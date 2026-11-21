module Sbx.Profiles (all, find) where
import Prelude
import Data.Array as A
import Data.Maybe (Maybe)
import Sbx.Profile (Profile)
import Sbx.Postgres as Postgres
import Sbx.MariaDB as MariaDB
import Sbx.DuckDB as DuckDB
import Sbx.Sqlite as Sqlite
import Sbx.MySQL as MySQL
import Sbx.Typesense as Typesense
import Sbx.Chroma as Chroma

type Database = { name :: String, profile :: Profile }
all :: Array Database
all = [ {name: "postgres", profile: Postgres.profile}, {name: "mariadb", profile: MariaDB.profile}, {name: "duckdb", profile: DuckDB.profile}, {name: "sqlite", profile: Sqlite.profile}, {name: "mysql", profile: MySQL.profile}, {name: "typesense", profile: Typesense.profile}, {name: "chroma", profile: Chroma.profile} ]
find :: String -> Maybe Database
find name = A.find (\db -> db.name == canonical) all
  where
  canonical = case name of
    "postgresql" -> "postgres"
    "pg" -> "postgres"
    "libsql" -> "sqlite"
    _ -> name
