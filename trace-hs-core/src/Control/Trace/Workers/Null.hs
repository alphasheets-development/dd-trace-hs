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
nullWorkerConfig = WorkerConfig
  { _wc_setup = return ()
  , _wc_run = \_ -> return ()
  , _wc_die = return ()
  , _wc_exception = \_ -> return Fatal
  }
