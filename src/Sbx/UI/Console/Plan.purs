-- | Resolve terminal targets from saved sandbox identity, never browser commands.
module Sbx.UI.Console.Plan (Plan, Request, decode, prepare, capabilities) where

import Prelude
import Bsdkrun.Docker as Docker
import Data.Argonaut.Core as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as A
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign.Object as O
import Sbx.Database.Profile (ClientCmd(..))
import Sbx.Management.Inventory as Inventory
import Sbx.Runtime.BsdServer as BSD
import Sbx.Platform.Native as N

type Request = { database :: String, branch :: String, kind :: String }
type Plan = { cli :: Boolean, program :: String, args :: Array String, label :: String }

capabilities :: Inventory.Entry -> { console :: Boolean, container :: Boolean, vm :: Boolean }
capabilities entry =
  { console: entry.kind /= "data" &&
      ( case entry.profile.client of
          Http -> false
          _ -> true
      )
  , container: entry.kind /= "data" && entry.state.os == "linux"
  , vm: true
  }

decode :: String -> Either String Request
decode body = do
  json <- jsonParser body
  obj <- case J.toObject json of
    Nothing -> Left "Expected a terminal request"
    Just value -> Right value
  let field key = fromMaybe "" (O.lookup key obj >>= J.toString)
  let kind = field "kind"
  if not (A.elem kind [ "console", "container", "vm" ]) then Left "Unknown terminal kind"
  else Right { database: field "database", branch: field "branch", kind }

prepare :: Request -> Aff (Either String Plan)
prepare request = do
  inventory <- Inventory.snapshot
  case A.find (\entry -> entry.database == request.database && entry.state.branch == request.branch) inventory.entries of
    Nothing -> pure (Left "Branch not found")
    Just entry -> do
      let p = entry.profile
      let label = request.database <> "/" <> request.branch
      let running = A.any (\row -> row.tool == entry.tool && row.running) inventory.rows
      let supported = capabilities entry
      case request.kind of
        "console" | not supported.console -> pure (Left "This database has no interactive console")
        "console" | not running -> pure (Left "Start the branch server before opening its console")
        "console" -> do
          let command = if request.database == "postgres" then "pgcli" else if A.elem request.database [ "mariadb", "mysql" ] then "mycli" else if request.database == "sqlite" then "litecli" else p.clientName
          pure $ Right { cli: true, program: "", args: [ request.database, "--branch", request.branch, command ], label: command <> " · " <> label }
        "container" | not supported.container || not running -> pure (Left "Start a Linux branch server before opening its container terminal")
        "container" -> pure $ Right { cli: true, program: "", args: [ request.database, "--branch", request.branch, "shell" ], label: "Container · " <> label }
        "vm" -> do
          binary <- liftEffect (N.readEnv "BSDKRUN_BIN")
          let program = if binary == "" then "bsdkrun" else binary
          if entry.state.os == "linux" then do
            engine <- Docker.status
            pure $
              if not engine.running then Left "Start the Docker VM before opening its terminal"
              else Right { cli: false, program, args: [ "exec", "-t", Docker.machineName, "sh" ], label: "VM · " <> Docker.machineName }
          else do
            machine <- BSD.machine (Inventory.scoped entry)
            pure $
              if not machine.running then Left "Start the VM before opening its terminal"
              else Right { cli: false, program, args: [ "exec", "-t", machine.id, "sh" ], label: "VM · " <> label }
        _ -> pure (Left "Unknown terminal kind")
