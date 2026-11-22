-- | An ephemeral UI client attaches the running branch over Quack. Its file
-- | is never opened by another writer, and closing the UI leaves the DB up.
module Sbx.UI.DuckDB (run, dockerfile, runArgs, relayPort) where

import Prelude
import Sbx.Database.Debian as Debian
import Bsdkrun.Docker as Docker
import Bsdkrun.Port as Port
import Control.Monad.Error.Class (throwError)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Effect.Aff (Aff, attempt, finally, forkAff, killFiber, never)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (error)
import Foreign.Object as O
import Sbx.UI.Browser as Browser
import Sbx.Runtime.Engine as Engine
import Sbx.Net.Http as Http
import Sbx.Platform.Native as N
import Sbx.Database.Profile (Profile)
import Sbx.Database.Services (script)
import Sbx.State.Types (State)

relayPort :: Int -> Int
relayPort port = if port == 4214 then 4215 else 4214

dockerfile :: String -> String
dockerfile base = S.joinWith "\n"
  ( Debian.layer base
      [ "apt-get update && apt-get install -y --no-install-recommends socat && rm -rf /var/lib/apt/lists/*"
      , "duckdb :memory: -no-agent -no-init -bail -c 'INSTALL ui;'"
      ]
      <>
        [ script "/usr/local/bin/dbsandbox-ui-connect"
            [ "socat - \"TCP6:[::1]:$SBX_UI_PORT\" 2>/dev/null || exec socat - \"TCP4:127.0.0.1:$SBX_UI_PORT\"" ]
        , script "/usr/local/bin/dbsandbox-duckdb-ui"
            [ ": \"${SBX_PASSWORD:?}\" \"${SBX_DB_PORT:?}\" \"${SBX_UI_PORT:?}\" \"${SBX_RELAY_PORT:?}\""
            -- The official UI binds loopback. Relay only inside this container;
            -- bsdkrun restricts the published port to the host's loopback.
            , "socat \"TCP4-LISTEN:$SBX_RELAY_PORT,bind=0.0.0.0,reuseaddr,fork\" EXEC:/usr/local/bin/dbsandbox-ui-connect &"
            , "printf '%s\\n' \"LOAD ui; SET ui_local_port = $SBX_UI_PORT;\" \"ATTACH 'quack:sbx-server:$SBX_DB_PORT' AS sbx (TOKEN getenv('SBX_PASSWORD'), DISABLE_SSL true);\" 'CALL start_ui_server();' '.shell sleep infinity' > /tmp/dbsandbox-ui.init"
            , "exec duckdb :memory: -no-agent -bail -init /tmp/dbsandbox-ui.init"
            ]
        , "ENTRYPOINT [\"/usr/local/bin/dbsandbox-duckdb-ui\"]"
        ]
  )

runArgs :: String -> String -> String -> State -> Int -> Array String
runArgs image name server st port =
  [ "run"
  , "-d"
  , "--rm"
  , "--init"
  , "--name"
  , name
  , "--label"
  , "org.dbsandbox.ui=true"
  , "--label"
  , "org.dbsandbox.server=" <> server
  , "--add-host"
  , "sbx-server:host-gateway"
  , "-p"
  , show port <> ":" <> show (relayPort port)
  , "-e"
  , "SBX_DB_PORT=" <> show st.port
  , "-e"
  , "SBX_PASSWORD=" <> st.password
  , "-e"
  , "SBX_UI_PORT=" <> show port
  , "-e"
  , "SBX_RELAY_PORT=" <> show (relayPort port)
  , image
  ]

run :: Profile -> State -> { port :: Maybe Int, noOpen :: Boolean } -> Aff Int
run p st options = Browser.session do
  serverLocal <- liftEffect (N.loopbackListener st.port)
  unless serverLocal $ throwError (error "DuckDB UI requires the Docker engine to publish on host loopback only (--publish-bind 127.0.0.1)")
  port <- case options.port of
    Nothing -> Port.findFree 4213
    Just n -> do
      Browser.validatePort n
      free <- Port.isFreeOn "127.0.0.1" n
      unless free $ throwError (error ("UI port " <> show n <> " is in use; choose another with --port"))
      pure n
  -- Resolve the image of the actual branch, even when another branch has
  -- upgraded the shared runtime tag since this container started.
  inspected <- Docker.docker [ "inspect", "--format", "{{.Image}}", Engine.containerName p ]
  unless (inspected.exitCode == 0) $ throwError (error "Cannot inspect the DuckDB server image")
  let base = "dbsandbox-duckdb-ui-base:" <> S.take 16 (N.sha256 (S.trim inspected.stdout))
  tagged <- Docker.docker [ "image", "tag", S.trim inspected.stdout, base ]
  unless (tagged.exitCode == 0) $ throwError (error "Cannot prepare the DuckDB UI image")
  built <- Engine.toolImage (p { tools = Just { image: "dbsandbox-duckdb-ui", dockerfile: dockerfile base } })
  image <- case built of
    Nothing -> throwError (error "Cannot build the DuckDB UI image")
    Just value -> pure value
  suffix <- liftEffect N.randomPassword
  let name = p.tool <> "-ui-" <> S.take 12 suffix
  let address = "http://localhost:" <> show port
  let cleanup = void (Docker.docker [ "rm", "-f", name ])
  finally cleanup do
    started <- Docker.docker (runArgs image name (Engine.containerName p) st port)
    unless (started.exitCode == 0) $ throwError (error ("Cannot start DuckDB UI: " <> S.trim started.stderr))
    terminal <- liftEffect (N.readEnv "DBSANDBOX_TUI")
    logs <- forkAff $ if terminal == "1" then never else void $ attempt $ Docker.dockerAttached [ "logs", "-f", name ]
    finally (killFiber (error "UI logs closed") logs) do
      Browser.await "DuckDB UI" do
        active <- Docker.docker [ "inspect", "--format", "{{.State.Running}}", name ]
        unless (active.exitCode == 0 && S.trim active.stdout == "true") $ throwError (error "DuckDB UI exited during startup; see its logs above")
        Http.healthy ("http://127.0.0.1:" <> show port) O.empty
      local <- liftEffect (N.loopbackListener port)
      unless local $ throwError (error "DuckDB UI must be exposed on host loopback only; start the engine with --publish-bind 127.0.0.1")
      liftEffect $ log ("DuckDB UI for branch '" <> st.branch <> "': " <> address <> " (sbx catalog; Ctrl-C closes the UI)")
      unless options.noOpen $ Browser.open address
      exited <- Docker.docker [ "wait", name ]
      pure $ if exited.exitCode == 0 then fromMaybe 1 (Int.fromString (S.trim exited.stdout)) else exited.exitCode
