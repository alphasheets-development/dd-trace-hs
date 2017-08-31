{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module   : Network.Datadog.Trace.Workers.Datadog
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Default implementation of a worker writing to a datadog agent.
module Network.Datadog.Trace.Workers.Datadog
  ( defaultDatadogWorkerConfig
  , mkDatadogWorker
  , DatadogWorkerConfig(..)
  , DatadogWorkerDeadException(..)
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import qualified Control.Concurrent.STM as STM
import           Control.Monad (replicateM_, unless, void, when)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Resource (runResourceT)
import           Data.Monoid ((<>))
import           Data.String (fromString)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import           Data.Typeable (Typeable)
import           GHC.Word (Word64)
import           Network.Datadog.Trace.Types
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.HTTP.Simple as HTTP
import qualified Network.HTTP.Types as HTTP
import           Text.Printf (printf)


-- | Commands datadog agent workers can process.
data Cmd =
  -- | Command to write out the given 'Trace'.
  CmdSpan FinishedSpan
  -- | Command the worker to terminate.
  | CmdDie


-- | Worker sending data to a datadog trace agent.
data DatadogWorkerConfig = DatadogWorkerConfig
  { -- | Request to perform when sending traces. For example
    --
    -- @
    -- initReq <- 'HTTP.parseRequest' "http://localhost:8126/v0.3/traces"
    -- return $! 'TraceConfig' { '_trace_request' = initReq { 'HTTP.method' = fromString "PUT" } }
    -- @
    _datadog_request :: !HTTP.Request
    -- | How many green threads to use to consume incoming traces. The
    -- trade-off is between blocking on slow sends to local trace
    -- daemon and filling up the queue and between having many idle
    -- workers.
  , _datadog_number_of_workers :: !Int
    -- | Whether to block span writes into '_datadog_chan' when the
    -- channel is full. This shouldn't affect the user action speed
    -- but if your channel fills up, it means potential long waits
    -- between actions.
  , _datadog_blocking :: !Bool
    -- | '_datadog_chan' bound.
  , _datadog_chan_bound :: !Int
    -- | Action to perform when '_datadog_blocking' is 'False' and the
    -- channel is full: we're dropping the span and might want to at
    -- least log that. Ideally you should set the other parameters in
    -- such a way that this never fires.
  , _datadog_on_blocked :: FinishedSpan -> IO ()
    -- | Sometimes we may want to leave tracing on to get a feel for
    -- how the system will perform with it but not actually send the
    -- traces anywhere.
  , _datadog_do_writes :: !Bool
    -- | Custom trace debug callback
  , _datadog_debug_callback :: Text.Text -> IO ()
    -- | Print debug info when sending traces? Uses '_datadog_do_writes'.
  , _datadog_debug :: !Bool
    -- | Configurable '_worker_exception'. This is just the logging
    -- part. Death will be handled by the worker itself. See also
    -- '_datadog_die_on_exception'.
    --
    -- An action that asks the the remaining worker threads to finish
    -- their work is provided should you wish to use it.
  , _datadog_on_exception :: Catch.SomeException -> IO () -> IO Fatality
    -- | Action to run after the span has been sent. Used mostly for
    -- testing but could be used for logging as well. Blocks the
    -- thread that performed the send.
  , _datadog_post_send :: FinishedSpan -> IO ()
  }

-- | Make a 'DatadogWorkerConfig' with default settings. This assumes trace
-- agent is running locally on default port.
defaultDatadogWorkerConfig :: IO DatadogWorkerConfig
defaultDatadogWorkerConfig = do
  req <- HTTP.parseRequest "http://localhost:8126/v0.3/traces"
  return $! DatadogWorkerConfig
    { _datadog_request = req { HTTP.method = HTTP.methodPut }
    , _datadog_number_of_workers = 8
    , _datadog_blocking = False
      -- We shouldn't really be hitting so many traces accumulating
      -- unless we have some non-child span in tight loop...
    , _datadog_chan_bound = 4092
    , _datadog_on_blocked = \s -> do
        putStrLn $ "Span channel full, dropping " <> show s
    , _datadog_do_writes = True
    , _datadog_debug_callback = Text.putStrLn
    , _datadog_debug = False
    , _datadog_on_exception = \e workerDie -> do
        printf "Span failed to send due to '%s'." (show e)
        workerDie
        return Fatal
    , _datadog_post_send = \_ -> return ()
    }

-- | Internal worker state used to determine when the worker stops
-- being available.
data DatadogWorkerState = Alive | Degraded | Dead
  deriving (Show, Eq, Ord)

-- | The worker is dead and is no longer any writes.
data DatadogWorkerDeadException = DatadogWorkerDeadException
  deriving (Show, Eq, Typeable)

instance Catch.Exception DatadogWorkerDeadException where

-- | Spaws '_datadog_number_of_workers' workers that listen on
-- internal channel to which traces are written and send them using
-- '_datadog_request' to the specified datadog agent. The agent itself
-- is in charge of sending the traces on to Datadog.
mkDatadogWorker :: DatadogWorkerConfig -> IO UserWorkerConfig
mkDatadogWorker cfg = do
  (inCh, outCh) <- U.newChan (_datadog_chan_bound cfg)
  statusVar <- STM.newTVarIO Alive

  -- Write a CmdDie for each worker then wait for them to die one by
  -- one. We have to write that many CmdDie as any of the workers
  -- can pick it up so we have to make sure we have one for each
  -- worker. Note that it's perfectly possible for some workers to
  -- start dying and others to process more incoming messages
  -- between the CmdDie are processed. CmdDie uses the same channel
  -- so all messages before it will be processed.
  let killWorkers = do
        replicateM_ (_datadog_number_of_workers cfg) $ U.writeChan inCh CmdDie
        STM.atomically $ STM.readTVar statusVar >>= STM.check . (== Dead)

  let runWrite x = if _datadog_blocking cfg
                   then U.writeChan inCh x >> return True
                   else U.tryWriteChan inCh x

  return $! UserWorkerConfig
    { _user_setup = do
        workerCountVar <- STM.newTVarIO (0 :: Word64)
        replicateM_ (_datadog_number_of_workers cfg) $ do
          STM.atomically $ STM.modifyTVar' workerCountVar succ
          Async.async $ do
            let workerDied = Catch.mask_ . STM.atomically $ do
                  STM.modifyTVar' workerCountVar pred
                  STM.readTVar workerCountVar >>= STM.writeTVar statusVar . \case
                    0 -> Dead
                    _ -> Degraded
            (writeLoop outCh `Catch.finally` workerDied) `Catch.catch` \e -> do
              void $ _datadog_on_exception cfg e killWorkers
    , _user_run = \t -> STM.atomically (STM.readTVar statusVar) >>= \case
        Dead -> Catch.throwM DatadogWorkerDeadException
        -- Write on degraded and alive.
        _ -> runWrite (CmdSpan t) >>= \b -> do
          unless b $ _datadog_on_blocked cfg t
    , _user_die = killWorkers
    , _user_exception = \e -> _datadog_on_exception cfg e killWorkers
    }
  where
    writeLoop :: U.OutChan Cmd -> IO ()
    writeLoop outCh = U.readChan outCh >>= \case
      CmdSpan t -> runSend t >> writeLoop outCh
      CmdDie -> return ()

    -- We do not catch exceptions
    -- TODO: We could do work batching instead of going 1 span at a
    -- time. Consider it. Write benchmarks first.
    runSend :: FinishedSpan -> IO ()
    runSend _ | not $ _datadog_do_writes cfg = return ()
    runSend s = runResourceT $ do
      let req' = HTTP.setRequestBodyJSON [[s]] (_datadog_request cfg)
          req'' = req'
                  { -- TODO: If charset is set in content-type, connection
                    -- fails completely. Investigate if Haskell is failing
                    -- or Go is faling (based on netcat tests, Go) and
                    -- file a bug whereever appropriate.
                    HTTP.requestHeaders = (HTTP.hContentType, fromString "application/json")
                                        : filter (\(h, _) -> h /= HTTP.hContentType)
                                                 (HTTP.requestHeaders req')
                  }
      debug $ fromString "Sending following span: " <> Text.pack (show s)
      -- will throw exception which should bubble up to the catch in
      -- initialisation and modify worker state.
      _ <- HTTP.httpNoBody req''
      liftIO $ _datadog_post_send cfg s
      where
        debug = when (_datadog_debug cfg) . liftIO . _datadog_debug_callback cfg
