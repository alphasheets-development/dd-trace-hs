{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
module Network.Datadog.Trace
  ( MonadTrace(..)
  , Network.Datadog.Trace.span
  , SpanInfo(..)
  , TraceConfig(..)
  , TraceEnv(..)
  , TraceState(..)
  , mkDefaultTraceConfig
  , modifySpanMeta
  , modifySpanMetrics
  , signalSpanError
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
import           Data.Maybe (fromMaybe)
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

-- | Make a 'TraceConfig' with default settings. This assumes trace
-- agent is running locally on default port.
mkDefaultTraceConfig :: MonadIO m => m TraceConfig
mkDefaultTraceConfig = liftIO $ do
  req <- HTTP.parseRequest "http://localhost:8126/v0.3/traces"
  return $! TraceConfig
    { _trace_request = req { HTTP.method = HTTP.methodPut }
    , _trace_number_of_workers = 8
    , _trace_blocking = False
      -- We shouldn't really be hitting so many traces accumulating
      -- unless we have some non-child span in tight loop...
    , _trace_chan_bound = 512
    , _trace_on_blocked = \s -> do
        putStrLn $ "Trace channel full, dropping " <> show s
    , _trace_max_send_amount = 8
    , _trace_enabled = True
    , _trace_do_sends = True
    , _trace_debug = False
    , _trace_debug_callback = Text.putStrLn
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
withTracing
  :: (Catch.MonadMask m, MonadIO m)
  => TraceConfig -- ^ Trace config
  -> (TraceState -> m a)
  -- ^ User action. Useful to build user structure from with help of 'TraceState'.
  -> m a
withTracing config act = case _trace_enabled config of
  True -> Catch.bracket (startTracing config) stopTracing $ \env -> do
    let state = TraceState { _trace_env = env
                           , _working_spans = mempty
                           , _finished_spans = mempty
                           , _trace_config = config
                           }
    act state
  False -> mkDummyEnv >>= \env -> do
    let state = TraceState { _trace_env = env
                           , _working_spans = mempty
                           , _finished_spans = mempty
                           , _trace_config = config
                           }
    act state
  where
    mkDummyEnv = liftIO $ do
      w <- STM.newTVarIO mempty
      c <- STM.newTBChanIO 0
      return $! TraceEnv
        { _trace_workers = w
        , _trace_chan = c
        }

-- | Tag the given action with a trace. Once the action exits, the
-- trace ends and is queued for sending to datadog.
--
-- Subject to '_trace_enabled'.
span :: (Catch.MonadMask m, MonadTrace m, MonadIO m) => SpanInfo -> m a -> m a
span ~i act = _trace_enabled . _trace_config <$> askTraceState >>= \case
  True -> Catch.bracket_ (startSpan i) endSpan act
  False -> act

modifySpan :: MonadTrace m => (RunningSpan -> RunningSpan) -> m ()
modifySpan f = modifyTraceState $ \state ->
  state { _working_spans = case _working_spans state of
            -- We're not in a span, do nothing. We could warn I
            -- guess but _shrug_.
            [] -> _working_spans state
            s : ss -> f s : ss
        }

-- | Signal that something went on during this trace. This is
-- convenient to signal abnormal behaviour later visible in datadog
-- dashboard.
signalSpanError :: MonadTrace m => m ()
signalSpanError = modifySpan $ \s -> s { _span_error = Just 1 }

-- | Modify the 'Map' of attributes that should be sent back with the
-- span.
modifySpanMeta :: MonadTrace m => (Map Text Text -> Map Text Text) -> m ()
modifySpanMeta f = modifySpan $ \s ->
  s { _span_meta = let m = f $ fromMaybe mempty (_span_meta s)
                   in if Map.null m then Nothing else Just m }

-- | Modify the 'Map' of metrics that should be sent back with the span.
modifySpanMetrics :: MonadTrace m => (Map Text Text -> Map Text Text) -> m ()
modifySpanMetrics f = modifySpan $ \s ->
  s { _span_metrics = let m = f $ fromMaybe mempty (_span_metrics s)
                      in if Map.null m then Nothing else Just m }

-- | Initialise workers &c.
startTracing :: MonadIO m => TraceConfig -> m TraceEnv
startTracing config = liftIO $ do
  ch <- STM.newTBChanIO (_trace_chan_bound config)
  workerMap <- STM.newTVarIO Map.empty
  replicateM_ (_trace_number_of_workers config) (startWorker ch workerMap)
  return $! TraceEnv
    { _trace_workers = workerMap
    , _trace_chan = ch
    }
  where
    startWorker :: STM.TBChan [GroupedSpan]
                -> STM.TVar (Map ThreadId (STM.TVar Bool))
                -> IO (ThreadId, STM.TVar Bool)
    startWorker ch workerMap = do
      dieRef <- STM.newTVarIO False
      threadId <- forkIO . fix $ \loop -> do
        -- Process work. If no work is present, check if we were asked
        -- to die. This way we ensure we _always_ process all work
        -- before exiting.
        es <- STM.atomically $
          (Just <$> getTBChanContents)
          `STM.orElse`
          (STM.readTVar dieRef >>= STM.check >> return Nothing)
        case es of
          Nothing -> do
            tId <- myThreadId
            STM.atomically $ do
              STM.modifyTVar' workerMap (Map.delete tId)
          Just es' -> do
            runSend config es'
            loop
      return $! (threadId, dieRef)

      where
        getTBChanContents :: STM.STM (NonEmpty [GroupedSpan])
        getTBChanContents = do
          e <- STM.readTBChan ch
          flip fix (e :| []) $ \loop es -> do
            STM.tryReadTBChan ch >>= \case
              Just e' -> loop $ e' NE.<| es
              Nothing -> return es


-- | Blocks until every already-finished span has been sent. Waits for
-- all on-going spans to finish first. This means that if you forget
-- to `endSpan` inside a forked thread somewhere, this will block
-- forever. You should always use `span` where possible to avoid this.
stopTracing :: MonadIO m => TraceEnv -> m ()
stopTracing env = liftIO $ do
  -- Tell every worker to die and wait until they do.
  workers <- STM.readTVarIO (_trace_workers env)
  forM_ (Map.elems workers) $ \wRef -> do
    STM.atomically $ STM.writeTVar wRef True

  -- Workers only die if there is no work present. Further, they won't
  -- die if they are sending. Lastly, all our work is put in worker
  -- channel synchronously. All this combined means that if we have no
  -- workers left, we have processed all the work there was and we're
  -- OK to just exit.
  STM.atomically $ do
    m <- STM.readTVar (_trace_workers env)
    STM.check (Map.null m)

-- | Perform the actual send of the given spans to tracing agent.
runSend :: TraceConfig -> NonEmpty [GroupedSpan] -> IO ()
runSend (_trace_do_sends -> False) _ = return ()
runSend ts traces = runResourceT $ do
  let req' = HTTP.setRequestBodyJSON (NE.toList traces) (_trace_request ts)
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
    _trace_debug_callback ts (fromString "Sending following spans: " <> Text.pack (show traces))
  void $ HTTP.httpNoBody req''

startSpan
  :: (MonadIO m, MonadTrace m)
  => SpanInfo
  -> m ()
startSpan info = do
  -- Find parent if any.
  parent_span_id <- fmap _span_span_id . listToMaybe . _working_spans <$> askTraceState
  -- Now that we asked for a parent, put ourselves on top so that
  -- nested spans see us as the parent.
  span_id <- liftIO Random.randomIO
  startTime <- liftIO $ Clock.getTime Clock.Realtime
  let s = Span { _span_trace_id = ()
               , _span_span_id = span_id
               , _span_name = _span_info_name info
               , _span_resource = _span_info_resource info
               , _span_service = _span_info_service info
               , _span_type = _span_info_type info
               , _span_start = fromIntegral $ Clock.toNanoSecs startTime
               , _span_duration = ()
               , _span_parent_id = parent_span_id
               , _span_error = Nothing
               , _span_meta = Nothing
               , _span_metrics = Nothing
               }
  modifyTraceState $ \state -> state { _working_spans = s : _working_spans state }

endSpan :: (MonadIO m, MonadTrace m) => m ()
endSpan = do
  !endTime <- liftIO $ Clock.getTime Clock.Realtime
  askTraceState >>= \state -> case _working_spans state of
    -- We really shouldn't be in here... Something popped off too much stuff...
    [] -> return ()
    s : restSpans -> do
      let !finishedSpan = s { _span_duration = fromIntegral (Clock.toNanoSecs endTime) - _span_start s }

      case restSpans of
        -- If we have no more spans on the stack, we were a top level
        -- span and we just finished. Send everything we possibly
        -- accumulated to the workers and keep going.
        [] -> do
          let chan = _trace_chan $ _trace_env state
              config = _trace_config state
          -- Now that we have the full group of spans in the trace,
          -- give it some trace ID and send it off.
          traces :: [GroupedSpan] <- do
            traceId <- liftIO Random.randomIO
            return $ map (\fs -> fs { _span_trace_id = traceId })
                         (finishedSpan : _finished_spans state)

          written <- liftIO . STM.atomically $ case _trace_blocking config of
            True -> STM.writeTBChan chan traces >> return True
            False -> STM.tryWriteTBChan chan traces
          unless written . liftIO $ do
            _trace_on_blocked config traces
          modifyTraceState $ \st' -> st' { _working_spans = mempty
                                         , _finished_spans = mempty }
        -- We do still have working spans, just remember to pop off
        -- the one we just worked on and to add it to finished
        -- collection and be on our way
        _ -> modifyTraceState $ \st' ->
          st' { _working_spans = restSpans
              , _finished_spans = finishedSpan : _finished_spans st'
              }
