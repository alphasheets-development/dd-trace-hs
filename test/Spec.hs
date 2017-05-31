{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
module Main (main) where

import           Control.Concurrent
import qualified Control.Concurrent.STM as STM
import qualified Control.Monad.Base as Base
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (MonadIO(..))
import qualified Control.Monad.State.Strict as MTL
import           Data.Monoid ((<>))
import qualified Network.Datadog.Trace as DD
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Test.Tasty as Tasty
import qualified Test.Tasty.HUnit as HUnit
import           Text.Printf (printf)

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

runTracerM :: (Catch.MonadMask m, MonadIO m) => Warp.Port -> Tracer a -> m a
runTracerM port (Tracer act) = do
  req <- liftIO $ do
    req <- HTTP.parseRequest (printf "http://localhost:%d/v0.3/traces" port)
    return $! req { HTTP.method = HTTP.methodPut }

  setup <- DD.mkDefaultTraceSetup >>= \setup ->
    return $! setup { DD._trace_request = req }

  DD.withTracing setup $ \env -> do
    st <- DD.newTraceState
    liftIO $ fst <$> MTL.runStateT act (TracerState env setup st)

mkEcho :: STM.TVar Int -> Wai.Application
mkEcho counter _req respond = do
  STM.atomically $ STM.modifyTVar' counter succ
  respond $ Wai.responseLBS HTTP.status200 [] "OK"

main :: IO ()
main = do
  (port, socket) <- Warp.openFreePort
  let settings = Warp.setPort port
               $ Warp.defaultSettings
  counter <- STM.newTVarIO 0
  _ <- forkIO $ Warp.runSettingsSocket settings socket (mkEcho counter)
  Tasty.defaultMain $ HUnit.testCaseSteps "Main test" $ \step -> do
    step "Can get own request"
    runTracerM port $ do
      liftIO $ step "Top level"
      liftIO $ putStrLn "top level"
      doSpan "top" $ do
        liftIO $ step "Mid level"
        liftIO $ putStrLn "Hello world"
        doSpan "child" $ do
          liftIO $ step "Bottom level"
          liftIO $ putStrLn "Bye world"
      doSpan "sleep" $ do
        liftIO $ threadDelay 2000000
        liftIO $ putStrLn "Sleep world"
  STM.atomically $ STM.readTVar counter >>= STM.check . (== 3)
  where
    mkSpanInfo qual = DD.SpanInfo
      { DD._span_info_name = qual <> "-span"
      , DD._span_info_resource = qual <> "-resource"
      , DD._span_info_service = qual <> "-service"
      , DD._span_info_type = qual <> "-type"
      }
    doSpan qual = DD.span (mkSpanInfo qual)
