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
  ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import           Control.Monad (void)
import qualified Control.Monad.Catch as Catch
import qualified Data.Aeson.Text as Aeson
import qualified Data.Text.Lazy as TextLazy
import qualified Data.Text.Lazy.IO as TextLazy
import           Network.Datadog.Trace.Types
import           System.IO

-- | Commands our handle worker can process.
data Cmd t =
  -- | Command to write out the given 'Trace'.
  CmdTrace Trace
  -- | Command to write out an already-serialised trace.
  | CmdSerialisedTrace t
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
  }

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
  worker <- Async.async $ writeLoop outCh
  flip Catch.onException (killWorker worker inCh) $ do
    let sendWrite = void . U.tryWriteChan inCh
        sendWrite' = if _handle_worker_serialise_before_send cfg
                     then sendWrite . CmdTrace
                     else sendWrite . CmdSerialisedTrace . _handle_worker_serialise cfg
    return $! Worker
      { _worker_run = sendWrite'
      , _worker_die = killWorker worker inCh
      }
  where
    killWorker :: Async.Async () -> U.InChan (Cmd t) -> IO ()
    killWorker w inCh = do
      U.writeChan inCh CmdDie
      void $ Async.waitCatch w

    writeLoop :: U.OutChan (Cmd t) -> IO ()
    writeLoop outCh = U.readChan outCh >>= \case
      CmdTrace t -> do
        _handle_worker_writer cfg $ _handle_worker_serialise cfg t
        writeLoop outCh
      CmdSerialisedTrace t -> _handle_worker_writer cfg t >> writeLoop outCh
      CmdDie -> return ()
