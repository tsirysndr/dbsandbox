module Sbx.Management.Catalog (rows, json) where

import Prelude
import Data.Argonaut.Core as J
import Data.Int as Int
import Data.Tuple.Nested ((/\))
import Foreign.Object as O
import Sbx.Database.Profiles as Profiles

type Database = { name :: String, product :: String, version :: String, image :: String, port :: Int, guests :: Array String }

rows :: Array Database
rows = map (\db -> { name: db.name, product: db.profile.product, version: db.profile.defaultTag, image: db.profile.image db.profile.defaultTag, port: db.profile.guestPort, guests: if db.profile.linuxOnly then [ "linux" ] else [ "linux", "freebsd", "netbsd" ] }) Profiles.all

json :: J.Json
json = J.fromArray $ map
  ( \r -> J.fromObject $ O.fromFoldable
      [ "name" /\ J.fromString r.name
      , "product" /\ J.fromString r.product
      , "version" /\ J.fromString r.version
      , "image" /\ J.fromString r.image
      , "port" /\ J.fromNumber (Int.toNumber r.port)
      , "guests" /\ J.fromArray (map J.fromString r.guests)
      ]
  )
  rows
