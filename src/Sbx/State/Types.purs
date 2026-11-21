module Sbx.State.Types (State, decode) where

import Prelude
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Argonaut.Core as J
import Data.Int as Int
import Foreign.Object as O

type State =
  { os :: String
  , version :: String -- ^ Linux image tag or BSD release; "" for the default
  , port :: Int
  , user :: String
  , password :: String
  , db :: String
  , branch :: String
  , cpus :: Int
  , mem :: Int
  }

decode :: J.Json -> Maybe State
decode json = do
  obj <- J.toObject json
  let text key = O.lookup key obj >>= J.toString
  let number key = O.lookup key obj >>= J.toNumber >>= Int.fromNumber
  os <- text "os"
  version <- text "version"
  port <- number "port"
  user <- text "user"
  password <- text "password"
  db <- text "db"
  branch <- text "branch"
  let cpus = fromMaybe 2 (number "cpus")
  let mem = fromMaybe 1024 (number "mem")
  if (os /= "linux" && os /= "freebsd" && os /= "netbsd") || port < 0 || port > 65535 || branch == "" || cpus <= 0 || mem <= 0 then Nothing
  else Just { os, version, port, user, password, db, branch, cpus, mem }
