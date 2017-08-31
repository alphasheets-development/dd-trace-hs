{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module   : Control.Trace
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Tracing API. To use it, you implement workers that consume
-- 'FinishedSpan's. Spans are modelled after the format that @datadog@
-- monitoring service supports but can be modified by each worker into
-- required format before being processed further.
module Control.Trace
  ( Control.Trace.Types.Fatality(..)
  , Control.Trace.Types.HandleWorkerConfig(..)
  , Control.Trace.Types.MonadTrace(..)
  , Control.Trace.Types.SpanInfo(..)
  , Control.Trace.Types.TraceState(..)
  , Control.Trace.Types.UserWorkerConfig(..)
  , Control.Trace.Types.WorkerConfig(..)
  , Control.Trace.Workers.Handle.defaultHandleWorkerConfig
  , Control.Trace.Workers.Null.nullWorkerConfig
  , Control.Trace.defaultAskTraceState
  , Control.Trace.defaultModifyTraceState
  , Control.Trace.modifySpanMeta
  , Control.Trace.modifySpanMetrics
  , Control.Trace.signalSpanError
  , Control.Trace.span
  , Control.Trace.withTracing
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.STM as STM
import           Control.Monad (void)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (liftIO, MonadIO(..))
import qualified Control.Monad.Trans.Class as T
import           Control.Trace.Types
import qualified Control.Trace.Workers.Handle
import qualified Control.Trace.Workers.Null
import           Data.Foldable (for_, Foldable(toList))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid (mempty)
import           Data.Text (Text)
import           Data.Traversable (Traversable)
import qualified Data.Vector as V
import           Prelude hiding (span)
import qualified System.Clock as Clock
import qualified System.Random as Random

-- | Run a tracing context around the given action. This sets up the
-- given worker (through 'WorkerConfig') as well as handles teardown
-- afterwards. Normally you want this around your outermost call as
-- this calls worker teardown on main thread.
--
-- If no 'WorkerConfig' is provided, tracing is disabled.
withTracing
  :: (Catch.MonadMask m, MonadIO m, Foldable t)
  => t WorkerConfig
     -- ^ Worker configs for the tracer. Pass empty structure to
     -- disable tracing.
     --
     -- Note that empty structure is not the same as passing something
     -- like null worker in that simply discards everything. A null
     -- worker will still measure how long things take and create
     -- spans, it just won't do anything with them.
     --
     -- If a worker throws an exception during send, its finalizer is
     -- ran and it is removed from the worker pool.
  -> (TraceState -> m a)
     -- ^ User action. Useful to build user structure from with help
     -- of 'TraceState'.
  -> m a
withTracing wCs act =
  Catch.bracket (startTracing . V.fromList $ toList wCs) stopTracing $ \workers -> do
    act $ TraceState { _trace_workers = workers
                     , _trace_id = Nothing
                     , _working_span = Nothing
                     }

-- | @whenDisabled act1 act2@
--
-- Do @act1@ when tracing is disabled, otherwise @act2@. Tracing is
-- considered disabled when there are no live workers.
--
-- [speed]: We could optimise for the case where workes die off
-- during the run of the program by removing them from the vector
-- making this check cheaper over time. However it's a little tricky
-- and adding additional synchronisation over the vector itself is
-- likely to be a net loss unless we have a very large number of
-- workers.
whenDisabled :: (MonadIO m, MonadTrace m) => m a -> m a -> m a
whenDisabled onDisabled onEnabled = _trace_workers <$> askTraceState >>= \v ->
  V.foldM (\b w -> if b then return b else isLive w) False v >>= \case
    False -> onDisabled
    True -> onEnabled
  where
    isLive (StartedWorker w) = liftIO $ STM.readTVarIO w >>= return . \case
      Nothing -> False
      Just{} -> True

-- | Tag the given action with a trace. Once the action exits, the
-- trace ends and is queued for sending.
--
-- Subject to '_trace_enabled'.
span :: (Catch.MonadMask m, MonadTrace m, MonadIO m) => SpanInfo -> m a -> m a
span i act = whenDisabled act $ do
  -- If we don't have a trace, make a new one. If we do, use it.
  tState <- askTraceState
  traceId <- case _trace_id tState of
    Nothing -> liftIO Random.randomIO
    Just tId -> return tId
  -- Run the user's action then possibly recover old state. Recovering
  -- old state resets trace ID which is useful at top level but it
  -- also "pops" a span off. This means everything should just work
  -- for nested spans. It also makes things work in forked contexts
  -- where the the spans in the fork are children of the calling
  -- thread's span. This works fine because we don't have to
  -- back-propagate any state from inside the fork, we only ever pass
  -- state down.
  Catch.bracket (startSpan i traceId) endSpan (\_ -> act)
    `Catch.finally` modifyTraceState (\_ -> tState)

-- | Modify the span we're currently inside of. If we're not in the
-- span, does nothing. Subject to '_trace_enabled'.
modifySpan :: (MonadIO m, MonadTrace m) => (RunningSpan -> RunningSpan) -> m ()
modifySpan f = whenDisabled (return ()) $ modifyTraceState $ \state ->
  state { _working_span = case _working_span state of
            Nothing -> Nothing
            Just s -> Just $! f s
        }

-- | Signal that something went wrong during this trace.
signalSpanError :: (MonadIO m, MonadTrace m) => m ()
signalSpanError = modifySpan $ \s -> s { _span_error = Just 1 }

-- | Modify the 'Map' of attributes that should be sent back with the
-- span.
modifySpanMeta :: (MonadIO m, MonadTrace m) => (Map Text Text -> Map Text Text) -> m ()
modifySpanMeta f = modifySpan $ \s ->
  s { _span_meta = let m = f $ fromMaybe mempty (_span_meta s)
                   in if Map.null m then Nothing else Just m }

-- | Modify the 'Map' of metrics that should be sent back with the span.
modifySpanMetrics :: (MonadIO m, MonadTrace m) => (Map Text Text -> Map Text Text) -> m ()
modifySpanMetrics f = modifySpan $ \s ->
  s { _span_metrics = let m = f $ fromMaybe mempty (_span_metrics s)
                      in if Map.null m then Nothing else Just m }

-- | Initialise workers &c.
startTracing :: (MonadIO m, Traversable t) => t WorkerConfig -> m (t StartedWorker)
startTracing = liftIO . Async.mapConcurrently mkWorker
  where
    mkWorker config = do
      !w <- case config of
        HandleWorker hCfg -> Control.Trace.Workers.Handle.mkHandleWorker hCfg
        UserWorker uCfg -> do
          _user_setup uCfg
          return $! Worker { _worker_run = _user_run uCfg
                           , _worker_die = _user_die uCfg
                           , _worker_exception = _user_exception uCfg
                           , _worker_in_flight = Just 0 }
      StartedWorker <$> STM.newTVarIO (Just w)

-- | Invoke '_worker_die' on every worker. Blocking. Workers that
-- throw an exception during death will be considered to have died. Rethrows
stopTracing :: (MonadIO m, Traversable t) => t StartedWorker -> m ()
stopTracing = liftIO . Async.mapConcurrently_ killWorker
  where
    killWorker (StartedWorker mvWorker) = do
      -- Wait until in-flight messages are done then disable sending any more.
      mw <- STM.atomically $ do
        mw <- STM.readTVar mvWorker >>= \case
          Nothing -> return Nothing
          Just w -> do
            let c = _worker_in_flight w
            STM.check $ c == Just 0 || c == Nothing
            return $! Just w
        STM.writeTVar mvWorker Nothing
        return mw

      -- If worker is dead already, great. If not, we just denied it
      -- any new contact and now will try to actually kill it.
      for_ mw $ \w -> do
        _worker_die w `Catch.catch` \(_ :: Catch.SomeException) -> return ()

-- | Start timing a span and store info we have ahead of time.
startSpan
  :: (MonadIO m, MonadTrace m)
  => SpanInfo
  -> Id -- ^ Trace ID
  -> m RunningSpan
startSpan info traceId = do
  -- Find parent if any.
  parent_span_id <- fmap _span_span_id . _working_span <$> askTraceState
  -- Now that we asked for a parent, put ourselves on top so that
  -- nested spans see us as the parent.
  span_id <- liftIO Random.randomIO
  startTime <- liftIO $ Clock.getTime Clock.Monotonic
  let s = Span { _span_trace_id = traceId
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
  modifyTraceState $ \state -> state { _working_span = Just s }
  return s

-- | Stop timing a span. If it's the end a trace, push the trace to
-- the worker. Blocks only long enough to increase the amount of
-- in-flight messages for each sender.
endSpan :: (MonadIO m, MonadTrace m) => RunningSpan -> m ()
endSpan s = do
  !endTime <- liftIO $ Clock.getTime Clock.Monotonic
  !curTime <- liftIO $ Clock.getTime Clock.Realtime
  let
    !duration = fromIntegral (Clock.toNanoSecs endTime) - _span_start s
    !finishedSpan = s { _span_duration = duration
                      -- restore span_start based on the epoch timestamp
                      , _span_start = fromIntegral (Clock.toNanoSecs curTime) - duration
                      }
  -- Send span off to all the workers. Do nothing alse as 'span' will
  -- take care of resetting the state.
  workers <- _trace_workers <$> askTraceState
  liftIO . void . Async.async $ Async.mapConcurrently_ (sendSpan finishedSpan) workers
  where
    -- Increase in-flight count, try to send span, decrease in-flight
    -- count. If at any point worker dies, that's OK, we just leave
    -- with it marked as such.
    sendSpan :: FinishedSpan -> StartedWorker -> IO ()
    sendSpan fs (StartedWorker mvWorker) = do
      let modifyCount f = STM.atomically $ STM.readTVar mvWorker >>= \case
            Nothing -> return Nothing
            Just w -> case _worker_in_flight w of
              Nothing -> return Nothing
              Just c -> do
                let w' = Just $! w { _worker_in_flight = Just $! f c }
                STM.writeTVar mvWorker w'
                return w'
      mw <- modifyCount (\x -> x + 1)
      -- Of course worker could have died by now but that's okay
      -- because we require that _worker_run and _worker_die aren't
      -- harmful to call on dead worker.
      for_ mw $ \w -> Catch.mask $ \restore -> do
        let runWorker = do
              restore $ _worker_run w fs
              void $ modifyCount (\x -> x - 1)
            catchRunExc e = _worker_exception w e >>= \case
              Fatal -> STM.atomically $ STM.writeTVar mvWorker Nothing
              NonFatal -> void $ modifyCount (\x -> x - 1)
        runWorker `Catch.catch` catchRunExc

-- | Default implementation for 'askTraceState' for 'T.MonadTrans'.
defaultAskTraceState
  :: (T.MonadTrans t, Monad m, MonadTrace m)
  => t m TraceState
defaultAskTraceState = T.lift askTraceState

-- | Default implementation for 'modifyTraceState' for 'T.MonadTrans'.
defaultModifyTraceState
  :: (T.MonadTrans t, Monad m, MonadTrace m)
  => (TraceState -> TraceState) -> t m ()
defaultModifyTraceState = T.lift . modifyTraceState
