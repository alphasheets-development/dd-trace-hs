-- |
-- Module   : Control.Trace.Workers.Null
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- A "worker" that does nothing at all.
module Control.Trace.Workers.Null
  ( nullWorkerConfig
  ) where

import Control.Trace.Types

-- | Performs no actions
nullWorkerConfig :: WorkerConfig
nullWorkerConfig = UserWorker $! UserWorkerConfig
  { _user_setup = return ()
  , _user_run = \_ -> return ()
  , _user_die = return ()
  , _user_exception = \_ -> return Fatal
  }
