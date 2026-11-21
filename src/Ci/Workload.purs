-- | Protocol-specific persistence fixtures; lifecycle assertions are shared.
module Ci.Workload (Workload, find) where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Argonaut.Core as J
import Data.Tuple.Nested ((/\))
import Foreign.Object as O

type Workload = { seed :: Array (Array String), read :: Array String, write :: Array String, original :: String, forked :: String }

api :: String -> String -> String -> Array String
api method path body = [ "api", method, path ] <> if body == "" then [] else [ body ]

schemaJson :: String -> String
schemaJson schema = J.stringify (J.fromObject (O.singleton "schema" (J.fromString schema)))

sqlJson :: String -> String
sqlJson sql = J.stringify (J.fromObject (O.fromFoldable [ "sql" /\ J.fromString sql, "pagination" /\ J.fromObject (O.singleton "wait_time_secs" (J.fromNumber 10.0)) ]))

find :: String -> Maybe Workload
find name = map (\w -> { seed: w.seed, read: w.read, write: w.write, original: "original", forked: "forked" })
  ( case name of
      "qdrant" -> Just
        { seed: [ api "PUT" "/collections/e2e_values" "{\"vectors\":{\"size\":2,\"distance\":\"Cosine\"}}", api "PUT" "/collections/e2e_values/points?wait=true" "{\"points\":[{\"id\":1,\"vector\":[1,0],\"payload\":{\"marker\":\"original\"}}]}" ]
        , read: api "GET" "/collections/e2e_values/points/1" ""
        , write: api "PUT" "/collections/e2e_values/points?wait=true" "{\"points\":[{\"id\":1,\"vector\":[0,1],\"payload\":{\"marker\":\"forked\"}}]}"
        }
      "surrealdb" -> Just
        { seed: [ api "POST" "/sql" "DEFINE NAMESPACE IF NOT EXISTS sandbox; USE NS sandbox; DEFINE DATABASE IF NOT EXISTS sandbox; USE DB sandbox; CREATE e2e:one CONTENT {marker:'original'};" ]
        , read: api "POST" "/sql" "USE NS sandbox DB sandbox; SELECT marker FROM e2e:one;"
        , write: api "POST" "/sql" "USE NS sandbox DB sandbox; UPDATE e2e:one SET marker='forked';"
        }
      "arangodb" -> Just
        { seed: [ api "POST" "/_api/collection" "{\"name\":\"e2e_values\"}", api "POST" "/_api/document/e2e_values" "{\"_key\":\"one\",\"marker\":\"original\"}" ]
        , read: api "GET" "/_api/document/e2e_values/one" ""
        , write: api "PATCH" "/_api/document/e2e_values/one" "{\"marker\":\"forked\"}"
        }
      "clickhouse" -> Just
        { seed: [ api "POST" "/?database=sandbox" "CREATE TABLE e2e_values(marker String) ENGINE=MergeTree ORDER BY tuple()", api "POST" "/?database=sandbox" "INSERT INTO e2e_values VALUES ('original')" ]
        , read: api "POST" "/?database=sandbox" "SELECT marker FROM e2e_values ORDER BY marker LIMIT 1"
        , write: api "POST" "/?database=sandbox" "INSERT INTO e2e_values VALUES ('forked')"
        }
      "databend" -> Just
        { seed: [ api "POST" "/v1/query" (sqlJson "CREATE TABLE e2e_values(marker STRING)"), api "POST" "/v1/query" (sqlJson "INSERT INTO e2e_values VALUES ('original')") ]
        , read: api "POST" "/v1/query" (sqlJson "SELECT marker FROM e2e_values ORDER BY marker LIMIT 1")
        , write: api "POST" "/v1/query" (sqlJson "INSERT INTO e2e_values VALUES ('forked')")
        }
      "mongodb" -> Just
        { seed: [ [ "mongosh", "--quiet", "--eval", "db.e2e_values.insertOne({_id:'one',marker:'original'})" ] ]
        , read: [ "mongosh", "--quiet", "--eval", "JSON.stringify(db.e2e_values.findOne({_id:'one'}))" ]
        , write: [ "mongosh", "--quiet", "--eval", "db.e2e_values.updateOne({_id:'one'},{$set:{marker:'forked'}})" ]
        }
      name' | name' == "cassandra" || name' == "scylladb" -> Just
        { seed: [ [ "cqlsh", "-e", ("CREATE KEYSPACE e2e WITH replication={'class':'" <> (if name' == "scylladb" then "NetworkTopologyStrategy" else "SimpleStrategy") <> "','replication_factor':'1'}; CREATE TABLE e2e.items(id int PRIMARY KEY,marker text); INSERT INTO e2e.items(id,marker) VALUES(1,'original');") ] ]
        , read: [ "cqlsh", "-e", "SELECT marker FROM e2e.items WHERE id=1;" ]
        , write: [ "cqlsh", "-e", "UPDATE e2e.items SET marker='forked' WHERE id=1;" ]
        }
      "spicedb" -> Just
        { seed: [ api "POST" "/v1/schema/write" (schemaJson "definition user {}\ndefinition original {\n relation reader: user\n}\n") ]
        , read: api "POST" "/v1/schema/read" "{}"
        , write: api "POST" "/v1/schema/write" (schemaJson "definition user {}\ndefinition original {\n relation reader: user\n}\ndefinition forked {\n relation reader: user\n}\n")
        }
      "vearch" -> Just
        { seed: [ api "POST" "/dbs/original" "" ]
        , read: api "GET" "/dbs" ""
        , write: api "POST" "/dbs/forked" ""
        }
      _ -> Nothing
  )
