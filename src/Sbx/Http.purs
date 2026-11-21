-- | Request parsing and response policy; the FFI only performs HTTP I/O.
module Sbx.Http (request, parse, healthy, client) where
import Prelude
import Bsdkrun.Internal (Async, toAff)
import Data.Array as A
import Data.Either (Either(..))
import Data.String as S
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (error)
import Control.Monad.Error.Class (throwError)
import Foreign.Object (Object)

type Request = { method :: String, path :: String, body :: String }
type Response = { status :: Int, body :: String }
parse :: Array String -> Either String Request
parse args = do
  spec <- case args of
    [path] -> Right {method: "GET", path, body: ""}
    [method, path] -> Right {method: S.toUpper method, path, body: ""}
    [method, path, body] -> Right {method: S.toUpper method, path, body}
    _ -> Left "Usage: api [METHOD] /path [JSON_BODY]"
  if not (A.elem spec.method ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]) then Left "Unsupported HTTP method"
  else if not (S.take 1 spec.path == "/") || S.take 2 spec.path == "//" || S.contains (S.Pattern "\\") spec.path then Left "API path must be relative to this sandbox, starting with /"
  else Right spec
foreign import requestImpl :: String -> Object String -> Request -> Int -> Async Response
request :: String -> Object String -> Request -> Int -> Aff Response
request base headers spec timeout = toAff (requestImpl base headers spec timeout)
healthy :: String -> Object String -> Aff Boolean
healthy address headers = do
  result <- attempt $ request address headers {method: "GET", path: "", body: ""} 1500
  pure case result of
    Right r -> r.status >= 200 && r.status < 300
    Left _ -> false
client :: String -> Object String -> Array String -> Aff Int
client base headers args = case parse args of
  Left msg -> throwError (error msg)
  Right spec -> do
    r <- request base headers spec 30000
    liftEffect (Console.log r.body)
    if r.status >= 200 && r.status < 300 then pure 0
    else liftEffect (Console.error ("HTTP " <> show r.status)) *> pure 1
