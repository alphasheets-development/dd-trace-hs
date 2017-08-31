{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module   : Control.Trace.Workers.Handle
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Default implementation of a worker writing to an open 'Handle'.
module Control.Trace.Workers.Handle
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
import           Control.Trace.Types
import qualified Data.Aeson.Text as Aeson
import qualified Data.Text.Lazy as TextLazy
import qualified Data.Text.Lazy.IO as TextLazy
import           Data.Typeable (Typeable)
import           System.IO
import           Text.Printf (printf)

-- | Commands our handle worker can process.
data Cmd t =
  -- | Command to write out the given 'Trace'.
  CmdSpan !FinishedSpan
  -- | Command to write out an already-serialised trace.
  | CmdSerialisedSpan !t
  -- | Command the worker to terminate.
  | CmdDie

-- | Configuration for a worker writing to user-provided handle.
data HandleWorkerConfig t = HandleWorkerConfig
  { -- | Conversion function for to 'Text' that we can write out.
    _handle_worker_serialise :: FinishedSpan -> t
    -- | Write the serialised trace out.
  , _handle_worker_writer :: t -> IO ()
    -- | Should we serialise the value before we send it to the
    -- worker? This can make a difference if writes to the handle are
    -- slow but the serialisation itself is cheap: if serialised form
    -- is cheaper than 'Trace' and quick to compute and writing to the
    -- handle is taking a while, it's can be more beneficial to keep
    -- the serialised form in memory rather than the trace itself.
  , _handle_worker_serialise_before_send :: !Bool
    -- | What should we do on exception to the handle worker? See
    -- '_worker_exception'. As usual, the worker finalisation does not
    -- close the handle, it is up to the user to do so in their
    -- program or inside this handler.
    --
    -- An action which stops the worker threads is provided should you
    -- wish to use it for teardown.
  , _handle_worker_on_exception :: Catch.SomeException -> IO () -> IO Fatality
  }

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
mkHandleWorker :: forall t. HandleWorkerConfig t -> IO WorkerConfig
mkHandleWorker cfg = do
  (inCh, outCh) <- U.newChan 4096
  isDead <- STM.newTVarIO False
  let workerDie = do
        U.writeChan inCh CmdDie
        STM.atomically $ STM.readTVar isDead >>= STM.check . (== True)

  let sendWrite = void . U.tryWriteChan inCh
      sendWrite' = if _handle_worker_serialise_before_send cfg
                   then sendWrite . CmdSpan
                   else sendWrite . CmdSerialisedSpan . _handle_worker_serialise cfg
  return $! WorkerConfig
    { _wc_setup = void . Async.async $ writeLoop outCh `Catch.catch` \e -> do
        STM.atomically $ STM.writeTVar isDead True
        void $ _handle_worker_on_exception cfg e workerDie
    , _wc_run = \t -> STM.atomically (STM.readTVar isDead) >>= \case
        False -> sendWrite' t
        True -> Catch.throwM HandleWorkerDeadException
    , _wc_die = workerDie
    , _wc_exception = \e -> _handle_worker_on_exception cfg e workerDie
    }
  where
    writeLoop :: U.OutChan (Cmd t) -> IO ()
    writeLoop outCh = U.readChan outCh >>= \case
      CmdSpan s -> do
        _handle_worker_writer cfg $ _handle_worker_serialise cfg s
        writeLoop outCh
      CmdSerialisedSpan s -> _handle_worker_writer cfg s >> writeLoop outCh
      CmdDie -> return ()
