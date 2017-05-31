{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
-- | Make some trace calls to confirm API actually works and reaches
-- datadog. This is a trivial "example" binary.
module Main where

import           Control.Concurrent (threadDelay)
import qualified Control.Monad.Base as Base
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (MonadIO(..))
import qualified Control.Monad.State.Strict as MTL
import           Data.Monoid ((<>))
import qualified Network.Datadog.Trace as DD

data TracerState = TracerState
  { tracerEnv :: !DD.TraceEnv
  , tracerSetup :: !DD.TraceSetup
  , tracerState :: !DD.TraceState
  }

newtype Tracer a = Tracer { _unTrace :: MTL.StateT TracerState IO a }
  deriving ( Applicative
           , Functor
           , Monad
           , Base.MonadBase IO
           , MTL.MonadState TracerState
           , Catch.MonadThrow
           , Catch.MonadCatch
           , Catch.MonadMask
           )

instance MonadIO Tracer where
  liftIO = Base.liftBase

instance DD.MonadTrace Tracer where
  askTraceSetup = Tracer (MTL.gets tracerSetup)
  askTraceState = Tracer (MTL.gets tracerState)
  askTraceEnv = Tracer (MTL.gets tracerEnv)
  modifyTraceState f = Tracer (MTL.modify' (\st -> st { tracerState = f (tracerState st) }))

runTracerM :: (Catch.MonadMask m, MonadIO m) => Tracer a -> m a
runTracerM (Tracer act) = do
  setup <- DD.mkDefaultTraceSetup
  DD.withTracing setup $ \env -> do
    st <- DD.newTraceState
    liftIO $ fst <$> MTL.runStateT act (TracerState env setup st)

main :: IO ()
main = do
  putStrLn "Can get own request"
  runTracerM $ do
    liftIO $ putStrLn "Newborn world"
    doSpan "top" $ do
      liftIO $ putStrLn "Hello world"
      doSpan "child" $ do
        liftIO $ putStrLn "Bye world"

    DD.startNewTrace
    doSpan "sleep" $ liftIO $ do
      threadDelay 2000000
      putStrLn "Sleep world"
  putStrLn "Complete."
  where
    mkSpanInfo qual = DD.SpanInfo
      { DD._span_info_name = qual <> "-span"
      , DD._span_info_resource = qual <> "-resource"
      , DD._span_info_service = qual <> "-service"
      , DD._span_info_type = qual <> "-type"
      }
    doSpan qual = DD.span (mkSpanInfo qual)
