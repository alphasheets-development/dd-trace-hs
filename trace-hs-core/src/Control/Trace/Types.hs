{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
-- |
-- Module   : Control.Trace.Types
-- Copyright: 2017 Alphasheets
-- License  : All Rights Reserved
--
-- Types used throughout @trace-hs-core@. Most useful things are
-- re-exported in @Control.Trace@.
module Control.Trace.Types
  ( Fatality(..)
  , FinishedSpan
  , HandleWorkerConfig(..)
  , Id
  , MonadTrace(..)
  , RunningSpan
  , Span(..)
  , SpanInfo(..)
  , StartedWorker(..)
  , TraceState(..)
  , UserWorkerConfig(..)
  , Worker(..)
  , WorkerConfig(..)
  ) where

import qualified Control.Concurrent.STM as STM
import qualified Control.Monad.Catch as Catch
import qualified Control.Monad.Trans.Class as T
import qualified Control.Monad.Trans.Reader as Reader
import qualified Control.Monad.Trans.State.Lazy as StateLazy
import qualified Control.Monad.Trans.State.Strict as StateStrict
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import           Data.Map.Strict (Map)
import           Data.Text (Text)
import           Data.Vector (Vector)
import           Data.Word (Word8, Word64)
import           GHC.Generics (Generic)

-- | A single trace (such as "user makes a request for a file") is
-- split into many 'Span's ("find file on disk", "read file", "send
-- file back", ...).
data Span a = Span
  { -- | The unique integer ID of the trace containing this span.
    _span_trace_id :: !Id
    -- | The span integer ID.
  , _span_span_id :: !Id
    -- | The span name
  , _span_name :: !Text
    -- | The resource you are tracing.
  , _span_resource :: !Text
    -- | The service name.
  , _span_service :: !Text
    -- | The type of request.
  , _span_type :: !Text
    -- | The start time of the request in nanoseconds from the unix epoch.
  , _span_start :: !Word64
    -- | The duration of the request in nanoseconds.
  , _span_duration :: !a
    -- | The span integer ID of the parent span.
  , _span_parent_id :: !(Maybe Id)
    -- | Set this value to @'Just' 1@ to indicate if an error occured.
    -- If an error occurs, you should pass additional information,
    -- such as the error message, type and stack information in the
    -- '_span_meta' property.
  , _span_error :: !(Maybe Word8)
    -- | A dictionary of key-value metrics data. e.g. tags.
  , _span_meta :: !(Maybe (Map Text Text))
    -- | A dictionary of key-value metrics data. Note: keys must be
    -- strings, values must be numeric.
  , _span_metrics :: !(Maybe (Map Text Text))
  } deriving (Show, Eq, Ord, Generic)

-- | IDs for traces, spans, ...
type Id = Word64

-- | Span that's currently on-going
type RunningSpan = Span ()

-- | Span that has finished but is part of a trace that has not.
type FinishedSpan = Span Word64

-- | Aeson parser options for 'Span's.
spanOptions :: Aeson.Options
spanOptions = Aeson.defaultOptions
  { Aeson.fieldLabelModifier    = drop (length ("_span_" :: String))
  , Aeson.omitNothingFields     = True
  }

instance Aeson.ToJSON a => Aeson.ToJSON (Span a) where
  toJSON = Aeson.genericToJSON spanOptions
  toEncoding = Aeson.genericToEncoding spanOptions

-- | Information to tag the span with used for categorisation of
-- spans.
data SpanInfo = SpanInfo
  { -- | '_span_name'.
    _span_info_name :: !Text
  , -- | '_span_resource'.
    _span_info_resource :: !Text
  , -- | '_span_service'.
    _span_info_service :: !Text
  , -- | '_span_type'.
    _span_info_type :: !Text
  } deriving (Show, Eq, Ord)

-- | Determines whether the exception received by the worker was fatal
-- or not. If it was fatal, the worker should be synchronously cleaned
-- up and 'Fatal' returned.
data Fatality = Fatal | NonFatal

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

-- | User-provided trace handler. Close over any state you need to
-- track.
data UserWorkerConfig = UserWorkerConfig
  { -- | A blocking action that sets up the user worker.
    _user_setup :: IO ()
    -- | Action processing a span.
  , _user_run :: FinishedSpan -> IO ()
    -- | A blocking action that tears down the worker.
  , _user_die :: IO ()
    -- | See '_worker_exception'. '_user_die' or any other teardown
    -- will not be called for you, it is up to the user to decide
    -- whether the exception is fatal and how to clean up.
  , _user_exception :: Catch.SomeException -> IO Fatality
  }

-- | Workers process traces and decide what to do with them.
data WorkerConfig where
  HandleWorker :: forall t. HandleWorkerConfig t -> WorkerConfig
  UserWorker :: UserWorkerConfig -> WorkerConfig

-- | The implementation of the "thing" actually processing the traces:
-- writing to file, sending elsewhere, discarding...
data Worker = Worker
  { -- | Kill the worker and wait until it dies. If `_worker_die`
    -- throws an exception, the worker is marked as dead.
    --
    -- It should be harmless to invoke '_worker_die' multiple times.
    _worker_die :: IO ()
    -- | Invoke the worker on the given span. Must be OK to run on a
    -- dead worker: your worker should make sure it's able to write
    -- the message or discard it if the worker is considered
    -- dead/dying. Any exceptions thrown by '_worker_run' are passed
    -- to '_worker_exception'. Asynchronous.
  , _worker_run :: FinishedSpan -> IO ()
    -- | Worker threw the given exception during '_worker_run'.
    -- Depending on worker implementation, this might not be directly
    -- related to the span that was being processed at the time: for
    -- example, a worker that uses threads to process spans might have
    -- died some time in the past and we only find out about it now on
    -- write.
    --
    -- If the exception is fatal, it is up to the user to perform a
    -- blocking clean-up operation and report 'Fatal'. Once the report
    -- is made, no more messages will be given to the worker. It is
    -- likely that messages will arrive during clean-up: the worker
    -- should handle this.
  , _worker_exception :: Catch.SomeException -> IO Fatality
    -- | How many messages does this worker have in-flight? If
    -- 'Nothing', the worker no longer accepts any messages.
  , _worker_in_flight :: !(Maybe Word64)
  }

-- | A started worker is a pair of 'Worker' as well as a count of how
-- many messages it has left to process. This count allows us to know
-- when it's OK to tear down worker without losing any unsent spans.
newtype StartedWorker = StartedWorker (STM.TVar (Maybe Worker))

-- | State of an on-going trace.
data TraceState = TraceState
  { -- | Implementation internal environment that tracer uses.
    _trace_workers :: !(Vector StartedWorker)
    -- | Trace we're executing under.
  , _trace_id :: !(Maybe Id)
    -- | The span we're currently in.
  , _working_span :: !(Maybe RunningSpan)
  }

-- | Basically MonadState
class MonadTrace m where
  askTraceState :: m TraceState
  modifyTraceState :: (TraceState -> TraceState) -> m ()

instance (Monad m, MonadTrace m) => MonadTrace (StateLazy.StateT s m) where
  askTraceState = T.lift askTraceState
  modifyTraceState = T.lift . modifyTraceState

instance (Monad m, MonadTrace m) => MonadTrace (StateStrict.StateT s m) where
  askTraceState = T.lift askTraceState
  modifyTraceState = T.lift . modifyTraceState

instance (Monad m, MonadTrace m) => MonadTrace (Reader.ReaderT r m) where
  askTraceState = T.lift askTraceState
  modifyTraceState = T.lift . modifyTraceState
