-- | Same dialect/schema types as Rocksky's Drizzle bindings, specialized to
-- | Bun's synchronous SQLite driver so CLI metadata stays transactional.
module Drizzle.SQLite.BunSQLite (available, open, close) where

import Prelude
import Drizzle.Database (Database)
import Drizzle.Dialect (SQLite)
import Effect (Effect)

foreign import available :: Effect Boolean
foreign import open :: String -> Effect (Database SQLite)
foreign import close :: Database SQLite -> Effect Unit
