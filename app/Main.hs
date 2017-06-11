{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
-- | Make some trace calls to confirm API actually works and reaches
-- datadog. This is a trivial "example" binary.
module Main where

import           Control.Concurrent (threadDelay)
import qualified Control.Monad.Base as Base
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (MonadIO(..))
import qualified Control.Monad.Trans.State.Strict as T
import qualified Data.IORef as IORef
import           Data.Monoid ((<>))
import qualified Network.Datadog.Trace as Trace
import qualified Network.Datadog.Trace.Types as Trace

newtype Tracer a = Tracer { _unTrace :: T.StateT Trace.TraceState IO a }
  deriving ( Applicative
           , Functor
           , Monad
           , Base.MonadBase IO
           , Catch.MonadThrow
           , Catch.MonadCatch
           , Catch.MonadMask
           )

instance MonadIO Tracer where
  liftIO = Base.liftBase

instance Trace.MonadTrace Tracer where
  askTraceState = Tracer T.get
  modifyTraceState = Tracer . T.modify'

runTracerM :: (Catch.MonadMask m, MonadIO m) => Tracer a -> m [Trace.Trace]
runTracerM (Tracer act) = do
  tracesRef <- liftIO $ IORef.newIORef []
  let ioRefWorker = Trace.UserWorker $! Trace.UserWorkerConfig
        { Trace._user_setup = return ()
        , Trace._user_run = IORef.modifyIORef' tracesRef . (:)
        , Trace._user_die = return ()
        }
  Trace.withTracing [ioRefWorker] $ \state -> liftIO $ do
    _ <- T.runStateT act state
    IORef.readIORef tracesRef

main :: IO ()
main = do
  putStrLn "Running tracer..."
  traces <- runTracerM $ do
    liftIO $ putStrLn "Top level"
    doSpan "top" $ do
      liftIO $ putStrLn "Inside top span"
      doSpan "child" $ do
        liftIO $ putStrLn "Inside child span"
    doSpan "sleep" $ liftIO $ do
      putStrLn "Inside sleep span, sleeping for 2 seconds..."
      threadDelay 2000000
  putStrLn $ "Complete with: " <> show traces
  where
    mkSpanInfo qual = Trace.SpanInfo
      { Trace._span_info_name = qual <> "-span"
      , Trace._span_info_resource = qual <> "-resource"
      , Trace._span_info_service = qual <> "-service"
      , Trace._span_info_type = qual <> "-type"
      }
    doSpan qual = Trace.span (mkSpanInfo qual)
