{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE LambdaCase #-}
module Main (main) where

import           Control.Concurrent (forkIO, threadDelay)
import qualified Control.Concurrent.STM as STM
import           Control.Monad (replicateM_)
import qualified Control.Monad.Base as Base
import qualified Control.Monad.Catch as Catch
import           Control.Monad.IO.Class (MonadIO(..))
import qualified Control.Monad.Trans.State.Strict as T
import           Data.Monoid ((<>))
import qualified Network.Datadog.Trace as Trace
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.HTTP.Types as HTTP
import qualified Test.Tasty as Tasty
import qualified Test.Tasty.HUnit as HUnit
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
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

runTracerM :: (Catch.MonadMask m, MonadIO m)
           => Int -- ^ Port to listen on
           -> Int -- ^ Number of workers
           -> STM.TVar Int
           -> STM.TVar (Maybe String)
           -> Tracer a -> m a
runTracerM port workerCount tCounter diedVar (Tracer act) = do
  req <- liftIO $ do
    req <- HTTP.parseRequest (printf "http://localhost:%d/v0.3/traces" port)
    return $! req { HTTP.method = HTTP.methodPut }

  config <- liftIO Trace.defaultDatadogWorkerConfig >>= \config ->
    return . Trace.Datadog $! config
      { Trace._datadog_request = req
      , Trace._datadog_post_send = \_ -> do
          STM.atomically $ STM.modifyTVar' tCounter succ
      , Trace._datadog_debug = False
      , Trace._datadog_on_exception = \e killWorkers -> do
          STM.atomically . STM.writeTVar diedVar . Just $
            "Tracer exception: " <> show e
          killWorkers
          return Trace.Fatal
      }

  -- Run datadog tracer twice to test multiple workers actually work.
  let workers = Prelude.replicate workerCount config
  Trace.withTracing workers $ liftIO . T.evalStateT act

mkOK :: Wai.Application
mkOK _req respond = respond $ Wai.responseLBS HTTP.status200 [] "OK"

main :: IO ()
main = do
  (port, socket) <- Warp.openFreePort
  let settings = Warp.setPort port
               $ Warp.defaultSettings
  _ <- forkIO $ Warp.runSettingsSocket settings socket mkOK

  counter <- STM.newTVarIO 0
  diedVar <- STM.newTVarIO Nothing
  let workerCount = 5
      spanCount = 100
  Tasty.defaultMain $ HUnit.testCaseSteps "Main test" $ \step -> do
    act <- runTracerM port workerCount counter diedVar $ do
      -- Give 1ms breather per trace or web server panics
      replicateM_ spanCount (doSpan "step" $ liftIO $ threadDelay 1000)
      -- Wait until all messages are processed.
      liftIO . STM.atomically $ do
        (STM.readTVar diedVar >>= \case
            Nothing -> STM.retry
            Just d -> return . error $ "Test died: " <> d)
        `STM.orElse`
          (do STM.readTVar counter >>= STM.check . (== workerCount * spanCount)
              return . step $ "Processed " <> show (workerCount * spanCount) <> " requests.")
    act
  where
    mkSpanInfo qual = Trace.SpanInfo
      { Trace._span_info_name = qual <> "-span"
      , Trace._span_info_resource = qual <> "-resource"
      , Trace._span_info_service = qual <> "-service"
      , Trace._span_info_type = qual <> "-type"
      }
    doSpan qual = Trace.span (mkSpanInfo qual)
