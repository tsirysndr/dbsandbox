module Test.Main where

import Prelude
import Effect (Effect)
import Test.Postgres as Postgres
import Test.MariaDB as MariaDB
import Test.DuckDB as DuckDB
import Test.Sqlite as Sqlite

main :: Effect Unit
main = Postgres.main *> MariaDB.main *> DuckDB.main *> Sqlite.main
