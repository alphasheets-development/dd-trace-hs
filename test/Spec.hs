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

newtype Tracer a = Tracer { _unTrace :: MTL.StateT DD.TraceState IO a }
  deriving ( Applicative
           , Functor
           , Monad
           , Base.MonadBase IO
           , MTL.MonadState DD.TraceState
           , Catch.MonadThrow
           , Catch.MonadCatch
           , Catch.MonadMask
           )

instance MonadIO Tracer where
  liftIO = Base.liftBase

instance DD.MonadTrace Tracer where
  askTraceState = Tracer MTL.get
  modifyTraceState = Tracer . MTL.modify'

runTracerM :: (Catch.MonadMask m, MonadIO m) => Warp.Port -> Tracer a -> m a
runTracerM port (Tracer act) = do
  req <- liftIO $ do
    req <- HTTP.parseRequest (printf "http://localhost:%d/v0.3/traces" port)
    return $! req { HTTP.method = HTTP.methodPut }

  config <- DD.mkDefaultTraceConfig >>= \config ->
    return $! config { DD._trace_request = req }

  DD.withTracing config $ \state -> do
    liftIO $ fst <$> MTL.runStateT act state

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
    STM.atomically $ STM.readTVar counter >>= STM.check . (== 2)
  where
    mkSpanInfo qual = DD.SpanInfo
      { DD._span_info_name = qual <> "-span"
      , DD._span_info_resource = qual <> "-resource"
      , DD._span_info_service = qual <> "-service"
      , DD._span_info_type = qual <> "-type"
      }
    doSpan qual = DD.span (mkSpanInfo qual)
