-- | Shared application actions for the web dashboard and terminal UI.
module Sbx.UI.Control (Action, Job, Plan, decodeAction, validate, plan, connection, encode, execute) where

import Prelude
import Data.Argonaut.Core as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as A
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.Tuple.Nested ((/\))
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Aff (Aff)
import Foreign.Object as O
import Bsdkrun.Port as Port
import Sbx.Database.App as App
import Sbx.UI.Browser as Browser
import Sbx.Cli (Command(..))
import Sbx.Runtime.Engine as Engine
import Sbx.Branch.Identity as I
import Sbx.Management.Inventory as Inventory
import Sbx.Management.Operations as Operations
import Sbx.Branch.Manager as Parallel
import Sbx.Database.Profile (Os(..), parseOs)
import Sbx.Database.Profiles as Profiles
import Sbx.Management.System as System

type Action = { action :: String, database :: String, branch :: String, name :: String, guest :: String, version :: String, id :: String, cpus :: Maybe Int, mem :: Maybe Int, uiPort :: Maybe Int }
type Job = { id :: String, action :: String, database :: String, branch :: String, status :: String, url :: String, port :: Int, kind :: String, createdAt :: Number }
type Plan = { operation :: Aff Int, url :: String, port :: Int, kind :: String }

decodeAction :: String -> Either String Action
decodeAction body = do
  json <- jsonParser body
  obj <- case J.toObject json of
    Nothing -> Left "Expected a JSON object"
    Just value -> Right value
  let text name = fromMaybe "" (O.lookup name obj >>= J.toString)
  let action = text "action"
  let integer name = O.lookup name obj >>= J.toNumber >>= Int.fromNumber
  let cpus = integer "cpus"
  let mem = integer "mem"
  let uiPort = integer "uiPort"
  let
    invalid name parsed = case O.lookup name obj of
      Nothing -> false
      Just _ -> parsed == Nothing
  if invalid "cpus" cpus || invalid "mem" mem || invalid "uiPort" uiPort then Left "CPU and memory must be integers"
  else validate { action, database: text "database", branch: text "branch", name: text "name", guest: text "guest", version: text "version", id: text "id", cpus, mem, uiPort }

validate :: Action -> Either String Action
validate a
  | fromMaybe 1 a.uiPort < 1 || fromMaybe 1 a.uiPort > 65535 = Left "UI port must be 1–65535"
  | fromMaybe 1 a.cpus < 1 || fromMaybe 1 a.cpus > 256 || fromMaybe 128 a.mem < 128 || fromMaybe 128 a.mem > 1048576 = Left "CPU must be 1–256 and memory must be 128–1048576 MiB"
  | a.action == "configure-engine" && (a.cpus == Nothing || a.mem == Nothing) = Left "CPU and memory are required"
  | not (A.elem a.action [ "start", "stop", "checkout", "branch", "delete", "open-ui", "close-ui", "stop-all", "configure-engine" ]) = Left "Unknown action"
  | S.length a.version > 200 = Left "Version is too long"
  | a.action == "branch" && not (I.validName a.name) = Left "Invalid branch name"
  | a.action == "delete" && not (I.validName a.branch) = Left "Invalid branch name"
  | otherwise = Right a

plan :: Array Job -> Action -> Aff (Either String Plan)
plan jobs action = case validate action of
  Left text -> pure (Left text)
  Right value -> planValid jobs value

planValid :: Array Job -> Action -> Aff (Either String Plan)
planValid _ action | action.action == "stop-all" = pure (Right { operation: Operations.stopAll, url: "", port: 0, kind: "operation" })
planValid _ action | action.action == "configure-engine" = pure (Right { operation: Engine.configureEngine (fromMaybe 2 action.cpus) (fromMaybe 2048 action.mem), url: "", port: 0, kind: "operation" })
planValid jobs action = case Profiles.find action.database of
  Nothing -> pure (Left "Unknown database")
  Just db -> do
    entries <- Inventory.discover
    let root = A.find (\e -> e.database == db.name && e.tool == db.profile.tool) entries
    let selected = if action.branch == "" then root else A.find (\e -> e.database == db.name && e.state.branch == action.branch) entries
    case selected of
      Nothing | action.action == "start" && action.branch == "" && not (A.any (\e -> e.database == db.name) entries) -> do
        let guest = if action.guest == "" then Just Linux else parseOs action.guest
        pure case guest of
          Nothing -> Left "Unknown guest OS"
          Just os | db.profile.linuxOnly && os /= Linux -> Left "This database supports Linux guests only"
          Just os | os == Linux && fromMaybe db.profile.engineMem action.mem < db.profile.engineMem -> Left ("This database needs at least " <> show db.profile.engineMem <> " MiB in the shared engine")
          Just os -> Right
            { operation: do
                when (os == Linux && (action.cpus /= Nothing || action.mem /= Nothing)) do
                  engine <- System.engine
                  void $ Engine.configureEngine (fromMaybe (max 2 engine.cpus) action.cpus) (fromMaybe (max db.profile.engineMem engine.memoryMiB) action.mem)
                App.run db.profile (Start (Parallel.emptyStart { os = Just os, version = if action.version == "" then Nothing else Just action.version, cpus = action.cpus, mem = action.mem }))
            , url: ""
            , port: 0
            , kind: "operation"
            }
      Nothing -> pure (Left "Configured branch not found")
      Just e | action.action == "delete" -> pure $
        if not (Inventory.canDelete e) then Left "Cannot delete the selected branch, main, or the dataset mounted by the parent server"
        else Right { operation: App.run db.profile (Branch { name: Just e.state.branch, arg: Nothing, delete: true, from: Nothing, port: Nothing }), url: "", port: 0, kind: "operation" }
      Just e | e.kind == "data" && action.action == "branch" -> pure $ Right { operation: App.run db.profile (Branch { name: Just action.name, arg: Nothing, delete: false, from: Just e.state.branch, port: Nothing }), url: "", port: 0, kind: "operation" }
      Just e | e.kind == "data" && action.action == "start" && db.profile.driver == "quack" && e.state.os == "linux" -> pure $ Right { operation: App.run db.profile (OnBranch e.state.branch (Start Parallel.emptyStart)), url: "", port: 0, kind: "operation" }
      Just e | e.kind == "data" && action.action /= "checkout" -> pure (Left "Switch to this ZFS branch first; it has no dedicated server")
      Just e -> case action.action of
        "start" -> pure $ Right { operation: Operations.runEntry e (Start Parallel.emptyStart), url: "", port: 0, kind: "operation" }
        "stop" -> pure $ Right { operation: Operations.runEntry e Stop, url: "", port: 0, kind: "operation" }
        "checkout" -> pure $ Right { operation: App.run db.profile (Checkout { name: e.state.branch, create: false }), url: "", port: 0, kind: "operation" }
        "branch" -> pure $ Right { operation: Operations.runEntry e (Branch { name: Just action.name, arg: Nothing, delete: false, from: Just e.state.branch, port: Nothing }), url: "", port: 0, kind: "operation" }
        "open-ui" -> do
          let duck = db.profile.driver == "quack" && e.state.os == "linux"
          let studio = db.profile.dialect /= "" && db.profile.studioSupported (fromMaybe Linux (parseOs e.state.os)) e.state.version
          if not duck && not studio then pure (Left "This database does not provide a supported UI")
          else do
            let reserved = map _.port (A.filter (\j -> j.status == "RUNNING" && j.port > 0) jobs)
            port <- Parallel.selectPort reserved (Port.isFreeOn "127.0.0.1") action.uiPort (if duck then 4213 else 4983)
            let cmd = if duck then Ui { port: Just port, noOpen: false } else Studio { port, host: "127.0.0.1", noOpen: false }
            pure $ Right { operation: Operations.runEntry e cmd, port, kind: if duck then "duckdb" else "studio", url: if duck then "http://localhost:" <> show port else Browser.studioUrl { port, host: "127.0.0.1" } }
        _ -> pure (Left "Unknown database action")

-- | Return the CLI connection URL only for an explicit, configured branch.
-- | UIs display redacted inventory URLs; copying fetches credentials on demand.
connection :: String -> String -> Aff (Either String String)
connection database branch = case Profiles.find database of
  Nothing -> pure (Left "Unknown database")
  Just db -> do
    entries <- Inventory.discover
    pure case A.find (\e -> e.database == db.name && e.state.branch == branch) entries of
      Nothing -> Left "Configured branch not found"
      Just e | e.kind == "data" -> Left "Switch to this ZFS branch first; it has no connection URL yet"
      Just e -> case parseOs e.state.os of
        Nothing -> Left "Unknown guest OS"
        Just os | not (e.profile.serves os e.state.version) -> Left "This branch uses file access rather than a network URL"
        Just _ -> Right (e.profile.url e.state.version { user: e.state.user, password: e.state.password, db: e.state.db } e.state.port)

encode :: Action -> J.Json
encode a = J.fromObject
  ( O.fromFoldable
      ( [ "action" /\ J.fromString a.action, "database" /\ J.fromString a.database, "branch" /\ J.fromString a.branch, "name" /\ J.fromString a.name, "guest" /\ J.fromString a.guest, "version" /\ J.fromString a.version, "id" /\ J.fromString a.id ]
          <> numeric "cpus" a.cpus
          <> numeric "mem" a.mem
          <> numeric "uiPort" a.uiPort
      )
  )
  where
  numeric name = case _ of
    Nothing -> []
    Just value -> [ name /\ J.fromNumber (Int.toNumber value) ]

execute :: String -> Aff Int
execute body = Browser.session case decodeAction body of
  Left text -> liftEffect (Console.error text) $> 1
  Right action -> plan [] action >>= case _ of
    Left text -> liftEffect (Console.error text) $> 1
    Right next -> next.operation
