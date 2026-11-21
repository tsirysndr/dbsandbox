module Sbx.Database.Profiles (all, find) where

import Prelude
import Data.Array as A
import Data.Maybe (Maybe)
import Sbx.Database.Profile (Profile)
import Sbx.Database.Postgres as Postgres
import Sbx.Database.MariaDB as MariaDB
import Sbx.Database.DuckDB as DuckDB
import Sbx.Database.Sqlite as Sqlite
import Sbx.Database.MySQL as MySQL
import Sbx.Database.Typesense as Typesense
import Sbx.Database.Chroma as Chroma
import Sbx.Database.Services as Services

type Database = { name :: String, profile :: Profile }

all :: Array Database
all = [ { name: "postgres", profile: Postgres.profile }, { name: "mariadb", profile: MariaDB.profile }, { name: "duckdb", profile: DuckDB.profile }, { name: "sqlite", profile: Sqlite.profile }, { name: "mysql", profile: MySQL.profile }, { name: "typesense", profile: Typesense.profile }, { name: "chroma", profile: Chroma.profile } ] <> additional

find :: String -> Maybe Database
find name = A.find (\db -> db.name == canonical) all
  where
  canonical = case name of
    "postgresql" -> "postgres"
    "pg" -> "postgres"
    "libsql" -> "sqlite"
    "timescaledb" -> "timescale"
    "mongo" -> "mongodb"
    "cockroach" -> "cockroachdb"
    "scylla" -> "scylladb"
    "yugabyte" -> "yugabytedb"
    _ -> name

additional :: Array Database
additional = [ { name: "databend", profile: Services.databend }, { name: "tigerbeetle", profile: Services.tigerbeetle }, { name: "yugabytedb", profile: Services.yugabytedb }, { name: "vearch", profile: Services.vearch }, { name: "timescale", profile: Services.timescale }, { name: "tidb", profile: Services.tidb }, { name: "spicedb", profile: Services.spicedb }, { name: "surrealdb", profile: Services.surrealdb }, { name: "scylladb", profile: Services.scylladb }, { name: "qdrant", profile: Services.qdrant }, { name: "mongodb", profile: Services.mongodb }, { name: "cassandra", profile: Services.cassandra }, { name: "clickhouse", profile: Services.clickhouse }, { name: "arangodb", profile: Services.arangodb }, { name: "cockroachdb", profile: Services.cockroachdb } ]
