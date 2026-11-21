module Sbx.Database.Chroma (profile) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Foreign.Object as Object
import Sbx.Database.Profile (ClientCmd(..), FancyCmd(..), Profile)

profile :: Profile
profile =
  { cli: "dbsandbox chroma"
  , tool: "chroma-sbx"
  , product: "Chroma"
  , engineMem: 2048
  , dockerArgs: []
  , hasDatabase: false
  , http: Just { health: "/api/v2/heartbeat", headers: const Object.empty }
  , hasToken: false
  , keepStdin: false
  , containerDockerfile: Nothing
  , versionAllowed: const true
  , runtimeCheck: Nothing
  , serves: \_ _ -> true
  , guestPort: 8000
  , defaultTag: "1.5.3"
  , image: \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "chromadb/chroma:" <> tag
  , versionNote: ""
  , linuxOnly: true
  , hasCredentials: false
  , defaults: { user: "", password: "", db: "chroma" }
  , dataDir: const "/data"
  , rootDisk: const Nothing
  , rootfsVolume: false
  , tools: Nothing
  , env: const Object.empty
  , command: const Nothing
  , provision: const Nothing
  , ready: \_ _ _ -> []
  , client: Http
  , clientName: "api"
  , clientAliases: []
  , fancy: { name: "http", cmd: HttpTool }
  , url: \_ _ port -> "http://127.0.0.1:" <> show port
  , studioSupported: \_ _ -> false
  , migrations: Nothing
  , dialect: ""
  , driver: "chroma"
  }
