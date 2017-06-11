{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
module Main (main) where

import           Control.Concurrent
import qualified Control.Concurrent.STM as STM
import qualified Control.Monad.Base as Base
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (MonadIO(..))
import qualified Control.Monad.Trans.State.Strict as T
import           Data.Monoid ((<>))
import qualified Network.Datadog.Trace as Trace
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Test.Tasty as Tasty
import qualified Test.Tasty.HUnit as HUnit
import           Text.Printf (printf)

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

runTracerM :: (Catch.MonadMask m, MonadIO m) => Warp.Port -> Tracer a -> m a
runTracerM port (Tracer act) = do
  req <- liftIO $ do
    req <- HTTP.parseRequest (printf "http://localhost:%d/v0.3/traces" port)
    return $! req { HTTP.method = HTTP.methodPut }

  config <- liftIO Trace.defaultDatadogWorkerConfig >>= \config ->
    return . Trace.Datadog $! config { Trace._datadog_request = req }

  -- Run datadog tracer twice to test multiple workers actually work.
  Trace.withTracing [config, config] $ liftIO . T.evalStateT act

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
      doSpan "top" $ do
        liftIO $ step "Mid level"
        doSpan "child" $ do
          liftIO $ step "Bottom level"
      doSpan "sleep" $ do
        liftIO $ threadDelay 2000000
    -- Two workers sending 2 requests each, 4 requests.
    STM.atomically $ STM.readTVar counter >>= STM.check . (== 4)
  where
    mkSpanInfo qual = Trace.SpanInfo
      { Trace._span_info_name = qual <> "-span"
      , Trace._span_info_resource = qual <> "-resource"
      , Trace._span_info_service = qual <> "-service"
      , Trace._span_info_type = qual <> "-type"
      }
    doSpan qual = Trace.span (mkSpanInfo qual)
