{-# LANGUAGE LambdaCase   #-}
{-# LANGUAGE ViewPatterns #-}
module Network.Datadog.Trace
  ( MonadTrace(..)
  , Network.Datadog.Trace.span
  , SpanInfo(..)
  , TraceEnv(..)
  , TraceSetup(..)
  , TraceState(..)
  , mkDefaultTraceSetup
  , newTraceState
  , modifySpanMeta
  , modifySpanMetrics
  , setSpanError
  , startNewTrace
  , withTracing
  ) where

import           Control.Concurrent (forkIO, ThreadId, myThreadId)
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TBChan as STM
import           Control.Monad (forM_, replicateM_, unless, void, when)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (liftIO, MonadIO(..))
import           Control.Monad.Trans.Resource (runResourceT)
import           Data.Function (fix)
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (listToMaybe)
import           Data.Monoid ((<>), mempty)
import           Data.String (fromString)
import           Data.Text (Text)
import qualified Data.Text as Text (pack)
import qualified Data.Text.IO as Text (putStrLn)
import           Network.Datadog.Trace.Types
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.HTTP.Simple as HTTP
import qualified Network.HTTP.Types as HTTP
import           Prelude hiding (span)
import qualified System.Clock as Clock
import qualified System.Random as Random

-- | Make a 'TraceSetup' with default settings. This assumes trace
-- agent is running locally on default port.
mkDefaultTraceSetup :: MonadIO m => m TraceSetup
mkDefaultTraceSetup = liftIO $ do
  req <- HTTP.parseRequest "http://localhost:8126/v0.3/traces"
  return $! TraceSetup
    { _trace_request = req { HTTP.method = HTTP.methodPut }
    , _trace_number_of_workers = 8
    , _trace_blocking = False
      -- We shouldn't really reach this many anyway unless someone
      -- sticks a trace in tight loop...
    , _trace_chan_bound = 8192
    , _trace_on_blocked = \s -> do
        putStrLn $ "Trace channel full, dropping " <> show s
    , _trace_max_send_amount = 512
    , _trace_enabled = True
    , _trace_do_sends = True
    , _trace_debug = False
    , _trace_debug_callback = Text.putStrLn
    }

-- | Make a new trace. Note that IDs are picked randomly
-- ('Random.randomIO').
newTraceState :: MonadIO m => m TraceState
newTraceState = do
  i <- liftIO Random.randomIO
  return $! TraceState
    { trace = i
    , spanInfo = mempty
    , spanStack = mempty
    }

-- | Run a tracing context around the given action. This sets up
-- workers as well as handles teardown. Normall you want this around
-- your outermost call as this will block until all traces are sent
-- even after the inner action has already completed. That ensures that
-- things like
--
-- @ main = do
--    …
--    withTracing setup (\_ -> do { 'span' … (void . liftIO . forkIO $ …) })
-- @
--
-- work. 'withTracing' will wait until the span is sent before exiting
-- instead of losing the trace if it wasn't sent on time. This is why
-- it's advisable to only have a single 'withTracing': you only pay
-- the penalty when it exits.
--
-- Subject to '_trace_enabled'.
withTracing :: (Catch.MonadMask m, MonadIO m) => TraceSetup -> (TraceEnv -> m a) -> m a
withTracing ts act = case _trace_enabled ts of
  True -> Catch.bracket (startTracing ts) (stopTracing ts) act
  False -> mkDummyEnv >>= act
  where
    mkDummyEnv = liftIO $ do
      w <- STM.newTVarIO mempty
      c <- STM.newTBChanIO 0
      f <- STM.newTVarIO 0
      return $! TraceEnv
        { _trace_workers = w
        , _trace_chan = c
        , _trace_in_flight = f
        }

-- | Start a new trace. This basically means picking a new trace ID.
-- All future 'span's will be under this new trace.
startNewTrace :: (MonadIO m, MonadTrace m) => m ()
startNewTrace = newTraceState >>= modifyTraceState . const

-- | Tag the given action with a trace. Once the action exits, the
-- trace ends and is queued for sending to datadog.
--
-- Subject to '_trace_enabled'.
span :: (Catch.MonadMask m, MonadTrace m, MonadIO m) => SpanInfo -> m a -> m a
span ~i act = _trace_enabled <$> askTraceSetup >>= \case
  True -> Catch.bracket (startSpan i) endSpan (\_ -> act)
  False -> act

-- | Signal that something went on during this trace. This is
-- convenient to signal abnormal behaviour later visible in datadog
-- dashboard.
setSpanError :: MonadTrace m => RunningSpan -> m ()
setSpanError s = withSpanContext s $ \c -> c { spanError = True }

-- | Modify the 'Map' of attributes that should be sent back with the
-- span.
modifySpanMeta :: MonadTrace m => RunningSpan -> (Map Text Text -> Map Text Text) -> m ()
modifySpanMeta s f = withSpanContext s $ \c -> c { spanMeta = f (spanMeta c) }

-- | Modify the 'Map' of metrics that should be sent back with the span.
modifySpanMetrics :: MonadTrace m => RunningSpan -> (Map Text Text -> Map Text Text) -> m ()
modifySpanMetrics s f = withSpanContext s $ \c -> c { spanMetrics = f (spanMetrics c) }

-- | Get 'STM.TBChan' contents until there are no more elements.
-- Output produced in first-in last-out fashion.
getTBChanContents :: STM.TBChan a -> STM.STM (NonEmpty a)
getTBChanContents ch = do
  e <- STM.readTBChan ch
  flip fix (e :| []) $ \loop es -> do
    STM.tryReadTBChan ch >>= \case
      Just e' -> loop $ e' NE.<| es
      Nothing -> return es

-- | Initialise workers &c.
startTracing :: MonadIO m => TraceSetup -> m TraceEnv
startTracing ts = liftIO $ do
  ch <- STM.newTBChanIO (_trace_chan_bound ts)
  workerMap <- STM.newTVarIO Map.empty
  replicateM_ (_trace_number_of_workers ts) (startWorker ch workerMap)
  in_flight <- STM.newTVarIO 0
  return $! TraceEnv
    { _trace_workers = workerMap
    , _trace_chan = ch
    , _trace_in_flight = in_flight
    }
  where
    startWorker :: STM.TBChan FinishedSpan
                -> STM.TVar (Map ThreadId (STM.TVar Bool))
                -> IO (ThreadId, STM.TVar Bool)
    startWorker ch workerMap = do
      dieRef <- STM.newTVarIO False
      threadId <- forkIO . fix $ \loop -> do
        es <- STM.atomically $ STM.readTVar dieRef >>= \case
          True -> return Nothing
          False ->  Just <$> getTBChanContents ch
        case es of
          Nothing -> do
            tId <- myThreadId
            STM.atomically $ do
              STM.modifyTVar' workerMap (Map.delete tId)
          Just es' -> do
            runSend ts es'
            loop
      return $! (threadId, dieRef)


-- | Blocks until every already-finished span has been sent. Waits for
-- all on-going spans to finish first. This means that if you forget
-- to `endSpan` inside a forked thread somewhere, this will block
-- forever. You should always use `span` where possible to avoid this.
stopTracing :: MonadIO m => TraceSetup -> TraceEnv -> m ()
stopTracing ts env = liftIO $ do
  -- Tell every worker to die and wait until they do.
  workers <- STM.readTVarIO (_trace_workers env)
  forM_ (Map.elems workers) $ \wRef -> do
    STM.atomically $ STM.writeTVar wRef True
  STM.atomically $ do
    m <- STM.readTVar (_trace_workers env)
    STM.check (Map.null m)

  -- Wait until all on-going spans have completed.
  STM.atomically $ do
    in_flight <- STM.readTVar (_trace_in_flight env)
    STM.check (in_flight == 0)
  -- Now that every worker is dead, check if we have any spans still
  -- waiting to be sent. Can happen if spans came in while other
  -- workers were already working and we told them to die.
  -- TODO: orElse should work fine
  STM.atomically (STM.tryPeekTBChan $ _trace_chan env) >>= \case
    Nothing -> return ()
    Just{} -> do
      es <- STM.atomically (getTBChanContents $ _trace_chan env)
      runSend ts es

-- | Perform the actual send of the given spans to tracing agent.
runSend :: TraceSetup -- ^
        -> NonEmpty FinishedSpan -> IO ()
runSend (_trace_do_sends -> False) _ = return ()
runSend ts sps = runResourceT $ do
  let req' = HTTP.setRequestBodyJSON [NE.toList sps] (_trace_request ts)
      req'' = req'
              { -- TODO: If charset is set in content-type, connection
                -- fails completely. Investigate if Haskell is failing
                -- or Go is faling (based on netcat tests, Go) and
                -- file a bug whereever appropriate.
                HTTP.requestHeaders = (HTTP.hContentType, fromString "application/json")
                                    : filter (\(h, _) -> h /= HTTP.hContentType)
                                             (HTTP.requestHeaders req')
              }
  when (_trace_debug ts) . liftIO $ do
    _trace_debug_callback ts (fromString "Sending following spans: " <> Text.pack (show sps))
  void $ HTTP.httpNoBody req''

startSpan
  :: (MonadIO m, MonadTrace m)
  => SpanInfo
  -> m RunningSpan
startSpan info = do
  trace_id <- trace <$> askTraceState
  span_id <- liftIO Random.randomIO
  startTime <- liftIO $ Clock.getTime Clock.Realtime
  parent_span <- listToMaybe . spanStack <$> askTraceState
  _trace_in_flight <$> askTraceEnv >>= \in_flight -> do
    liftIO . STM.atomically $ STM.modifyTVar' in_flight succ
  modifyTraceState $ \env -> env { spanStack = span_id : spanStack env }
  return $! Span
    { _span_trace_id = trace_id
    , _span_span_id = span_id
    , _span_name = _span_info_name info
    , _span_resource = _span_info_resource info
    , _span_service = _span_info_service info
    , _span_type = _span_info_type info
    , _span_start = Clock.toNanoSecs startTime
    , _span_duration = ()
    , _span_parent_id = parent_span
    , _span_error = Nothing
    , _span_meta = Nothing
    , _span_metrics = Nothing
    }

endSpan :: (MonadIO m, MonadTrace m) => RunningSpan -> m ()
endSpan s = do
  endTime <- liftIO $ Clock.getTime Clock.Realtime
  ctx <- do
    let spanId = _span_span_id s
    contexts <- spanInfo <$> askTraceState
    return $! Map.findWithDefault defaultSpanContext spanId contexts
  _trace_in_flight <$> askTraceEnv >>= \in_flight -> do
    liftIO . STM.atomically $ STM.modifyTVar' in_flight pred
  let s' = s { _span_duration = Clock.toNanoSecs endTime - _span_start s
             , _span_error = if spanError ctx then Just 1 else Nothing
             , _span_meta = if Map.null (spanMeta ctx) then Nothing else Just (spanMeta ctx)
             , _span_metrics = if Map.null (spanMetrics ctx) then Nothing else Just (spanMetrics ctx)
             }
  ts <- askTraceSetup
  ch <- _trace_chan <$> askTraceEnv
  written <- liftIO . STM.atomically $ do
    if _trace_blocking ts
    then STM.writeTBChan ch s' >> return True
    else STM.tryWriteTBChan ch s'
  unless written $ do
    liftIO $ _trace_on_blocked ts s'

  -- TODO: Make stacks work with forking
  modifyTraceState $ \env -> env { spanStack = case spanStack env of
                                [] -> []
                                _ : rest -> rest
                            }

defaultSpanContext :: SpanContext
defaultSpanContext = SpanContext
  { spanError = False
  , spanMeta = Map.empty
  , spanMetrics = Map.empty
  }

withSpanContext :: MonadTrace m => RunningSpan -> (SpanContext -> SpanContext) -> m ()
withSpanContext s f = modifyTraceState $ \env ->
  let contexts = spanInfo env
      spanId = _span_span_id s
      newInfo = f $ Map.findWithDefault defaultSpanContext spanId contexts
  in env { spanInfo = Map.insert spanId newInfo contexts }
