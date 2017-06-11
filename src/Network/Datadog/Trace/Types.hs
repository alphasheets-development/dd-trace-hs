{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
module Network.Datadog.Trace.Types
  ( FinishedSpan
  , GroupedSpan
  , Id
  , MonadTrace(..)
  , RunningSpan
  , Span(..)
  , SpanInfo(..)
  , Trace
  , TraceState(..)
  , DatadogWorkerConfig(..)
  , HandleWorkerConfig(..)
  , Worker(..)
  , WorkerConfig(..)
  , UserWorkerConfig(..)
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import           Data.Map.Strict (Map)
import           Data.Text (Text)
import           Data.Word (Word8, Word64)
import           GHC.Generics (Generic)
import qualified Network.HTTP.Simple as HTTP

-- | A single trace (such as "user makes a request for a file") is
-- split into many 'Span's ("find file on disk", "read file", "send
-- file back")…
data Span a b = Span
  { -- | The unique integer ID of the trace containing this span. Only
    -- set once we have gathered all the traces for the spans and
    -- we're about to send it. No need to carry it around.
    _span_trace_id :: !b
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

-- | IDs for traces, spans, ….
type Id = Word64

-- | Span that's currently on-going
type RunningSpan = Span () ()

-- | Span that has finished but is part of a trace that has not.
type FinishedSpan = Span Word64 ()

-- | Span that has finished and been assigned a trace ID along with
-- other spans in the same trace.
type GroupedSpan = Span Word64 Id

-- | A trace is just a collection of spans.
type Trace = [GroupedSpan]

-- | Aeson parser options for 'Span's.
spanOptions :: Aeson.Options
spanOptions = Aeson.defaultOptions
  { Aeson.fieldLabelModifier    = drop (length ("_span_" :: String))
  , Aeson.omitNothingFields     = True
  }

instance (Aeson.ToJSON a, Aeson.ToJSON b) => Aeson.ToJSON (Span a b) where
  toJSON = Aeson.genericToJSON spanOptions
  toEncoding = Aeson.genericToEncoding spanOptions

-- | Information to tag the span with used for categorisation of spans
-- on datadog.
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
  , _datadog_on_blocked :: Trace -> IO ()
    -- | Sometimes we may want to leave tracing on to get a feel for
    -- how the system will perform with it but not actually send the
    -- traces anywhere.
  , _datadog_do_writes :: !Bool
    -- | Custom trace debug callback
  , _datadog_debug_callback :: Text -> IO ()
    -- | Print debug info when sending traces?
  , _datadog_debug :: !Bool
  }

-- | Configuration for a worker writing to user-provided handle.
data HandleWorkerConfig t = HandleWorkerConfig
  { -- | Conversion function for traces to 'Text' that we can write out.
    _handle_worker_serialise :: Trace -> t
    -- | Write the serialised trace out.
  , _handle_worker_writer :: t -> IO ()
    -- | Should we serialise the value before we send it to the
    -- worker? This can make a difference if writes to the handle are
    -- slow but the serialisation itself is cheap: if serialised form
    -- is cheaper than 'Trace' and quick to compute and writing to the
    -- handle is taking a while, it's can be more beneficial to keep
    -- the serialised form in memory rather than the trace itself.
  , _handle_worker_serialise_before_send :: !Bool
  }

-- | User-provided trace handler. Close over any state you need to
-- track.
data UserWorkerConfig = UserWorkerConfig
  { -- | A blocking action that sets up the user worker.
    _user_setup :: IO ()
    -- | Action processing a trace.
  , _user_run :: Trace -> IO ()
    -- | A blocking action that tears down the worker.
  , _user_die :: IO ()
  }

-- | Workers process traces and decide what to do with them.
data WorkerConfig where
  Datadog :: DatadogWorkerConfig -> WorkerConfig
  HandleWorker :: forall t. HandleWorkerConfig t -> WorkerConfig
  UserWorker :: UserWorkerConfig -> WorkerConfig

-- | The implementation of the "thing" actually processing the traces:
-- writing to file, sending elsewhere, discarding...
data Worker = Worker
  { -- | Kill the worker and wait until it dies.
    _worker_die :: IO ()
    -- | Invoke the worker on the given trace.
  , _worker_run :: Trace -> IO ()
  -- | Tracing environment keeping track of workers and any other
  -- metadata internal to implementation.
  }

-- | State of an on-going trace.
data TraceState = TraceState
  { -- | Implementation internal environment that tracer uses.
    _trace_worker :: !(Maybe Worker)
    -- | Stack of spans which haven't finished yet.
  , _working_spans :: ![RunningSpan]
    -- | Set of spans which finished but haven't been assigned an
    -- trace_id yet as there may be more spans in their traces to come
    -- still.
  , _finished_spans :: ![FinishedSpan]
  }

-- | Basically MonadState
class MonadTrace m where
  askTraceState :: m TraceState
  modifyTraceState :: (TraceState -> TraceState) -> m ()
