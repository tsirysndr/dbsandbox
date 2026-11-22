module Sbx.Cluster.Native where

import Prelude
import Bsdkrun.Internal (Async, toAff)
import Data.Nullable (Nullable)
import Effect (Effect)
import Effect.Aff (Aff)

foreign import data Server :: Type
foreign import internalWorker :: Effect (Nullable String)
foreign import invocation :: Effect { executable :: String, args :: Array String }
foreign import quiet :: Effect Unit
foreign import respond :: String -> Effect Unit
foreign import readText :: String -> Effect String
foreign import uuid :: Effect String
foreign import hashFileImpl :: String -> Async String
foreign import transferImpl :: Array String -> String -> Boolean -> Async Unit
foreign import execImpl :: Array String -> Async { exitCode :: Int, stderr :: String }
foreign import launchImpl :: String -> Async { address :: String, server :: Server }
foreign import waitImpl :: Server -> Async Unit
foreign import stopImpl :: Server -> Async Unit

hashFile :: String -> Aff String
hashFile = toAff <<< hashFileImpl

transfer :: Array String -> String -> Boolean -> Aff Unit
transfer args path receive = toAff (transferImpl args path receive)

exec :: Array String -> Aff { exitCode :: Int, stderr :: String }
exec = toAff <<< execImpl

launch :: String -> Aff { address :: String, server :: Server }
launch = toAff <<< launchImpl

wait :: Server -> Aff Unit
wait = toAff <<< waitImpl

stop :: Server -> Aff Unit
stop = toAff <<< stopImpl
