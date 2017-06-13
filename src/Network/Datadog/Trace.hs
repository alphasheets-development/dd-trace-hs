{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
-- |
-- Module   : Network.Datadog.Trace
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Tracing library with datadog support.
module Network.Datadog.Trace
  ( Network.Datadog.Trace.Types.DatadogWorkerConfig(..)
  , Network.Datadog.Trace.Types.HandleWorkerConfig(..)
  , Network.Datadog.Trace.Types.MonadTrace(..)
  , Network.Datadog.Trace.Types.SpanInfo(..)
  , Network.Datadog.Trace.Types.TraceState(..)
  , Network.Datadog.Trace.Types.UserWorkerConfig(..)
  , Network.Datadog.Trace.Types.WorkerConfig(..)
  , Network.Datadog.Trace.Workers.Datadog.defaultDatadogWorkerConfig
  , Network.Datadog.Trace.Workers.Handle.defaultHandleWorkerConfig
  , Network.Datadog.Trace.Workers.Null.nullWorkerConfig
  , Network.Datadog.Trace.defaultAskTraceState
  , Network.Datadog.Trace.defaultModifyTraceState
  , Network.Datadog.Trace.modifySpanMeta
  , Network.Datadog.Trace.modifySpanMetrics
  , Network.Datadog.Trace.signalSpanError
  , Network.Datadog.Trace.span
  , Network.Datadog.Trace.withTracing
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (liftIO, MonadIO(..))
import qualified Control.Monad.Trans.Class as T
import           Data.Foldable (for_)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid (mempty)
import           Data.Text (Text)
import           Network.Datadog.Trace.Types
import qualified Network.Datadog.Trace.Workers.Datadog
import qualified Network.Datadog.Trace.Workers.Handle
import qualified Network.Datadog.Trace.Workers.Null
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
  :: (Catch.MonadMask m, MonadIO m)
  => [WorkerConfig]
     -- ^ Worker configs for the tracer. Pass '[]' to disable tracing.
     --
     -- Note that '[]' is not the same as passing something like
     -- null worker in that simply discards everything. A null worker
     -- will still measure how long things take, accumulate spans and
     -- try to process traces, it just won't do anything with them.
     --
     -- Currently support for multiple workers is experimental. A
     -- leaked exception in one worker will kill every other worker as
     -- well as the whole tracing process. Likewise exception during
     -- teardown is likely to not result in teardown running for other
     -- workers. Use at own risk.
  -> (TraceState -> m a)
     -- ^ User action. Useful to build user structure from with help
     -- of 'TraceState'.
  -> m a
withTracing mWorkerCfg act =
  Catch.bracket (startTracing mWorkerCfg) stopTracing $ \mWorker -> do
    act $ TraceState { _trace_worker = mWorker
                     , _trace_id = Nothing
                     , _working_span = Nothing
                     }

-- | @whenDisabled act1 act2@
--
-- Do @act1@ when tracing is disabled, otherwise @act2@.
whenDisabled :: (Monad m, MonadTrace m) => m a -> m a -> m a
whenDisabled onDisabled onEnabled = _trace_worker <$> askTraceState >>= \case
  Nothing -> onDisabled
  Just{} -> onEnabled

-- | Tag the given action with a trace. Once the action exits, the
-- trace ends and is queued for sending to datadog.
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
modifySpan :: (Monad m, MonadTrace m) => (RunningSpan -> RunningSpan) -> m ()
modifySpan f = whenDisabled (return ()) $ modifyTraceState $ \state ->
  state { _working_span = case _working_span state of
            Nothing -> Nothing
            Just s -> Just $! f s
        }

-- | Signal that something went on during this trace. This is
-- convenient to signal abnormal behaviour later visible in datadog
-- dashboard.
signalSpanError :: (Monad m, MonadTrace m) => m ()
signalSpanError = modifySpan $ \s -> s { _span_error = Just 1 }

-- | Modify the 'Map' of attributes that should be sent back with the
-- span.
modifySpanMeta :: (Monad m, MonadTrace m) => (Map Text Text -> Map Text Text) -> m ()
modifySpanMeta f = modifySpan $ \s ->
  s { _span_meta = let m = f $ fromMaybe mempty (_span_meta s)
                   in if Map.null m then Nothing else Just m }

-- | Modify the 'Map' of metrics that should be sent back with the span.
modifySpanMetrics :: (Monad m, MonadTrace m) => (Map Text Text -> Map Text Text) -> m ()
modifySpanMetrics f = modifySpan $ \s ->
  s { _span_metrics = let m = f $ fromMaybe mempty (_span_metrics s)
                      in if Map.null m then Nothing else Just m }

-- | Initialise workers &c.
startTracing :: MonadIO m => [WorkerConfig] -> m (Maybe Worker)
startTracing [] = return Nothing
startTracing wCs = fmap Just . liftIO $ case wCs of
  -- Optimise for single worker case by skipping the whole Async
  -- stuff.
  [w] -> mkWorker w
  _ -> do
    workers <- Async.mapConcurrently mkWorker wCs
    return $! Worker { _worker_run = \t ->
                         Async.mapConcurrently_ (`_worker_run` t) workers
                     , _worker_die = Async.mapConcurrently_ _worker_die workers
                     }
  where
    mkWorker config = case config of
      Datadog ddCfg -> Network.Datadog.Trace.Workers.Datadog.mkDatadogWorker ddCfg
      HandleWorker hCfg -> Network.Datadog.Trace.Workers.Handle.mkHandleWorker hCfg
      UserWorker uCfg -> do
        _user_setup uCfg
        return $! Worker { _worker_run = _user_run uCfg
                         , _worker_die = _user_die uCfg }

-- | Invoke '_worker_die'. This is usually expected to block.
stopTracing :: MonadIO m => Maybe Worker -> m ()
stopTracing w = for_ w $ liftIO . _worker_die

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
  startTime <- liftIO $ Clock.getTime Clock.Realtime
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
-- the worker.
endSpan :: (MonadIO m, MonadTrace m) => RunningSpan -> m ()
endSpan s = do
  !endTime <- liftIO $ Clock.getTime Clock.Realtime
  let !finishedSpan = s { _span_duration = fromIntegral (Clock.toNanoSecs endTime) - _span_start s }
  -- Send span off.
  worker <- _trace_worker <$> askTraceState
  liftIO . for_ worker $ \w -> _worker_run w finishedSpan

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
