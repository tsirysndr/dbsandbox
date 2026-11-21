-- | Read-only discovery of configured servers, including stopped/orphaned
-- | branch state. Public rows deliberately contain no credentials.
module Sbx.Management.Inventory (Entry, ServerRow, discover, snapshot, rowJson, scoped, target, canDelete) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Docker as Docker
import Sbx.Branch.Graph as Graph
import Sbx.Branch.Graph.Metadata as Metadata
import Sbx.Platform.Native as N
import Bsdkrun.Types (SandboxInfo, DockerContainer)
import Control.Alt ((<|>))
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (Nullable, null, toMaybe)
import Data.String as S
import Data.Traversable (traverse)
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt, delay, parallel, sequential)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Ref as Ref
import Data.Time.Duration (Milliseconds(..))
import Foreign.Object as O
import Sbx.Runtime.BsdServer as BSD
import Sbx.Cli (Command(..))
import Sbx.Branch.Identity as I
import Sbx.Database.Profile (Profile, Os(..), ClientCmd(..), parseOs)
import Sbx.Database.Profiles as Profiles
import Sbx.State.Types (State)
import Sbx.State as State
import Sbx.State.Store as Store

type Entry = { database :: String, profile :: Profile, tool :: String, state :: State, active :: Boolean, kind :: String, parent :: Nullable String, createdAt :: Nullable Number }
type ServerRow = { database :: String, tool :: String, branch :: String, guest :: String, version :: String, status :: String, running :: Boolean, active :: Boolean, port :: Int, url :: String, ui :: String, kind :: String, deletable :: Boolean, parent :: Nullable String, createdAt :: Nullable Number, created :: String, graph :: Graph.Position, console :: String, containerTerminal :: Boolean }

canDelete :: Entry -> Boolean
canDelete e = not e.active && e.state.branch /= "main" && e.tool /= e.profile.tool

scoped :: Entry -> Profile
scoped e = e.profile { tool = e.tool }

-- Explicitly target the parent even when checkout currently selects a fork.
target :: Entry -> Command -> Command
target e cmd = if I.isInstance e.tool then cmd else OnBranch e.state.branch cmd

discover :: Aff (Array Entry)
discover = _.entries <$> discoverAll

discoverAll :: Aff { entries :: Array Entry, errors :: Array String }
discoverAll = do
  dirs <- liftEffect Store.tools
  groups <- traverse
    ( \db -> do
        let candidates = A.sort $ A.filter (\tool -> tool == db.profile.tool || S.take (S.length db.profile.tool + 8) tool == db.profile.tool <> ".branch-") dirs
        states <- traverse
          ( \tool -> do
              saved <- liftEffect (State.lookup tool)
              pure $ saved >>= \st ->
                if tool /= db.profile.tool && (not (I.validName st.branch) || tool /= I.instanceName db.profile.tool st.branch) then Nothing
                else Just { database: db.name, profile: db.profile, tool, state: st, active: false, kind: "server", parent: null, createdAt: null }
          )
          candidates
        let entries = A.catMaybes states
        active <- liftEffect (Store.active db.profile.tool)
        let chosen = fromMaybe db.profile.tool (map _.tool (A.find (\e -> I.isInstance e.tool && Just e.state.branch == active) entries))
        pure (map (\e -> e { active = e.tool == chosen }) entries)
    )
    Profiles.all
  let configured = A.concat groups
  volumes <- if A.null configured then pure (Right []) else sequential (parallel (attempt Metadata.list) <|> parallel (delay (Milliseconds 4000.0) $> Left (error "ZFS inventory timeout")))
  case volumes of
    Left _ -> pure { entries: configured, errors: [ "Cannot list ZFS branches; showing configured server instances only" ] }
    Right found -> do
      let
        extra = A.concatMap
          ( \parent ->
              if parent.tool /= parent.profile.tool then []
              else case A.find (\volume -> volume.name == parent.profile.tool) found of
                Nothing -> []
                Just volume -> A.mapMaybe
                  ( \name ->
                      if A.any (\existing -> existing.database == parent.database && existing.state.branch == name) configured || (name /= "main" && not (I.validName name)) then Nothing
                      else Just { database: parent.database, profile: parent.profile, tool: parent.profile.tool <> ".data-" <> S.take 20 (N.sha256 name), state: parent.state { branch = name }, active: false, kind: "data", parent: null, createdAt: null }
                  )
                  (A.nub ([ "main" ] <> map _.name volume.branches))
          )
          configured
      unless (A.null configured) $ liftEffect $ Store.syncSearch (map (\e -> { tool: e.tool, database: e.database, branch: e.state.branch, guest: e.state.os, version: e.state.version }) extra)
      let
        enriched = map
          ( \entry -> case A.find (\volume -> volume.name == entry.profile.tool) found >>= \volume -> A.find (\branch -> branch.name == entry.state.branch) volume.branches of
              Nothing -> entry
              Just branch -> entry { parent = branch.origin, createdAt = branch.createdAt }
          )
          (configured <> extra)
      pure { entries: enriched, errors: [] }

snapshot :: Aff { entries :: Array Entry, rows :: Array ServerRow, errors :: Array String }
snapshot = do
  discovered <- discoverAll
  let entries = discovered.entries
  errors <- liftEffect (Ref.new discovered.errors)
  let note text = liftEffect $ Ref.modify_ (_ <> [ text ]) errors
  linux <-
    if A.any (\e -> e.state.os == "linux") entries then do
      result <- attempt Docker.status
      case result of
        Left _ -> note "Cannot inspect the Docker engine" $> Nothing
        Right engine | not engine.running -> pure (Just [])
        Right _ -> do
          containers <- attempt (Docker.containers true)
          case containers of
            Left _ -> note "Cannot list Docker containers" $> Nothing
            Right found -> pure (Just found)
    else pure (Just [])
  bsd <-
    if A.any (\e -> e.state.os /= "linux") entries then do
      machines <- attempt (B.list true)
      case machines of
        Left _ -> note "Cannot list BSD machines" $> Nothing
        Right found -> pure (Just found)
    else pure (Just [])
  rows <- traverse
    ( \entry -> do
        state <- running linux bsd entry
        when (state == "UNKNOWN") $ note ("Cannot determine status: " <> entry.database <> "/" <> entry.state.branch)
        let os = fromMaybe Linux (parseOs entry.state.os)
        let p = entry.profile
        let serves = entry.kind /= "data" && p.serves os entry.state.version
        let url = if serves then p.url entry.state.version { user: entry.state.user, password: "***", db: entry.state.db } entry.state.port else if entry.kind == "data" then "Switch to mount this ZFS branch" else "file access in guest"
        pure
          { database: entry.database
          , tool: entry.tool
          , branch: entry.state.branch
          , parent: entry.parent
          , createdAt: entry.createdAt
          , created: Metadata.dateLabel entry.createdAt
          , graph: Graph.empty
          , console:
              if entry.kind == "data" then ""
              else case p.client of
                Http -> ""
                _ -> if entry.database == "postgres" then "pgcli" else if A.elem entry.database [ "mariadb", "mysql" ] then "mycli" else if entry.database == "sqlite" then "litecli" else p.clientName
          , containerTerminal: entry.kind /= "data" && os == Linux
          , guest: entry.state.os
          , version: entry.state.version
          , status: state
          , running: state == "RUNNING"
          , deletable: canDelete entry
          , active: entry.active
          , port: if serves then entry.state.port else 0
          , url
          , kind: entry.kind
          , ui: if entry.kind == "data" then "" else if p.driver == "quack" && os == Linux then "duckdb" else if p.dialect /= "" && p.studioSupported os entry.state.version then "studio" else ""
          }
    )
    entries
  warnings <- liftEffect (Ref.read errors)
  let ordered = A.concatMap (\db -> let nodes = Graph.layout (A.filter (\row -> row.database == db.name) rows) in map (\node -> node.item { graph = Graph.position nodes node }) nodes) Profiles.all
  pure { entries, rows: ordered, errors: A.nub warnings }

running :: Maybe (Array DockerContainer) -> Maybe (Array SandboxInfo) -> Entry -> Aff String
running _ _ e | e.kind == "data" = pure "DATA ONLY"
running containers _ e | e.state.os == "linux" = pure case containers of
  Nothing -> "UNKNOWN"
  Just list -> if A.any (\c -> c.name == e.tool && c.state == "running") list then "RUNNING" else "STOPPED"
running _ machines e = case machines of
  Nothing -> pure "UNKNOWN"
  Just list -> case A.find (\m -> toMaybe m.name == Just (I.volumeName e.tool)) list of
    Nothing -> pure "STOPPED"
    Just m | not m.running -> pure "STOPPED"
    Just _ -> do
      result <- sequential (parallel (attempt (BSD.running (scoped e) e.state)) <|> parallel (delay (Milliseconds 4000.0) $> Left (error "status timeout")))
      pure case result of
        Left _ -> "UNKNOWN"
        Right true -> "RUNNING"
        Right false -> "STOPPED"

rowJson :: ServerRow -> J.Json
rowJson r = J.fromObject $ O.fromFoldable
  [ "database" /\ J.fromString r.database
  , "tool" /\ J.fromString r.tool
  , "branch" /\ J.fromString r.branch
  , "console" /\ J.fromString r.console
  , "containerTerminal" /\ J.fromBoolean r.containerTerminal
  , "parent" /\ maybeJson J.fromString (toMaybe r.parent)
  , "createdAt" /\ maybeJson J.fromNumber (toMaybe r.createdAt)
  , "created" /\ J.fromString r.created
  , "graph" /\ graphJson r.graph
  , "guest" /\ J.fromString r.guest
  , "version" /\ J.fromString r.version
  , "status" /\ J.fromString r.status
  , "running" /\ J.fromBoolean r.running
  , "deletable" /\ J.fromBoolean r.deletable
  , "active" /\ J.fromBoolean r.active
  , "port" /\ J.fromNumber (Int.toNumber r.port)
  , "url" /\ J.fromString r.url
  , "kind" /\ J.fromString r.kind
  , "ui" /\ J.fromString r.ui
  ]

maybeJson :: forall a. (a -> J.Json) -> Maybe a -> J.Json
maybeJson encode = case _ of
  Nothing -> J.jsonNull
  Just value -> encode value

graphJson :: Graph.Position -> J.Json
graphJson graph = J.fromObject $ O.fromFoldable
  [ "index" /\ J.fromNumber (Int.toNumber graph.index)
  , "lane" /\ J.fromNumber (Int.toNumber graph.lane)
  , "lanes" /\ J.fromNumber (Int.toNumber graph.lanes)
  , "parentIndex" /\ J.fromNumber (Int.toNumber graph.parentIndex)
  , "unknown" /\ J.fromBoolean graph.unknown
  , "color" /\ J.fromString graph.color
  , "segments" /\ J.fromArray
      ( map
          ( \segment -> J.fromObject
              ( O.fromFoldable
                  [ "fromLane" /\ J.fromNumber (Int.toNumber segment.fromLane)
                  , "toLane" /\ J.fromNumber (Int.toNumber segment.toLane)
                  , "fromY" /\ J.fromNumber (Int.toNumber segment.fromY)
                  , "toY" /\ J.fromNumber (Int.toNumber segment.toY)
                  , "color" /\ J.fromString segment.color
                  ]
              )
          )
          graph.segments
      )
  ]
