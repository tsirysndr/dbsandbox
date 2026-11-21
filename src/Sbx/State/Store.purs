-- | Transactional host metadata. Sandbox volumes and guest databases remain
-- | owned by bsdkrun; this database stores their configuration and selections.
module Sbx.State.Store (load, save, saveFor, clear, tools, entries, saveEntries, active, activate, search, databasePath, searchQuery, syncSearch) where

import Prelude
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toMaybe)
import Data.String as S
import Data.String.Regex as R
import Data.String.Regex.Flags (global)
import Data.Either (Either(..))
import Data.Traversable (traverse)
import Drizzle.Database as DB
import Drizzle.Database (Database)
import Drizzle.Dialect (SQLite)
import Drizzle.Query as Q
import Drizzle.Schema (columns, toSQL)
import Drizzle.SQL as SQL
import Drizzle.SQLite.BunSQLite as Bun
import Foreign.Object (lookup)
import Effect (Effect)
import Effect.Exception (try, throw, throwException)
import Sbx.Branch.Identity as I
import Sbx.Platform.Native as N
import Sbx.Database.Profile (Profile)
import Sbx.Database.Profiles as Profiles
import Sbx.State.Types (State)
import Sbx.State.Types as Types
import Sbx.State.Native as FS
import Sbx.State.Schema as Schema

type BranchEntry = { name :: String, tool :: String, running :: Boolean }
type Saved = { tool :: String, database :: String, os :: String, version :: String, port :: Int, user :: String, password :: String, db :: String, branch :: String, cpus :: Int, mem :: Int }

databasePath :: Effect String
databasePath = N.configHome <#> \home -> N.pathJoin (N.pathJoin home "dbsandbox") "state.sqlite"

toolDatabase :: String -> Maybe String
toolDatabase tool = _.name <$> A.find (\db -> db.profile.tool == I.volumeName tool) Profiles.all

stateRecord :: Saved -> State
stateRecord r = { os: r.os, version: r.version, port: r.port, user: r.user, password: r.password, db: r.db, branch: r.branch, cpus: r.cpus, mem: r.mem }

putState :: Database SQLite -> String -> State -> Effect Unit
putState db tool st = case toolDatabase tool of
  Nothing -> throw "Unknown sandbox tool"
  Just database -> putStateAs db database tool st

putStateAs :: Database SQLite -> String -> String -> State -> Effect Unit
putStateAs db database tool st = Q.upsert db Schema.states { tool, database, os: st.os, version: st.version, port: st.port, user: st.user, password: st.password, db: st.db, branch: st.branch, cpus: st.cpus, mem: st.mem }

-- SQL schema and FTS triggers live in PureScript. Only non-secret labels are
-- indexed; passwords, usernames and connection URLs never enter FTS shadow tables.
migrations :: Array String
migrations =
  [ "CREATE TABLE IF NOT EXISTS sandboxes (tool TEXT PRIMARY KEY NOT NULL, database TEXT NOT NULL, os TEXT NOT NULL CHECK(os IN ('linux','freebsd','netbsd')), version TEXT NOT NULL, port INTEGER NOT NULL CHECK(port BETWEEN 0 AND 65535), user TEXT NOT NULL, password TEXT NOT NULL, db TEXT NOT NULL, branch TEXT NOT NULL, cpus INTEGER NOT NULL CHECK(cpus > 0), mem INTEGER NOT NULL CHECK(mem > 0))"
  , "CREATE TABLE IF NOT EXISTS selections (tool TEXT PRIMARY KEY NOT NULL, branch TEXT NOT NULL)"
  , "CREATE TABLE IF NOT EXISTS branches (tool TEXT PRIMARY KEY NOT NULL, parent TEXT NOT NULL, name TEXT NOT NULL, running INTEGER NOT NULL CHECK(running IN (0,1)), UNIQUE(parent,name))"
  , "CREATE TABLE IF NOT EXISTS legacy_imports (tool TEXT PRIMARY KEY NOT NULL)"
  , "CREATE VIRTUAL TABLE IF NOT EXISTS sandbox_search USING fts5(tool UNINDEXED, database, branch, guest, version, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')"
  , "CREATE TRIGGER IF NOT EXISTS sandbox_search_insert AFTER INSERT ON sandboxes BEGIN INSERT INTO sandbox_search(tool,database,branch,guest,version) VALUES(new.tool,new.database,new.branch,new.os,new.version); END"
  , "CREATE TRIGGER IF NOT EXISTS sandbox_search_delete AFTER DELETE ON sandboxes BEGIN DELETE FROM sandbox_search WHERE tool=old.tool; END"
  , "CREATE TRIGGER IF NOT EXISTS sandbox_search_update AFTER UPDATE ON sandboxes BEGIN DELETE FROM sandbox_search WHERE tool=old.tool; INSERT INTO sandbox_search(tool,database,branch,guest,version) VALUES(new.tool,new.database,new.branch,new.os,new.version); END"
  ]

legacyStates :: Effect (Array { tool :: String, state :: State })
legacyStates = do
  home <- N.configHome
  names <- N.listDir home
  found <- traverse
    ( \tool -> case toolDatabase tool of
        Nothing -> pure Nothing
        Just _ -> do
          raw <- N.readJson (N.pathJoin (N.pathJoin home tool) "state.json")
          pure do
            st <- toMaybe raw >>= Types.decode
            if I.isInstance tool && (not (I.validName st.branch) || tool /= I.instanceName tool st.branch) then Nothing
            else Just { tool, state: st }
    )
    names
  pure (A.catMaybes found)

imported :: Database SQLite -> String -> Effect Boolean
imported db tool = Q.select db Schema.imports (SQL.eq (toSQL (columns Schema.imports).tool) (SQL.param tool)) <#> not <<< A.null

migrateLegacy :: Database SQLite -> Array { tool :: String, state :: State } -> Effect Unit
migrateLegacy db legacy = DB.transaction db \tx -> do
  home <- N.configHome
  for_ legacy \e -> do
    done <- imported tx e.tool
    unless done do
      saved <- Q.select tx Schema.states (SQL.eq (toSQL (columns Schema.states).tool) (SQL.param e.tool))
      when (A.null saved) (putState tx e.tool e.state)
      unless (I.isInstance e.tool) do
        let dir = N.pathJoin home e.tool
        raw <- N.readJson (N.pathJoin dir "branches.json")
        let list = fromMaybe [] (toMaybe raw >>= J.toArray)
        for_ list \json -> case J.toObject json of
          Nothing -> pure unit
          Just obj -> do
            -- Decode untrusted legacy manifests rather than casting JSON.
            let name = J.toString =<< lookup "name" obj
            let tool = J.toString =<< lookup "tool" obj
            let running = fromMaybe false (lookup "running" obj >>= J.toBoolean)
            case name, tool of
              Just n, Just t | I.validName n && t == I.instanceName e.tool n && A.any (\child -> child.tool == t && child.state.branch == n) legacy ->
                Q.upsert tx Schema.branches { tool: t, parent: e.tool, name: n, running }
              _, _ -> pure unit
        selected <- N.readJson (N.pathJoin dir "active.json")
        case toMaybe selected >>= J.toString of
          Just name | A.any (\child -> child.tool == I.instanceName e.tool name && child.state.branch == name) legacy -> Q.upsert tx Schema.selections { tool: e.tool, branch: name }
          _ -> pure unit
      Q.upsert tx Schema.imports { tool: e.tool }

withDb :: forall a. Boolean -> a -> (Database SQLite -> Effect a) -> Effect a
withDb create fallback action = do
  path <- databasePath
  exists <- N.fileExists path
  legacy <- legacyStates
  if not create && not exists && A.null legacy then pure fallback
  else do
    FS.prepare path
    db <- Bun.open path
    ensuring (Bun.close db) do
      FS.protect path
      DB.execute db (SQL.raw "PRAGMA busy_timeout=5000")
      versions <- DB.all db (SQL.raw "PRAGMA user_version") :: Effect (Array { user_version :: Int })
      let version = fromMaybe 0 (_.user_version <$> A.head versions)
      when (version > 1) (throw "State database is newer than this dbsandbox version")
      when (version == 0) do
        DB.execute db (SQL.raw "PRAGMA journal_mode=WAL")
        DB.transaction db \tx -> do
          for_ migrations (DB.execute tx <<< SQL.raw)
          DB.execute tx (SQL.raw "PRAGMA user_version=1")
      migrateLegacy db legacy
      action db

load :: String -> Effect (Maybe State)
load tool = withDb false Nothing \db -> do
  rows <- Q.select db Schema.states (SQL.eq (toSQL (columns Schema.states).tool) (SQL.param tool))
  pure (stateRecord <$> A.head rows)

save :: String -> State -> Effect Unit
save tool st = withDb true unit \db -> DB.transaction db \tx -> do
  putState tx tool st
  Q.upsert tx Schema.imports { tool }

-- | Scoped/isolated runtimes keep the profile's database identity even when
-- | the caller chooses a different resource name (e.g. live-test fixtures).
saveFor :: Profile -> State -> Effect Unit
saveFor profile st = case A.find (\db -> db.profile.product == profile.product && db.profile.driver == profile.driver) Profiles.all of
  Nothing -> throw "Unknown database profile"
  Just found -> withDb true unit \db -> DB.transaction db \tx -> do
    putStateAs tx found.name profile.tool st
    Q.upsert tx Schema.imports { tool: profile.tool }

clear :: String -> Effect Unit
clear tool = withDb false unit \db -> DB.transaction db \tx -> do
  Q.deleteWhere tx Schema.states (SQL.eq (toSQL (columns Schema.states).tool) (SQL.param tool))
  Q.deleteWhere tx Schema.branches (SQL.or (SQL.eq (toSQL (columns Schema.branches).tool) (SQL.param tool)) (SQL.eq (toSQL (columns Schema.branches).parent) (SQL.param tool)))
  Q.deleteWhere tx Schema.selections (SQL.eq (toSQL (columns Schema.selections).tool) (SQL.param tool))
  Q.upsert tx Schema.imports { tool }

tools :: Effect (Array String)
tools = withDb false [] \db -> Q.select db Schema.states (SQL.raw "1=1") <#> map _.tool

entries :: String -> Effect (Array BranchEntry)
entries parent = withDb false [] \db -> do
  rows <- Q.select db Schema.branches (SQL.eq (toSQL (columns Schema.branches).parent) (SQL.param parent))
  pure (map (\r -> { tool: r.tool, name: r.name, running: r.running }) rows)

saveEntries :: String -> Array BranchEntry -> Effect Unit
saveEntries parent values = withDb true unit \db -> DB.transaction db \tx -> do
  Q.deleteWhere tx Schema.branches (SQL.eq (toSQL (columns Schema.branches).parent) (SQL.param parent))
  for_ values \e -> Q.upsert tx Schema.branches { tool: e.tool, parent, name: e.name, running: e.running }

active :: String -> Effect (Maybe String)
active tool = withDb false Nothing \db -> Q.select db Schema.selections (SQL.eq (toSQL (columns Schema.selections).tool) (SQL.param tool)) <#> map _.branch <<< A.head

activate :: String -> Maybe String -> Effect Unit
activate tool selection = withDb true unit \db -> case selection of
  Nothing -> Q.deleteWhere db Schema.selections (SQL.eq (toSQL (columns Schema.selections).tool) (SQL.param tool))
  Just branch -> Q.upsert db Schema.selections { tool, branch }

-- Treat input as literal words with prefix matching, never as FTS operators.
searchQuery :: String -> String
searchQuery input =
  let
    normalized = case R.regex "[^A-Za-z0-9_\\u0080-\\uffff]+" global of
      Left _ -> ""
      Right regex -> R.replace regex " " (S.take 200 input)
    terms = A.filter (_ /= "") (S.split (S.Pattern " ") (S.trim normalized))
  in
    S.joinWith " AND " (map (\word -> "\"" <> word <> "\"*") (A.take 12 terms))

search :: String -> Effect (Array String)
search input = withDb false [] \db -> do
  let query = searchQuery input
  if query == "" then pure []
  else do
    rows <- DB.all db (SQL.template [ "SELECT tool FROM sandbox_search WHERE sandbox_search MATCH ", " ORDER BY rank LIMIT 2000" ] [ SQL.param query ]) :: Effect (Array { tool :: String })
    pure (map _.tool rows)

ensuring :: forall a. Effect Unit -> Effect a -> Effect a
ensuring cleanup action = do
  result <- try action
  cleanup
  case result of
    Left err -> throwException err
    Right value -> pure value

-- | Add data-only ZFS branches to the search index without inventing server
-- | state or credentials for them. Rebuild transactionally with actual state.
syncSearch :: Array { tool :: String, database :: String, branch :: String, guest :: String, version :: String } -> Effect Unit
syncSearch extra = withDb false unit \db -> DB.transaction db \tx -> do
  DB.execute tx (SQL.raw "DELETE FROM sandbox_search")
  DB.execute tx (SQL.raw "INSERT INTO sandbox_search(tool,database,branch,guest,version) SELECT tool,database,branch,os,version FROM sandboxes")
  for_ extra \row -> DB.execute tx (SQL.template [ "INSERT INTO sandbox_search(tool,database,branch,guest,version) VALUES (", ",", ",", ",", ",", ")" ] [ SQL.param row.tool, SQL.param row.database, SQL.param row.branch, SQL.param row.guest, SQL.param row.version ])
