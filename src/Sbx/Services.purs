-- | Linux development profiles. Every persistent component lives on its branch.
module Sbx.Services where
import Prelude
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Tuple.Nested ((/\))
import Foreign.Object as O
import Sbx.Profile (Profile, Creds, ClientCmd(..), FancyCmd(..), shellQuote)
import Sbx.Typesense as Typesense
import Sbx.Postgres as Postgres
import Sbx.MySQL as MySQL
import Sbx.Native as N

image :: String -> String -> String
image repo tag = if S.contains (S.Pattern "/") tag || S.contains (S.Pattern ":") tag then tag else repo <> ":" <> tag
http :: String -> String -> String -> Int -> String -> String -> Profile
http name product repo port dir health = Typesense.profile
  { cli = "dbsandbox " <> name, tool = name <> "-sbx", product = product
  , image = image repo, defaultTag = "latest", guestPort = port
  , dockerArgs = nofile
  , dataDir = const dir, hasToken = false, hasCredentials = false
  , defaults = {user: "", password: "", db: name}, env = const O.empty
  , http = Just {health, headers: const O.empty}, driver = name
  }
basic :: Creds -> O.Object String
basic c = O.singleton "Authorization" (N.basicAuth c.user c.password)
script :: String -> Array String -> String
script path lines = "RUN printf '%s\\n' " <> S.joinWith " " (map shellQuote (["#!/bin/sh", "set -eu"] <> lines)) <> " > " <> path <> " && chmod 755 " <> path
nofile :: Array String
nofile = ["--ulimit", "nofile=65536:65536"]

qdrant :: Profile
qdrant = (http "qdrant" "Qdrant" "qdrant/qdrant" 6333 "/qdrant/storage" "/healthz")
  {hasToken = true, env = \c -> O.singleton "QDRANT__SERVICE__API_KEY" c.password
  , http = Just {health: "/healthz", headers: \c -> O.singleton "api-key" c.password}}
surrealdb :: Profile
surrealdb = (http "surrealdb" "SurrealDB" "surrealdb/surrealdb" 8000 "/data" "/health")
  {hasCredentials = true, defaults = {user: "root", password: "surrealdb", db: "sandbox"}
  , env = \c -> O.fromFoldable ["SURREAL_USER" /\ c.user, "SURREAL_PASS" /\ c.password]
  , dockerArgs = ["--user", "0:0"]
  , command = const (Just ["start", "--bind", "0.0.0.0:8000", "surrealkv:/data/database"])
  , http = Just {health: "/health", headers: \c -> O.insert "Content-Type" "text/plain" (basic c)}}
arangodb :: Profile
arangodb = (http "arangodb" "ArangoDB" "arangodb" 8529 "/var/lib/arangodb3" "/_api/version")
  {hasCredentials = false, hasToken = true, dockerArgs = nofile, defaults = {user: "root", password: "arangodb", db: "_system"}
  , env = \c -> O.singleton "ARANGO_ROOT_PASSWORD" c.password
  , command = const (Just ["--javascript.app-path", "/var/lib/arangodb3/apps"])
  , http = Just {health: "/_api/version", headers: basic}}
clickhouse :: Profile
clickhouse = (http "clickhouse" "ClickHouse" "clickhouse/clickhouse-server" 8123 "/var/lib/clickhouse" "/ping")
  {hasCredentials = true, hasDatabase = true, engineMem = 6144, defaults = {user: "default", password: "clickhouse", db: "sandbox"}
  , dockerArgs = nofile
  , env = \c -> O.fromFoldable ["CLICKHOUSE_USER" /\ c.user, "CLICKHOUSE_PASSWORD" /\ c.password, "CLICKHOUSE_DB" /\ c.db, "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT" /\ "1"]
  , http = Just {health: "/ping", headers: basic}
  , client = Guest \_ _ c -> ["clickhouse-client", "--host", "127.0.0.1", "--user", c.user, "--password=" <> c.password, "--database", c.db]
  , clientName = "clickhouse", clientAliases = ["sql"]}
mongodb :: Profile
mongodb = (http "mongodb" "MongoDB" "mongo" 27017 "/data/db" "")
  {defaultTag = "8", http = Nothing, hasCredentials = true, hasDatabase = true
  , defaults = {user: "root", password: "mongodb", db: "sandbox"}
  , env = \c -> O.fromFoldable ["MONGO_INITDB_ROOT_USERNAME" /\ c.user, "MONGO_INITDB_ROOT_PASSWORD" /\ c.password, "MONGO_INITDB_DATABASE" /\ c.db]
  , url = \_ c port -> mongoUrl c port
  , ready = \_ _ c -> ["sh", "-c", "test $(cat /proc/1/comm) = mongod && exec mongosh " <> shellQuote (mongoUrl c 27017) <> " --quiet --eval 'if (!db.runCommand({ping:1}).ok) quit(1)'"]
  , client = Guest \_ _ c -> ["mongosh", mongoUrl c 27017]
  , clientName = "mongosh", fancy = {name: "mongo", cmd: GuestTool \_ _ c -> ["mongosh", mongoUrl c 27017]}}
mongoUrl :: Creds -> Int -> String
mongoUrl c port = "mongodb://" <> N.encodeURIComponent c.user <> ":" <> N.encodeURIComponent c.password <> "@127.0.0.1:" <> show port <> "/" <> N.encodeURIComponent c.db <> "?authSource=admin"

cassandra :: Profile
cassandra = (http "cassandra" "Cassandra" "cassandra" 9042 "/var/lib/cassandra" "")
  {defaultTag = "5", engineMem = 6144, http = Nothing, dockerArgs = nofile
  , containerDockerfile = Just \tag -> S.joinWith "\n"
      ["FROM " <> image "cassandra" tag
      , "RUN sed -i -e '/^commitlog_sync:/d' -e '/^commitlog_sync_period/d' /etc/cassandra/cassandra.yaml && printf '\\ncommitlog_sync: batch\\n' >> /etc/cassandra/cassandra.yaml"]
  , env = const (O.fromFoldable ["MAX_HEAP_SIZE" /\ "512M", "HEAP_NEWSIZE" /\ "100M", "CASSANDRA_CLUSTER_NAME" /\ "dbsandbox", "CASSANDRA_RPC_ADDRESS" /\ "0.0.0.0"])
  , ready = \_ _ _ -> ["cqlsh", "127.0.0.1", "9042", "-e", "SELECT release_version FROM system.local;"]
  , client = Guest \_ _ _ -> ["cqlsh", "127.0.0.1", "9042"]
  , clientName = "cqlsh", fancy = {name: "cql", cmd: GuestTool \_ _ _ -> ["cqlsh", "127.0.0.1", "9042"]}
  , url = \_ _ port -> "cassandra://127.0.0.1:" <> show port}
scylladb :: Profile
scylladb = cassandra
  {cli = "dbsandbox scylladb", tool = "scylladb-sbx", product = "ScyllaDB", driver = "scylladb"
  , image = image "scylladb/scylla", defaultTag = "latest", dataDir = const "/var/lib/scylla", env = const O.empty
  , containerDockerfile = Just \tag -> S.joinWith "\n"
      ["FROM " <> image "scylladb/scylla" tag, "USER 0"
      , "RUN sed -i -e '/^commitlog_sync:/d' -e '/^commitlog_sync_period/d' /etc/scylla/scylla.yaml && printf '\\ncommitlog_sync: batch\\n' >> /etc/scylla/scylla.yaml && chown scylla:scylla /etc/scylla/scylla.yaml"
      , script "/usr/local/bin/sbx-start" ["chown -R \"$(id -u scylla):$(id -g scylla)\" /var/lib/scylla", "chown scylla:scylla /proc/self/fd/1 /proc/self/fd/2", "exec runuser -u scylla -- /docker-entrypoint.py \"$@\""]
      , "ENTRYPOINT [\"/usr/local/bin/sbx-start\"]"]
  , command = const (Just ["--smp", "1", "--memory", "1536M", "--overprovisioned", "1", "--developer-mode", "1", "--rpc-address", "0.0.0.0", "--broadcast-rpc-address", "127.0.0.1"])}

-- PostgreSQL-wire services retain the shared host driver and Drizzle tools.
timescale :: Profile
timescale = Postgres.profile
  {cli = "dbsandbox timescale", tool = "timescale-sbx", product = "TimescaleDB"
  , linuxOnly = true, provision = const Nothing, rootDisk = const Nothing, migrations = Nothing
  , image = image "timescale/timescaledb", defaultTag = "latest-pg18"
  , dataDir = const "/var/lib/postgresql"
  , env = \c -> O.insert "PGDATA" "/var/lib/postgresql/pgdata" (Postgres.profile.env c)}
yugabytedb :: Profile
yugabytedb = Postgres.profile
  {cli = "dbsandbox yugabytedb", tool = "yugabytedb-sbx", product = "YugabyteDB"
  , linuxOnly = true, provision = const Nothing, rootDisk = const Nothing, migrations = Nothing
  , image = image "yugabytedb/yugabyte", defaultTag = "2026.1.3.0-b100", engineMem = 6144, guestPort = 5433
  , dataDir = const "/home/yugabyte/yb_data", dockerArgs = ["--hostname", "dbsandbox-node"] <> nofile
  , containerDockerfile = Just \tag -> S.joinWith "\n"
      ["FROM " <> image "yugabytedb/yugabyte" tag, "USER 0"
      , script "/usr/local/bin/sbx-start" ["chown -R \"$(id -u yugabyte):$(id -g yugabyte)\" /home/yugabyte/yb_data", "exec runuser -u yugabyte -- \"$@\""]
      , "ENTRYPOINT [\"/sbin/tini\", \"--\", \"/usr/local/bin/sbx-start\"]"]
  , defaults = {user: "yugabyte", password: "", db: "yugabyte"}, hasCredentials = false, hasDatabase = false, env = const O.empty
  , command = const (Just ["bin/yugabyted", "start", "--base_dir=/home/yugabyte/yb_data", "--background=false", "--advertise_address=127.0.0.1", "--callhome=false", "--master_flags=memory_limit_hard_bytes=268435456", "--tserver_flags=memory_limit_hard_bytes=536870912,pgsql_proxy_bind_address=0.0.0.0:5433"])
  , ready = \_ _ _ -> ["/home/yugabyte/bin/ysqlsh", "-h", "127.0.0.1", "-p", "5433", "-U", "yugabyte", "-d", "yugabyte", "-tAc", "SELECT 1"]
  , client = Guest \_ _ _ -> ["/home/yugabyte/bin/ysqlsh", "-h", "127.0.0.1", "-p", "5433", "-U", "yugabyte", "-d", "yugabyte"]
  , clientName = "ysqlsh"}
cockroachdb :: Profile
cockroachdb = Postgres.profile
  {cli = "dbsandbox cockroachdb", tool = "cockroachdb-sbx", product = "CockroachDB"
  , linuxOnly = true, provision = const Nothing, rootDisk = const Nothing, migrations = Nothing
  , image = image "cockroachdb/cockroach", defaultTag = "latest", guestPort = 26257
  , dockerArgs = nofile <> ["--entrypoint", "/cockroach/cockroach"]
  , dataDir = const "/cockroach/cockroach-data", defaults = {user: "root", password: "", db: "defaultdb"}
  , hasCredentials = false, hasDatabase = false, env = const O.empty
  , command = const (Just ["start-single-node", "--insecure", "--store=/cockroach/cockroach-data", "--listen-addr=0.0.0.0:26257", "--advertise-addr=127.0.0.1:26257", "--cache=128MiB", "--max-sql-memory=128MiB"])
  , ready = \_ _ _ -> ["/cockroach/cockroach", "sql", "--insecure", "--host=127.0.0.1:26257", "--execute=SELECT 1"]
  , client = Guest \_ _ _ -> ["/cockroach/cockroach", "sql", "--insecure", "--host=127.0.0.1:26257", "--database=defaultdb"]
  , clientName = "cockroach", clientAliases = ["sql"], dialect = ""}

tidb :: Profile
tidb = MySQL.profile
  {cli = "dbsandbox tidb", tool = "tidb-sbx", product = "TiDB", linuxOnly = true
  , provision = const Nothing, rootDisk = const Nothing, guestPort = 4000, dataDir = const "/data"
  , dockerArgs = nofile
  , defaultTag = "latest", image = image "pingcap/tidb", hasCredentials = false, hasDatabase = false
  , defaults = {user: "root", password: "", db: "test"}, env = const O.empty
  , containerDockerfile = Nothing
  , command = const (Just ["--store=unistore", "--path=/data/tidb", "--host=0.0.0.0", "-P=4000"])
  , ready = \_ _ _ -> ["curl", "-fsS", "http://127.0.0.1:10080/status"]
  , tools = Just {image: "dbsandbox-mysql-tools", dockerfile: "FROM mysql:8.4\n"}
  , client = Guest \_ _ _ -> ["mysql", "--protocol=TCP", "-h", "127.0.0.1", "-P", "4000", "-u", "root", "test"]}

databend :: Profile
databend = (http "databend" "Databend" "datafuselabs/databend" 8000 "/var/lib/databend" "/v1/health")
  {hasCredentials = true, engineMem = 6144, defaults = {user: "databend", password: "databend", db: "default"}
  , env = \c -> O.fromFoldable ["QUERY_DEFAULT_USER" /\ c.user, "QUERY_DEFAULT_PASSWORD" /\ c.password, "QUERY_STORAGE_TYPE" /\ "fs"]
  , http = Just {health: "", headers: basic}
  , ready = \_ _ _ -> ["curl", "-fsS", "http://127.0.0.1:8080/v1/health"]}

spicedb :: Profile
spicedb = (http "spicedb" "SpiceDB" "authzed/spicedb" 8443 "/data" "")
  {hasToken = true, keepStdin = true
  , http = Just {health: "", headers: \c -> O.singleton "Authorization" ("Bearer " <> c.password)}
  , env = \c -> O.fromFoldable ["SPICEDB_GRPC_PRESHARED_KEY" /\ c.password, "SPICEDB_DATASTORE_ENGINE" /\ "postgres", "SPICEDB_DATASTORE_CONN_URI" /\ "postgres://postgres@127.0.0.1:5432/spicedb?sslmode=disable", "SPICEDB_HTTP_ENABLED" /\ "true", "SPICEDB_HTTP_ADDR" /\ "0.0.0.0:8443"]
  , containerDockerfile = Just \tag -> S.joinWith "\n"
      ["FROM " <> image "authzed/spicedb" tag <> " AS upstream", "FROM postgres:17-bookworm"
      , "COPY --from=upstream /usr/local/bin/spicedb /usr/local/bin/spicedb"
      , "COPY --from=upstream /usr/local/bin/grpc_health_probe /usr/local/bin/grpc_health_probe"
      , script "/usr/local/bin/sbx-start" ["mkdir -p /data/postgres; chown postgres:postgres /data/postgres", "if [ ! -f /data/postgres/PG_VERSION ]; then gosu postgres initdb -D /data/postgres --auth=trust; fi", "gosu postgres pg_ctl -D /data/postgres -o '-h 127.0.0.1 -c track_commit_timestamp=on' -w start", "if ! gosu postgres psql -h 127.0.0.1 -tAc \"SELECT 1 FROM pg_database WHERE datname='spicedb'\" | grep -q 1; then gosu postgres createdb -h 127.0.0.1 spicedb; fi", "spicedb datastore migrate head --skip-release-check=true", "exec spicedb serve --skip-release-check=true"]
      , "ENTRYPOINT [\"/usr/local/bin/sbx-start\"]"]
  , ready = \_ _ _ -> ["grpc_health_probe", "-addr=127.0.0.1:50051"]}

tigerbeetle :: Profile
tigerbeetle = (http "tigerbeetle" "TigerBeetle" "ghcr.io/tigerbeetle/tigerbeetle" 3000 "/data" "")
  {http = Nothing, engineMem = 6144, dockerArgs = nofile <> ["--security-opt", "seccomp=unconfined", "--ulimit", "memlock=-1:-1"]
  , containerDockerfile = Just \tag -> S.joinWith "\n"
      ["FROM " <> image "ghcr.io/tigerbeetle/tigerbeetle" tag <> " AS upstream", "FROM debian:bookworm-slim"
      , "COPY --from=upstream /tigerbeetle /usr/local/bin/tigerbeetle"
      , script "/usr/local/bin/sbx-start" ["if [ ! -f /data/0_0.tigerbeetle ]; then tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development /data/0_0.tigerbeetle; fi", "exec tigerbeetle start --addresses=0.0.0.0:3000 --development --cache-grid=256MiB /data/0_0.tigerbeetle"]
      , "ENTRYPOINT [\"/usr/local/bin/sbx-start\"]"]
  , ready = \_ _ _ -> ["sh", "-c", "reply=$(timeout 5 tigerbeetle repl --cluster=0 --addresses=127.0.0.1:3000 '--command=lookup_accounts id=1;' 2>&1) && exit 0; printf '%s\\n' \"$reply\" | grep -Fxq 'No accounts were found.'"]
  , client = Guest \_ _ _ -> ["tigerbeetle", "repl", "--cluster=0", "--addresses=127.0.0.1:3000"]
  , clientName = "repl", fancy = {name: "tb", cmd: GuestTool \_ _ _ -> ["tigerbeetle", "repl", "--cluster=0", "--addresses=127.0.0.1:3000"]}
  , url = \_ _ port -> "tigerbeetle://127.0.0.1:" <> show port <> "?cluster=0"}

vearch :: Profile
vearch = (http "vearch" "Vearch" "vearch/vearch" 9001 "/data" "/")
  {containerDockerfile = Just \tag -> S.joinWith "\n"
    ["FROM " <> image "vearch/vearch" tag
    , "RUN printf '%s\\n' " <> S.joinWith " " (map shellQuote vearchConfig) <> " > /vearch/config.toml"]}
vearchConfig :: Array String
vearchConfig =
  ["[global]", "name = 'dbsandbox'", "resource_name = 'default'", "data = ['/data']", "log = '/data/logs'", "level = 'info'", "signkey = 'dbsandbox'", "skip_auth = true", "self_manage_etcd = false"
  , "[[masters]]", "name = 'm1'", "address = '127.0.0.1'", "api_port = 8817", "etcd_port = 2378", "etcd_peer_port = 2390", "etcd_client_port = 2370", "cluster_state = 'new'"
  , "[router]", "port = 9001", "[ps]", "rpc_port = 8081", "raft_heartbeat_port = 8898", "raft_replicate_port = 8899"]
