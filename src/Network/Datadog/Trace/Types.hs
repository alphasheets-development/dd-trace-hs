{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.Datadog.Trace.Types
  ( FinishedSpan
  , GroupedSpan
  , Id
  , MonadTrace(..)
  , RunningSpan
  , Span(..)
  , SpanInfo(..)
  , TraceConfig(..)
  , TraceEnv(..)
  , TraceState(..)
  ) where

import           Control.Concurrent (ThreadId)
import qualified Control.Concurrent.STM.TBChan as STM
import qualified Control.Concurrent.STM.TVar as STM
import qualified Control.Monad.Trans.Class as T
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import           Data.Map.Strict (Map)
import           Data.Text (Text)
import           Data.Word (Word8, Word64)
import           GHC.Generics (Generic)
import qualified Network.HTTP.Simple as HTTP
import           Text.Printf (printf)

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

-- | Configuration for the tracing subsystem.
data TraceConfig = TraceConfig
  { -- | Request to perform when sending traces. For example
    --
    -- @
    -- initReq <- 'HTTP.parseRequest' "http://localhost:8126/v0.3/traces"
    -- return $! 'TraceConfig' { '_trace_request' = initReq { 'HTTP.method' = fromString "PUT" } }
    -- @
    _trace_request :: !HTTP.Request
    -- | How many green threads to use to consume incoming traces. The
    -- trade-off is between blocking on slow sends to local trace
    -- daemon and filling up the queue and between having many idle
    -- workers.
  , _trace_number_of_workers :: !Int
    -- | Whether to block span writes into '_trace_chan' when the
    -- channel is full. This shouldn't affect the user action speed
    -- but if your channel fills up, it means potential long waits
    -- between actions.
  , _trace_blocking :: !Bool
    -- | '_trace_chan' bound.
  , _trace_chan_bound :: !Int
    -- | Action to perform when '_trace_blocking' is 'False' and the
    -- channel is full: we're dropping the span and might want to at
    -- least log that. Ideally you should set the other parameters in
    -- such a way that this never fires.
  , _trace_on_blocked :: [GroupedSpan] -> IO ()
    -- | How many finished spans to try and send in a single request.
    -- Note that this does not determine amount of data that will be
    -- sent as 'FinishedSpan's have unbounded size fields.
  , _trace_max_send_amount :: !Int
    -- | Is tracing enabled? If not, the tracer will simply execute
    -- inner actions without doing any work. It is important to
    -- understand that tracing will still have an impact even if it
    -- doesn't do any work itself:
    --
    -- * Any arguments passed in strictly that otherwise would not be
    --   used will still be evaluated.
    --
    -- * GHC may produce different code even with do-nothing spans
    --   everywhere.
    --
    -- Further, this simply performs checks in user-exposed interface
    -- whether it is enabled.
  , _trace_enabled :: !Bool
    -- | Sometimes we may want to leave tracing on to get a feel for
    -- how the system will perform with it but not actually send the
    -- traces anywhere.
  , _trace_do_sends :: !Bool
    -- | Print debug info?
  , _trace_debug :: !Bool
    -- | Custom trace debug callback
  , _trace_debug_callback :: Text -> IO ()
  }

instance Show TraceConfig where
  show ts = printf
    (concat [ "TraceConfig {"
            , " _trace_request = %s"
            , ", _trace_number_of_workers = %d"
            , ", _trace_blocking = %s"
            , ", _trace_chan_bound = %d"
            , ", _trace_on_blocked = <FinishedSpan -> IO ()>"
            , ", _trace_max_send_amount = %d"
            , ", _trace_enabled = %s"
            , ", _trace_do_sends = %s"
            , " }"
            ])
    (show $ _trace_request ts) (_trace_number_of_workers ts)
    (show $ _trace_blocking ts) (_trace_chan_bound ts)
    (_trace_max_send_amount ts) (show $ _trace_enabled ts)
    (show $ _trace_do_sends ts)

-- | Tracing environment keeping track of workers and any other
-- metadata internal to implementation.
data TraceEnv = TraceEnv
  { _trace_workers :: !(STM.TVar (Map ThreadId (STM.TVar Bool)))
  , _trace_chan :: !(STM.TBChan [GroupedSpan])
  }

-- | State of an on-going trace.
data TraceState = TraceState
  { -- | Implementation internal environment that tracer uses.
    _trace_env :: !TraceEnv
    -- | Stack of spans which haven't finished yet.
  , _working_spans :: ![RunningSpan]
    -- | Set of spans which finished but haven't been assigned an
    -- trace_id yet as there may be more spans in their traces to come
    -- still.
  , _finished_spans :: ![FinishedSpan]
    -- | Configuration for the tracer.
  , _trace_config :: !TraceConfig
  }


-- | Basically MonadState
class MonadTrace m where
  askTraceState :: m TraceState
  modifyTraceState :: (TraceState -> TraceState) -> m ()

instance (T.MonadTrans t, Monad m, MonadTrace m) => MonadTrace (t m) where
  askTraceState = T.lift askTraceState
  modifyTraceState = T.lift . modifyTraceState
