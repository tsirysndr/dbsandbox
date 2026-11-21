-- | Synchronous SQLite operations. Transactions must stay in Effect: an Aff
-- | callback could commit before its asynchronous work completes.
module Drizzle.Database (Database, execute, all, transaction) where

import Prelude
import Drizzle.Dialect (Dialect, SQLite)
import Drizzle.SQL (SQL)
import Effect (Effect)

foreign import data Database :: Dialect -> Type
foreign import execute :: Database SQLite -> SQL -> Effect Unit
foreign import all :: forall row. Database SQLite -> SQL -> Effect (Array (Record row))
foreign import transaction :: forall a. Database SQLite -> (Database SQLite -> Effect a) -> Effect a
