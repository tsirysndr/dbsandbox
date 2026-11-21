-- | Local HTTP transport only. Routing, authorization and actions are PureScript.
module Sbx.UI.Web.Native (Server, Request, Response, listen, close) where

import Prelude
import Bsdkrun.Internal (Async, toAff)
import Data.Either (Either(..))
import Effect.Aff (Aff, attempt, launchAff, launchAff_, killFiber)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Foreign.Object (Object)

foreign import data Server :: Type
type Request = { method :: String, path :: String, query :: String, database :: String, branch :: String, source :: String, id :: String, host :: String, origin :: String, token :: String, body :: String }
type Response = { status :: Int, headers :: Object String, body :: String }

foreign import listenImpl :: Int -> (Request -> Async Response) -> Async Server
foreign import closeImpl :: Server -> Async Unit

listen :: Int -> (Request -> Aff Response) -> Aff Server
listen port handler = toAff $ listenImpl port \request failure success -> do
  fiber <- launchAff do
    result <- attempt (handler request)
    liftEffect case result of
      Left err -> failure err
      Right response -> success response
  pure (launchAff_ (killFiber (error "HTTP request closed") fiber))

close :: Server -> Aff Unit
close = toAff <<< closeImpl
