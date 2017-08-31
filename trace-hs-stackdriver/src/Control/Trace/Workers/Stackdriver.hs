{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE LambdaCase          #-}
-- |
-- Module   : Control.Trace.Workers.Stackdriver
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Default implementation of a worker writing to a stackdriver agent.
module Control.Trace.Workers.Stackdriver
  ( defaultStackdriverWorkerConfig
  , mkStackdriverWorker
  , StackdriverWorkerConfig(..)
  , StackdriverWorkerDeadException(..)
  , StackdriverEnv
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import qualified Control.Concurrent.STM as STM
import           Control.Lens ((&), (.~))
import           Control.Monad (replicateM_, unless, void, when)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Resource (runResourceT)
import           Control.Trace.Types
import           Data.Bits (shiftR)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as M
import           Data.Monoid ((<>))
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import           Data.Typeable (Typeable)
import           GHC.Word (Word8, Word64)
import qualified Network.Google as G
import qualified Network.Google.CloudTrace as G
import           Text.Printf (printf)

-- | Commands stackdriver agent workers can process.
data Cmd =
  -- | Command to write out the given 'Trace'.
  CmdSpan !FinishedSpan
  -- | Command the worker to terminate.
  | CmdDie

-- | Handy synonym for 'G.Env' scoped over trace patching API.
type StackdriverEnv = G.Env (G.Scopes G.ProjectsPatchTraces)

-- | Worker sending data to a stackdriver trace agent.
data StackdriverWorkerConfig = StackdriverWorkerConfig
  { -- | How many green threads to use to consume incoming traces. The
    -- trade-off is between blocking on slow sends to local trace
    -- daemon and filling up the queue and between having many idle
    -- workers.
    _stackdriver_number_of_workers :: !Int
    -- | Whether to block span writes into '_stackdriver_chan' when the
    -- channel is full. This shouldn't affect the user action speed
    -- but if your channel fills up, it means potential long waits
    -- between actions.
  , _stackdriver_blocking :: !Bool
    -- | '_stackdriver_chan' bound.
  , _stackdriver_chan_bound :: !Int
    -- | Action to perform when '_stackdriver_blocking' is 'False' and the
    -- channel is full: we're dropping the span and might want to at
    -- least log that. Ideally you should set the other parameters in
    -- such a way that this never fires.
  , _stackdriver_on_blocked :: FinishedSpan -> IO ()
    -- | Sometimes we may want to leave tracing on to get a feel for
    -- how the system will perform with it but not actually send the
    -- traces anywhere.
  , _stackdriver_do_writes :: !Bool
    -- | Custom trace debug callback
  , _stackdriver_debug_callback :: Text.Text -> IO ()
    -- | Print debug info when sending traces? Uses '_stackdriver_do_writes'.
  , _stackdriver_debug :: !Bool
    -- | Configurable '_worker_exception'. This is just the logging
    -- part. Death will be handled by the worker itself. See also
    -- '_stackdriver_die_on_exception'.
    --
    -- An action that asks the the remaining worker threads to finish
    -- their work is provided should you wish to use it.
  , _stackdriver_on_exception :: Catch.SomeException -> IO () -> IO Fatality
    -- | Action to run after the span has been sent. Used mostly for
    -- testing but could be used for logging as well. Blocks the
    -- thread that performed the send.
  , _stackdriver_post_send :: FinishedSpan -> IO ()
    -- | Create 'G.Env' with the right credentials and scopes. This
    -- can be as simple as 'G.newEnv' or customised with
    -- 'G.newEnvWith'.
  , _stackdriver_mk_env :: IO StackdriverEnv
    -- | Stackdriver project name that the traces will be sent to.
  , _stackdriver_project :: !Text.Text
  }

-- | Make a 'StackdriverWorkerConfig' with default settings. This assumes trace
-- agent is running locally on default port.
--
-- You should at the very least override '_stackdriver_project' so we
-- know where to send the traces, if anywhere.
defaultStackdriverWorkerConfig :: StackdriverWorkerConfig
defaultStackdriverWorkerConfig = StackdriverWorkerConfig
  { _stackdriver_number_of_workers = 8
  , _stackdriver_blocking = False
    -- We shouldn't really be hitting so many traces accumulating
    -- unless we have some non-child span in tight loop...
  , _stackdriver_chan_bound = 4096
  , _stackdriver_on_blocked = \s -> do
      putStrLn $ "Span channel full, dropping " <> show s
  , _stackdriver_do_writes = True
  , _stackdriver_debug_callback = Text.putStrLn
  , _stackdriver_debug = False
  , _stackdriver_on_exception = \e workerDie -> do
      printf "Span failed to send due to '%s'." (show e)
      workerDie
      return Fatal
  , _stackdriver_post_send = \_ -> return ()
  , _stackdriver_mk_env = G.newEnv
  , _stackdriver_project = Text.empty
  }

-- | Internal worker state used to determine when the worker stops
-- being available.
data StackdriverWorkerState = Alive | Degraded | Dead
  deriving (Show, Eq, Ord)

-- | The worker is dead and is no longer any writes.
data StackdriverWorkerDeadException = StackdriverWorkerDeadException
  deriving (Show, Eq, Typeable)

instance Catch.Exception StackdriverWorkerDeadException where

-- | Spaws '_stackdriver_number_of_workers' workers that listen on
-- internal channel to which traces are written and send them using
-- '_stackdriver_request' to the specified stackdriver agent. The agent itself
-- is in charge of sending the traces on to Stackdriver.
mkStackdriverWorker :: StackdriverWorkerConfig -> IO WorkerConfig
mkStackdriverWorker cfg = do
  (inCh, outCh) <- U.newChan (_stackdriver_chan_bound cfg)
  statusVar <- STM.newTVarIO Alive
  genv <- _stackdriver_mk_env cfg

  -- Write a CmdDie for each worker then wait for them to die one by
  -- one. We have to write that many CmdDie as any of the workers
  -- can pick it up so we have to make sure we have one for each
  -- worker. Note that it's perfectly possible for some workers to
  -- start dying and others to process more incoming messages
  -- between the CmdDie are processed. CmdDie uses the same channel
  -- so all messages before it will be processed.
  let killWorkers = do
        replicateM_ (_stackdriver_number_of_workers cfg) $ U.writeChan inCh CmdDie
        STM.atomically $ STM.readTVar statusVar >>= STM.check . (== Dead)

  let runWrite x = if _stackdriver_blocking cfg
                   then U.writeChan inCh x >> return True
                   else U.tryWriteChan inCh x

  return $! WorkerConfig
    { _wc_setup = do
        workerCountVar <- STM.newTVarIO (0 :: Word64)
        replicateM_ (_stackdriver_number_of_workers cfg) $ do
          STM.atomically $ STM.modifyTVar' workerCountVar succ
          Async.async $ do
            let workerDied = Catch.mask_ . STM.atomically $ do
                  STM.modifyTVar' workerCountVar pred
                  STM.readTVar workerCountVar >>= STM.writeTVar statusVar . \case
                    0 -> Dead
                    _ -> Degraded
            (writeLoop genv outCh `Catch.finally` workerDied) `Catch.catch` \e -> do
              void $ _stackdriver_on_exception cfg e killWorkers
    , _wc_run = \t -> STM.atomically (STM.readTVar statusVar) >>= \case
        Dead -> Catch.throwM StackdriverWorkerDeadException
        -- Write on degraded and alive.
        _ -> runWrite (CmdSpan t) >>= \b -> do
          unless b $ _stackdriver_on_blocked cfg t
    , _wc_die = killWorkers
    , _wc_exception = \e -> _stackdriver_on_exception cfg e killWorkers
    }
  where
    writeLoop :: StackdriverEnv -> U.OutChan Cmd -> IO ()
    writeLoop genv outCh = U.readChan outCh >>= \case
      CmdSpan t -> runSend genv t >> writeLoop genv outCh
      CmdDie -> return ()

    spanToStackdriverTrace :: FinishedSpan -> G.Trace
    spanToStackdriverTrace s =
      let s' = G.traceSpan
             & G.tsStartTime .~ Just (Text.pack . show $ _span_start s)
             & G.tsEndTime .~ Just (Text.pack . show $ _span_start s + _span_duration s)
             & G.tsKind .~ Just "SPAN_KIND_UNSPECIFIED"
             & G.tsName .~ Just (_span_name s)
             & G.tsLabels .~ mkLabels (_span_meta s <> _span_metrics s)
             & G.tsParentSpanId .~ _span_parent_id s
             & G.tsSpanId .~ Just (_span_span_id s)

          -- Convert any map that we may have to hashmap that the
          -- library expects
          mkLabels = fmap (G.traceSpanLabels . HM.fromList . M.toList)
          -- We tag spans with Word64 but Stackdriver expects a
          -- 128-bit value encoded in 32-byte hex: i.e. they want a
          -- UUID.
          w64ToUUIDText :: Word64 -> Text.Text
          w64ToUUIDText w =
            let w1 :: Word8
                [w1, w2, w3, w4, w5, w6, w7, w8] = map (fromIntegral . shiftR w) [56, 48 .. 0]
                halfUUID = Text.pack $ printf (concat $ Prelude.replicate 8 "%02.2x") w1 w2 w3 w4 w5 w6 w7 w8
            in halfUUID <> halfUUID
      in G.trace & G.tSpans .~ [s']
                 & G.tProjectId .~ Just (_stackdriver_project cfg)
                 & G.tTraceId .~ Just (w64ToUUIDText $ _span_trace_id s)

    -- We do not catch exceptions
    -- TODO: We could do work batching instead of going 1 span at a
    -- time. Consider it. Write benchmarks first.
    runSend :: StackdriverEnv -> FinishedSpan -> IO ()
    runSend _ _ | not $ _stackdriver_do_writes cfg = return ()
    runSend genv s = do
      let req = G.projectsPatchTraces traces (_stackdriver_project cfg)
          traces = G.traces & G.tTraces .~ [stackdriverTrace]
          stackdriverTrace = spanToStackdriverTrace s
      debug $ "Sending following trace: " <> Text.pack (show stackdriverTrace)
      runResourceT . G.runGoogle genv . void $ G.send req
      liftIO $ _stackdriver_post_send cfg s

    debug = when (_stackdriver_debug cfg) . liftIO . _stackdriver_debug_callback cfg
