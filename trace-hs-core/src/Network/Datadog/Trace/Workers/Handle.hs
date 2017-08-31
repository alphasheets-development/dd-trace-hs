{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module   : Network.Datadog.Trace.Workers.Handle
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Default implementation of a worker writing to an open 'Handle'.
module Network.Datadog.Trace.Workers.Handle
  ( defaultHandleWorkerConfig
  , mkHandleWorker
  , HandleWorkerConfig(..)
  , HandleWorkerDeadException(..)
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import qualified Control.Concurrent.STM as STM
import           Control.Monad (void)
import qualified Control.Monad.Catch as Catch
import qualified Data.Aeson.Text as Aeson
import qualified Data.Text.Lazy as TextLazy
import qualified Data.Text.Lazy.IO as TextLazy
import           Data.Typeable (Typeable)
import           Network.Datadog.Trace.Types
import           System.IO
import           Text.Printf (printf)

-- | Commands our handle worker can process.
data Cmd t =
  -- | Command to write out the given 'Trace'.
  CmdSpan FinishedSpan
  -- | Command to write out an already-serialised trace.
  | CmdSerialisedSpan t
  -- | Command the worker to terminate.
  | CmdDie

-- | Default config that writes the traces in JSON format, one trace
-- per line. It is up to the user to make sure the handle is open and
-- in right buffering mode: with 'defaultHandleWorkerConfig', that's
-- 'LineBuffering'.
defaultHandleWorkerConfig :: Handle -> HandleWorkerConfig TextLazy.Text
defaultHandleWorkerConfig h = HandleWorkerConfig
  { _handle_worker_serialise = Aeson.encodeToLazyText
  , _handle_worker_writer = TextLazy.hPutStrLn h
  , _handle_worker_serialise_before_send = False
  , _handle_worker_on_exception = \e workerDie -> do
      TextLazy.putStrLn . TextLazy.pack $ printf
        "Span failed to write due to '%s'." (show e)
      workerDie
      return Fatal
  }

-- | The handle worker is no longer accepting writes and is considered
-- dead.
data HandleWorkerDeadException = HandleWorkerDeadException
  deriving (Show, Eq, Typeable)

instance Catch.Exception HandleWorkerDeadException where

-- | Handle worker using a fast unagi channel to provide non-blocking
-- (to the user) sequential file writing. This means the user only
-- waits for however long it takes to write the trace to the channel
-- rather than for the trace serialisation and write to disk.
--
-- This implementation is the "obvious" implementation, also used in
-- @katip@ though we can't quite re-use that one.
--
-- Does not open nor close the given handle. Does not set buffering
-- mode on the handle.
mkHandleWorker :: forall t. HandleWorkerConfig t -> IO Worker
mkHandleWorker cfg = do
  (inCh, outCh) <- U.newChan 4096
  isDead <- STM.newTVarIO False
  let workerDie = do
        U.writeChan inCh CmdDie
        STM.atomically $ STM.readTVar isDead >>= STM.check . (== True)

  _ <- Async.async $ writeLoop outCh `Catch.catch` \e -> do
    STM.atomically $ STM.writeTVar isDead True
    void $ _handle_worker_on_exception cfg e workerDie

  let sendWrite = void . U.tryWriteChan inCh
      sendWrite' = if _handle_worker_serialise_before_send cfg
                   then sendWrite . CmdSpan
                   else sendWrite . CmdSerialisedSpan . _handle_worker_serialise cfg
  return $! Worker
    { _worker_run = \t -> STM.atomically (STM.readTVar isDead) >>= \case
        False -> sendWrite' t
        True -> Catch.throwM HandleWorkerDeadException
    , _worker_die = workerDie
    , _worker_exception = \e -> _handle_worker_on_exception cfg e workerDie
    , _worker_in_flight = Just 0
    }
  where
    writeLoop :: U.OutChan (Cmd t) -> IO ()
    writeLoop outCh = U.readChan outCh >>= \case
      CmdSpan s -> do
        _handle_worker_writer cfg $ _handle_worker_serialise cfg s
        writeLoop outCh
      CmdSerialisedSpan s -> _handle_worker_writer cfg s >> writeLoop outCh
      CmdDie -> return ()
