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
import           Control.Monad (replicateM, replicateM_, unless, void, when)
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
mkDatadogWorker :: DatadogWorkerConfig -> IO Worker
mkDatadogWorker cfg = do
  (inCh, outCh) <- U.newChan (_datadog_chan_bound cfg)
  workerCountVar <- STM.newTVarIO (0 :: Word64)
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

  _workers <- replicateM (_datadog_number_of_workers cfg) $ do
    STM.atomically $ STM.modifyTVar' workerCountVar succ
    Async.async $ do
      let workerDied = Catch.mask_ . STM.atomically $ do
            STM.modifyTVar' workerCountVar pred
            STM.readTVar workerCountVar >>= STM.writeTVar statusVar . \case
              0 -> Dead
              _ -> Degraded
      (writeLoop outCh `Catch.finally` workerDied) `Catch.catch` \e -> do
        void $ _datadog_on_exception cfg e killWorkers


  let runWrite x = if _datadog_blocking cfg
                   then U.writeChan inCh x >> return True
                   else U.tryWriteChan inCh x
  return $! Worker
    { _worker_run = \t -> STM.atomically (STM.readTVar statusVar) >>= \case
        Dead -> Catch.throwM DatadogWorkerDeadException
        -- Write on degraded and alive.
        _ -> runWrite (CmdSpan t) >>= \b -> do
          unless b $ _datadog_on_blocked cfg t
    , _worker_die = killWorkers
    , _worker_exception = \e -> _datadog_on_exception cfg e killWorkers
    , _worker_in_flight = Just 0
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