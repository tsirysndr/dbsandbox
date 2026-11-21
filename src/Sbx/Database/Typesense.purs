module Sbx.Database.Typesense (profile) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object
import Sbx.Database.Profile (ClientCmd(..), FancyCmd(..), Profile)

profile :: Profile
profile =
  { cli: "dbsandbox typesense"
  , tool: "typesense-sbx"
  , product: "Typesense"
  , engineMem: 2048
  , dockerArgs: []
  , hasDatabase: false
  , http: Just { health: "/health", headers: \c -> Object.singleton "X-TYPESENSE-API-KEY" c.password }
  , hasToken: true
  , keepStdin: false
  , containerDockerfile: Nothing
  , versionAllowed: const true
  , runtimeCheck: Nothing
  , serves: \_ _ -> true
  , guestPort: 8108
  , defaultTag: "30.2"
  , image: \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "typesense/typesense:" <> tag
  , versionNote: ""
  , linuxOnly: true
  , hasCredentials: false
  , defaults: { user: "", password: "", db: "typesense" }
  , dataDir: const "/data"
  , rootDisk: const Nothing
  , rootfsVolume: false
  , tools: Nothing
  , env: \c -> Object.fromFoldable [ "TYPESENSE_DATA_DIR" /\ "/data", "TYPESENSE_API_KEY" /\ c.password ]
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
  , driver: "typesense"
  }
