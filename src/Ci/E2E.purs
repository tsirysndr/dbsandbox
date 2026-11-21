module Ci.E2E (run, sandboxCli, redact) where

import Prelude
import Ci.Database as Database
import Ci.Workload as Workload
import Ci.Common as C
import Ci.Install as Install
import Ci.Native as N
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Either (Either(..), either)
import Data.Foldable (any, for_)
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt, bracket, forkAff, killFiber, finally, delay)
import Data.Time.Duration (Milliseconds(..))
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (message, error)
import Effect.Ref as Ref
import Foreign.Object as O
import Node.Process (setExitCode)
import Sbx.App as App
import Sbx.Cli as Cli
import Sbx.Profiles as Profiles
import Sbx.Profile (Profile)
import Sbx.Http as Http

type Context =
  { database :: String, profile :: Profile, name :: String, scratch :: String, logDir :: String, log :: String
  , env :: O.Object String, runtime :: String, node :: String, version :: String
  , password :: String, started :: Ref.Ref Boolean, engineWasRunning :: Ref.Ref Boolean
  , occupied :: Ref.Ref (Maybe N.Port), succeeded :: Ref.Ref Boolean
  }

type Options = { allowFailure :: Boolean, secret :: Boolean, timeout :: Int, env :: O.Object String }
defaultOptions :: Options
defaultOptions = { allowFailure: false, secret: false, timeout: 300000, env: O.empty }

redact :: Array String -> Array String
redact args = A.mapWithIndex (\i arg -> if A.index args (i - 1) == Just "--password" then "<redacted>" else arg) args

redactText :: Context -> String -> String
redactText c = S.replaceAll (S.Pattern c.password) (S.Replacement "<redacted>")

record :: Context -> String -> Aff Unit
record c text = liftEffect $ N.appendText c.log (redactText c text <> "\n")
pass :: Context -> String -> Aff Unit
pass c text = liftEffect (Console.error ("PASS: " <> text)) *> record c ("PASS: " <> text)

command :: Context -> Options -> String -> Array String -> Aff N.Result
command c options program args = do
  let label = redactText c (program <> " " <> S.joinWith " " (redact args))
  liftEffect (N.stream ("[e2e] $ " <> label <> "\n"))
  unless options.secret $ record c ("$ " <> label)
  let output chunk = unless options.secret (N.appendText c.log (redactText c chunk) *> N.stream (redactText c chunk))
  heartbeat <- forkAff (waiting label 15)
  result <- finally (killFiber (error "command completed") heartbeat) $
    N.command { program, args, env: O.union options.env c.env, timeout: options.timeout, cwd: "", output }
  C.demand (program <> " failed (" <> show result.code <> ")" <> if options.secret then "" else ": " <> redactText c result.stderr) (options.allowFailure || result.code == 0)
  pure result
  where
  waiting label seconds = do
    delay (Milliseconds 15000.0)
    liftEffect $ N.stream ("[e2e] still running (" <> show seconds <> "s): " <> label <> "\n")
    waiting label (seconds + 15)

cliWith :: Context -> Options -> Array String -> Aff N.Result
cliWith c options args = command c options c.node ([ "bin/ci.js", "sandbox-cli", c.database, c.name ] <> args)
cli :: Context -> Array String -> Aff String
cli c args = S.trim <<< _.stdout <$> cliWith c defaultOptions args
runtime :: Context -> Array String -> Aff String
runtime c args = _.stdout <$> command c defaultOptions c.runtime args

query :: Context -> String -> Aff String
query c = queryAt c []

queryAt :: Context -> Array String -> String -> Aff String
queryAt c selected = queryWith c selected Nothing

queryWith :: Context -> Array String -> Maybe String -> String -> Aff String
queryWith c selected override sql = do
  uri <- cliWith c (defaultOptions { secret = true }) (selected <> [ "url" ])
  let address = case override of
        Nothing -> S.trim uri.stdout
        Just wrong -> S.replaceAll (S.Pattern c.password) (S.Replacement wrong) (S.trim uri.stdout)
  if c.profile.driver == "quack" then do
    token <- case override of
      Just wrong -> pure wrong
      Nothing -> S.trim <<< _.stdout <$> cliWith c (defaultOptions {secret = true}) (selected <> ["token"])
    let attachSql = "ATTACH '" <> address <> "' AS sandbox (TOKEN getenv('DBSANDBOX_E2E_PASSWORD')); CONNECT sandbox;"
    result <- command c (defaultOptions {allowFailure = true, env = O.singleton "DBSANDBOX_E2E_PASSWORD" token}) (c.scratch <> "/client/duckdb")
      [":memory:", "-no-agent", "-no-init", "-bail", "-noheader", "-csv", "-cmd", attachSql, "-c", sql]
    C.demand "Quack query failed" (result.code == 0)
    pure (S.trim result.stdout)
  else do
    rows <- Database.query { driver: c.profile.driver, url: address, sql }
    pure (S.joinWith "\n" (map (S.joinWith ",") rows))

assertEqual :: String -> String -> Aff Unit
assertEqual expected actual = C.demand ("Expected " <> show expected <> ", got " <> show actual) (actual == expected)

freePort :: Aff Int
freePort = bracket N.reservePort (N.closePort <<< _.handle) (\p -> if p.port < 65533 then pure p.port else freePort)

setup :: String -> Aff Context
setup requested = do
  db <- C.fromEither $ case Profiles.find requested of
    Just found -> Right found
    Nothing -> Left "Unknown database profile"
  let database = db.name
  let profile = db.profile
  C.prepareRuntime
  name <- (\nonce -> "dbsandbox-" <> database <> "-e2e-" <> nonce) <$> liftEffect (N.randomHex 6)
  password <- ("e2e-" <> _) <$> liftEffect (N.randomHex 24)
  scratch <- liftEffect (N.tempDir "dbsandbox-e2e-")
  guest <- C.fallback "SBX_E2E_OS" "linux"
  logDir <- C.fallback "DBSANDBOX_E2E_LOG_DIR" (".fluentci/test-logs/" <> database <> "/" <> guest) >>= liftEffect <<< N.resolve
  let log = logDir <> "/e2e.log"
  liftEffect (N.mkdir logDir *> N.writeText log "")
  runtimePath <- C.bsdkrun
  node <- liftEffect N.node
  version <- C.projectVersion
  started <- liftEffect (Ref.new false)
  engineWasRunning <- liftEffect (Ref.new true)
  occupied <- liftEffect (Ref.new Nothing)
  succeeded <- liftEffect (Ref.new false)
  pure { database, profile, name, scratch, logDir, log, node, version, password, started, engineWasRunning, occupied, succeeded
       , runtime: runtimePath
       , env: O.fromFoldable [ "XDG_CONFIG_HOME" /\ (scratch <> "/config"), "NO_COLOR" /\ "1", "BSDKRUN_NO_AUTO_INSTALL" /\ "1" ] }

body :: Context -> Aff Unit
body c = do
  before <- runtime c [ "docker", "status", "--json" ] >>= C.fromEither <<< C.jsonSuffix
  wasRunning <- C.fromEither (C.boolField "running" before)
  liftEffect (Ref.write wasRunning c.engineWasRunning)
  void $ runtime c [ "probe" ]
  machines <- runtime c [ "ps", "--all", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
  volumes <- runtime c [ "zfs", "ls", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
  let named item = C.stringField "name" item == Right c.name
  C.demand "E2E sandbox already exists" (not (any named machines || any named volumes))
  binary <- liftEffect (N.resolve "dist/dbsandbox")
  result <- command c defaultOptions binary [ "--version" ]
  assertEqual ("dbsandbox " <> c.version) (S.trim result.stdout)
  guest <- C.fallback "SBX_E2E_OS" "linux"
  C.demand "Expected linux, freebsd or netbsd" (A.elem guest ["linux", "freebsd", "netbsd"])
  when (c.profile.driver == "quack") do
    host <- liftEffect N.platform
    let os = if host.os == "darwin" then "osx" else host.os
    let arch = if host.arch == "x64" then "amd64" else host.arch
    liftEffect (N.mkdir (c.scratch <> "/client"))
    void $ command c defaultOptions "curl" ["-fsSL", "--retry", "3", "https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-cli-" <> os <> "-" <> arch <> ".tar.gz", "-o", c.scratch <> "/client.tar.gz"]
    void $ command c defaultOptions "tar" ["-xzf", c.scratch <> "/client.tar.gz", "-C", c.scratch <> "/client"]
    liftEffect (N.chmod (c.scratch <> "/client/duckdb") 493)
  port <- freePort
  liftEffect (Ref.write true c.started)
  void $ cliWith c (defaultOptions { timeout = 600000 })
    ([ "start", guest ] <> (if guest == "linux" then [c.profile.defaultTag] else ["--mem", "2048"]) <> [ "--port", show port, "-d" ] <> (if c.profile.hasCredentials then [ "--user", "sbx_e2e", "--password", c.password, "--db", "sbx_e2e" ] else if c.profile.hasToken then ["--password", c.password] else []))
  query c "SELECT 42;" >>= assertEqual "42"
  let sqlArgs = case c.database of
        name | name == "postgres" || name == "timescale" || name == "yugabytedb" -> [c.profile.clientName, "-tAc", "SELECT 42;"]
        "cockroachdb" -> ["cockroach", "--format=tsv", "--execute=SELECT 42"]
        "tidb" -> ["mysql", "-N", "-B", "-e", "SELECT 42;"]
        "mysql" -> ["mysql", "-N", "-B", "-e", "SELECT 42;"]
        "mariadb" -> ["mariadb", "-N", "-B", "-e", "SELECT 42;"]
        "duckdb" -> ["duckdb", "-noheader", "-csv", "-c", "SELECT 42;"]
        _ -> ["sqlite3", "SELECT 42;"]
  output <- cli c sqlArgs
  if c.database == "cockroachdb" then C.demand "Cockroach SQL client failed" (S.contains (S.Pattern "42") output) else assertEqual "42" output
  when (c.profile.hasCredentials || c.profile.hasToken) do
    rejected <- attempt $ queryWith c [] (Just "wrong-password") "SELECT 1;"
    C.demand "Incorrect password was accepted" (either (const true) (const false) rejected)
  pass c "host driver authenticated and reached the sandbox through its forwarded port"
  void $ query c "CREATE TABLE e2e_values (n INTEGER);"
  void $ query c "INSERT INTO e2e_values VALUES (42);"
  when (guest == "linux" && not wasRunning) do
    Install.verifyDriver c.runtime
    void $ runtime c [ "docker", "stop" ]
    void $ cli c [ "start", "-d" ]
    Install.verifyDriver c.runtime
    query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
    pass c "normal startup creates an overlay/ext4 engine and preserves it across VM restart"
  void $ cli c [ "branch", "feature" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ queryAt c ["--branch", "feature"] "UPDATE e2e_values SET n=7;"
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ cli c [ "branch", "nested", "--from", "feature" ]
  queryAt c ["--branch", "nested"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "checkout", "feature" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "checkout", "main" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ cli c [ "stop" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "start", "-d" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  void $ cli c [ "--branch", "feature", "stop" ]
  queryAt c ["--branch", "nested"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  when (guest /= "linux") do
    void $ runtime c ["stop", c.name]
    void $ cli c ["start", "-d"]
    queryAt c ["--branch", "nested"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
    stoppedFork <- cli c ["--branch", "feature", "status"]
    C.demand "A stopped fork restarted with the BSD VM" (S.contains (S.Pattern "STOPPED") stoppedFork)
  void $ cli c [ "--branch", "feature", "start", "-d" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "branch", "-d", "nested" ]
  queryAt c ["--branch", "feature"] "SELECT n FROM e2e_values;" >>= assertEqual "7"
  void $ cli c [ "branch", "-d", "feature" ]
  query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
  pass c "parallel containers, nested forks, focus changes, independent stops and ZFS isolation"

  when (guest == "linux") do
    void $ cli c [ "stop" ]
    stopped <- cli c [ "status" ]
    C.demand "Sandbox did not stop" (S.contains (S.Pattern "STOPPED") stopped)
    collisionPort <- N.reservePort
    liftEffect (Ref.write (Just collisionPort.handle) c.occupied)
    collision <- cliWith c (defaultOptions { allowFailure = true }) [ "start", "--port", show collisionPort.port, "-d" ]
    C.demand "Occupied port was accepted" (collision.code /= 0)
    N.closePort collisionPort.handle
    liftEffect (Ref.write Nothing c.occupied)
    nextPort <- freePort
    void $ cli c [ "start", "--port", show nextPort, "-d" ]
    query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
    void $ cli c [ "stop" ]
    void $ cli c [ "start", "-d" ]
    query c "SELECT n FROM e2e_values;" >>= assertEqual "42"
    pass c "occupied ports fail clearly; port changes and stop/start preserve data"
  liftEffect (Ref.write true c.succeeded)

cleanup :: Context -> Aff Unit
cleanup c = do
  result <- attempt do
    occupied <- liftEffect (Ref.read c.occupied)
    for_ occupied N.closePort
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "ps", "--all", "--json" ]
    -- Capture the actual post-restart mount/driver state, not just whether
    -- the host data.img file exists. No state files or credentials are copied.
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "docker", "status", "--json" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "cat", "/proc/mounts" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "stat", "-f", "-c", "%T", "/var/lib/docker" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "cat", "/proc/1/limits" ]
    started <- liftEffect (Ref.read c.started)
    when started do
      void $ cliWith c (defaultOptions { allowFailure = true, timeout = 15000 }) [ "log" ]
      void $ cliWith c (defaultOptions { timeout = 120000 }) [ "destroy", "--yes" ]
    after <- runtime c [ "zfs", "ls", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
    C.demand "E2E data volume leaked" (not (any (\j -> C.stringField "name" j == Right c.name) after))
    wasRunning <- liftEffect (Ref.read c.engineWasRunning)
    unless wasRunning do
      running <- runtime c [ "docker", "ps", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
      when (A.null running) $ void $ runtime c [ "docker", "stop" ]
    pass c "temporary sandbox removed; existing engine/services preserved"
  succeeded <- liftEffect (Ref.read c.succeeded)
  let ok = succeeded && either (const false) (const true) result
  liftEffect do
    N.writeText (c.logDir <> "/result.json") $ J.stringify $ J.fromObject $ O.fromFoldable
      [ "passed" /\ J.fromBoolean ok, "sandbox" /\ J.fromString c.name ]
    N.remove c.scratch
  case result of
    Left err -> record c ("CLEANUP FAILED: " <> message err) *> throwError err
    Right _ -> pure unit

run :: String -> Aff Unit
run database = bracket (setup database) cleanup \c -> do
  result <- attempt (case Workload.find c.database of
    Just workload -> bodyWorkload c workload
    Nothing -> if c.database == "tigerbeetle" then bodyWorkload c tigerWorkload else if c.database == "typesense" || c.database == "chroma" then bodyApi c else body c)
  case result of
    Left err -> record c ("FAIL: " <> message err) *> throwError err
    Right _ -> pure unit

sandboxCli :: String -> String -> Array String -> Aff Unit
sandboxCli database name args = do
  db <- C.fromEither $ case Profiles.find database of
    Just found -> Right found
    Nothing -> Left "Unknown database profile"
  C.demand "Missing isolated E2E sandbox name" (C.matches ("^dbsandbox-" <> db.name <> "-e2e-[a-f0-9]{12}$") name)
  version <- C.projectVersion
  let isolated = db.profile { tool = name }
  cmd <- liftEffect (N.setArgs args *> Cli.parseCommand isolated version)
  App.run isolated cmd >>= liftEffect <<< setExitCode

-- API databases exercise the same branch manager with collections instead of SQL.
api :: Context -> Array String -> String -> String -> String -> Aff String
api c selected method path payload = cli c (selected <> ["api", method, path] <> if payload == "" then [] else [payload])

bodyApi :: Context -> Aff Unit
bodyApi c = do
  before <- runtime c ["docker", "status", "--json"] >>= C.fromEither <<< C.jsonSuffix
  wasRunning <- C.fromEither (C.boolField "running" before)
  liftEffect (Ref.write wasRunning c.engineWasRunning)
  port <- freePort
  liftEffect (Ref.write true c.started)
  void $ cliWith c (defaultOptions {timeout = 600000}) (["start", "linux", c.profile.defaultTag, "--port", show port, "-d"] <> if c.profile.hasToken then ["--password", c.password] else [])
  let path = if c.database == "typesense" then "/collections" else "/api/v2/tenants/default_tenant/databases/default_database/collections"
  let collection name = if c.database == "typesense" then "{\"name\":\"" <> name <> "\",\"fields\":[{\"name\":\"title\",\"type\":\"string\"}]}" else "{\"name\":\"" <> name <> "\"}"
  let check selected expected = do
        listing <- api c selected "GET" path ""
        C.demand ("Collection missing: " <> expected) (S.contains (S.Pattern expected) listing)
  void $ api c [] "POST" path (collection "main_collection")
  check [] "main_collection"
  when c.profile.hasToken do
    cli c ["token"] >>= assertEqual c.password
    address <- cli c ["url"]
    rejected <- Http.request address (O.singleton "X-TYPESENSE-API-KEY" "wrong-key") {method: "GET", path, body: ""} 5000
    C.demand "Typesense accepted an incorrect API key" (rejected.status == 401)
  void $ cli c ["branch", "feature"]
  let feature = ["--branch", "feature"]
  check feature "main_collection"
  void $ api c feature "POST" path (collection "feature_collection")
  root <- api c [] "GET" path ""
  C.demand "Fork modified the parent data" (not (S.contains (S.Pattern "feature_collection") root))
  mainUrl <- cli c ["url"]
  featureUrl <- cli c (feature <> ["url"])
  C.demand "Parallel API servers share a host port" (mainUrl /= featureUrl)
  void $ cli c ["branch", "nested", "--from", "feature"]
  check ["--branch", "nested"] "feature_collection"
  void $ cli c ["checkout", "feature"]
  check [] "feature_collection"
  void $ cli c ["checkout", "main"]
  void $ cli c ["stop"]
  check feature "feature_collection"
  void $ cli c ["start", "-d"]
  check [] "main_collection"
  void $ cli c (feature <> ["stop"])
  check ["--branch", "nested"] "feature_collection"
  void $ cli c (feature <> ["start", "-d"])
  check feature "feature_collection"
  void $ cli c ["branch", "-d", "nested"]
  void $ cli c ["branch", "-d", "feature"]
  void $ cli c ["stop"]
  collision <- N.reservePort
  liftEffect (Ref.write (Just collision.handle) c.occupied)
  rejected <- cliWith c (defaultOptions {allowFailure = true}) ["start", "--port", show collision.port, "-d"]
  C.demand "Occupied API port was accepted" (rejected.code /= 0)
  N.closePort collision.handle
  liftEffect (Ref.write Nothing c.occupied)
  next <- freePort
  void $ cli c ["start", "--port", show next, "-d"]
  check [] "main_collection"
  pass c "HTTP collections persist across independent, nested ZFS branches, selection changes, stop/start and port changes"
  liftEffect (Ref.write true c.succeeded)


-- One lifecycle suite for every native/API workload, with protocol fixtures.
bodyWorkload :: Context -> Workload.Workload -> Aff Unit
bodyWorkload c workload = do
  guest <- C.fallback "SBX_E2E_OS" "linux"
  C.demand "This profile supports Linux guests only" (guest == "linux")
  before <- runtime c ["docker", "status", "--json"] >>= C.fromEither <<< C.jsonSuffix
  wasRunning <- C.fromEither (C.boolField "running" before)
  liftEffect (Ref.write wasRunning c.engineWasRunning)
  port <- freePort
  liftEffect (Ref.write true c.started)
  void $ cliWith c (defaultOptions {timeout = 900000}) (["start", "linux", c.profile.defaultTag, "--port", show port, "-d"] <> if c.profile.hasCredentials then ["--user", c.profile.defaults.user, "--password", c.password] <> if c.profile.hasDatabase then ["--db", c.profile.defaults.db] else [] else if c.profile.hasToken then ["--password", c.password] else [])
  for_ workload.seed (void <<< cli c)
  let check selected expected = do
        output <- cli c (selected <> workload.read)
        C.demand ("Expected persisted marker: " <> expected) (S.contains (S.Pattern expected) output)
  check [] workload.original
  when (c.profile.hasToken || c.profile.hasCredentials) do
    case c.profile.http, A.head workload.read of
      Just endpoint, Just "api" -> do
        address <- cli c ["url"]
        spec <- C.fromEither (Http.parse (A.drop 1 workload.read))
        let bad = endpoint.headers {user: c.profile.defaults.user, password: "wrong-password", db: c.profile.defaults.db}
        rejected <- Http.request address bad spec 10000
        C.demand "Invalid API credentials were accepted" (rejected.status == 401 || rejected.status == 403)
      _, _ -> pure unit
  void $ cli c ["branch", "feature"]
  let feature = ["--branch", "feature"]
  check feature workload.original
  void $ cli c (feature <> workload.write)
  check feature workload.forked
  root <- cli c workload.read
  C.demand "Fork modified parent data" (not (S.contains (S.Pattern workload.forked) root))
  void $ cli c ["branch", "nested", "--from", "feature"]
  check ["--branch", "nested"] workload.forked
  mainUrl <- cli c ["url"]
  branchUrl <- cli c (feature <> ["url"])
  C.demand "Fork reused the parent port" (mainUrl /= branchUrl)
  void $ cli c ["checkout", "feature"]
  check [] workload.forked
  void $ cli c ["checkout", "main"]
  void $ cli c ["stop"]
  check feature workload.forked
  void $ cli c ["start", "-d"]
  check [] workload.original
  void $ cli c (feature <> ["stop"])
  check ["--branch", "nested"] workload.forked
  void $ cli c (feature <> ["start", "-d"])
  check feature workload.forked
  void $ cli c ["branch", "-d", "nested"]
  void $ cli c ["branch", "-d", "feature"]
  void $ cli c ["stop"]
  nextPort <- freePort
  void $ cli c ["start", "--port", show nextPort, "-d"]
  check [] workload.original
  pass c "protocol CRUD, nested forks, isolated data, selection, independent stop/start and port changes"
  liftEffect (Ref.write true c.succeeded)

tigerWorkload :: Workload.Workload
tigerWorkload =
  { seed: [tigerCommand "create_accounts id=1 code=314159 ledger=1;"]
  , read: tigerCommand "lookup_accounts id=1,id=2;"
  , write: tigerCommand "create_accounts id=2 code=271828 ledger=1;"
  , original: "314159", forked: "271828" }

tigerCommand :: String -> Array String
tigerCommand command' = ["exec", "sh", "-c", "printf '%s\\n' '" <> command' <> "' | tigerbeetle repl --cluster=0 --addresses=127.0.0.1:3000"]
