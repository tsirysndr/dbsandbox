module Sbx.Cluster.Worker (execute) where

import Prelude
import Bsdkrun.Docker as Docker
import Bsdkrun.Port as Port
import Bsdkrun.Types (ZfsVolumeInfo)
import Bsdkrun.Zfs as Zfs
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as A
import Data.Either (either)
import Data.Int as Int
import Data.Maybe (Maybe(..), maybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Traversable (traverse)
import Data.Tuple (Tuple)
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, finally)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Foreign.Object as O
import Sbx.Branch.Manager as Parallel
import Sbx.Cli (Command(..))
import Sbx.Cluster.Native as N
import Sbx.Database.App as App
import Sbx.Database.Profile (Profile, Os(..), shellQuote)
import Sbx.Database.Profiles as Profiles
import Sbx.Platform.Native as Host
import Sbx.Runtime.Engine as Engine
import Sbx.State as State
import Sbx.State.Store as Store
import Sbx.State.Types as Types

type Identity = { id :: String, database :: String, name :: String }

fail :: forall a. String -> Aff a
fail = throwError <<< error

field :: String -> J.Json -> Maybe J.Json
field name json = J.toObject json >>= O.lookup name

text :: String -> J.Json -> Aff String
text name json = maybe (fail ("Missing " <> name)) pure (field name json >>= J.toString)

object :: Array (Tuple String J.Json) -> J.Json
object = J.fromObject <<< O.fromFoldable

check :: Array String -> Aff Unit
check args = N.exec args >>= \result -> unless (result.exitCode == 0) (fail result.stderr)

volume :: Profile -> Aff ZfsVolumeInfo
volume profile = Zfs.list >>= maybe (fail "Branch volume is missing") pure <<< A.find (\v -> v.name == profile.tool)

choosePort :: Profile -> String -> Aff Int
choosePort profile version
  | not (profile.serves Linux version) = pure 0
  | otherwise = do
      states <- liftEffect (Store.tools >>= traverse State.load)
      Parallel.selectPort (map _.port (A.catMaybes states)) (Port.isFreeOn "127.0.0.1") Nothing profile.guestPort

start :: Profile -> Aff Unit
start profile = do
  saved <- liftEffect (State.load profile.tool)
  case saved of
    Just _ -> void (volume profile)
    Nothing -> pure unit
  port <- maybe (choosePort profile profile.defaultTag) (pure <<< _.port) saved
  code <- App.run profile (Start (Parallel.emptyStart { os = Just Linux, port = Just port }))
  unless (code == 0) (fail "Branch start failed")

encodeState :: Types.State -> J.Json
encodeState st = object
  [ "os" /\ J.fromString st.os
  , "version" /\ J.fromString st.version
  , "port" /\ J.fromNumber (Int.toNumber st.port)
  , "user" /\ J.fromString st.user
  , "password" /\ J.fromString st.password
  , "db" /\ J.fromString st.db
  , "branch" /\ J.fromString st.branch
  , "cpus" /\ J.fromNumber (Int.toNumber st.cpus)
  , "mem" /\ J.fromNumber (Int.toNumber st.mem)
  ]

execute :: String -> Aff Int
execute body = do
  liftEffect N.quiet
  payload <- either fail pure (jsonParser body)
  raw <- maybe (fail "Missing branch record") pure (field "record" payload)
  id <- text "id" raw
  database <- text "database" raw
  name <- text "name" raw
  unless (S.length id == 36 && A.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c == '-') (CU.toCharArray id)) (fail "Invalid branch resource identity")
  found <- maybe (fail "Unknown database") pure (Profiles.find database)
  let profile = found.profile { tool = "sbx-" <> S.replaceAll (S.Pattern "-") (S.Replacement "") id, cli = "dbsandbox " <> database <> " --branch " <> name }
  action <- text "action" payload
  let identity = { id, database, name }
  result <- perform profile identity payload action
  liftEffect (N.respond (J.stringify result))
  pure 0

perform :: Profile -> Identity -> J.Json -> String -> Aff J.Json
perform profile identity payload action = do
  let ok = object [ "ok" /\ J.fromBoolean true, "branch" /\ J.fromString identity.name ]
  case action of
    "start" -> do
      raw <- maybe (fail "Missing branch record") pure (field "record" payload)
      let phase = field "phase" raw >>= J.toString
      saved <- liftEffect (State.load profile.tool)
      when (phase == Just "ready" && saved == Nothing) (fail "Ready branch storage is missing; recover its owning node instead of creating an empty database")
      start profile $> ok
    "stop" -> do
      code <- App.run profile Stop
      unless (code == 0) (fail "Branch stop failed")
      pure ok
    "delete" -> do
      code <- App.run profile (Destroy { yes: true })
      unless (code == 0) (fail "Branch deletion failed")
      pure ok
    "inventory" -> do
      st <- liftEffect (State.load profile.tool) >>= maybe (fail "Branch is not initialized") pure
      running <- Engine.isRunning profile
      let url = if profile.serves Linux st.version then profile.url st.version { user: st.user, password: "***", db: st.db } st.port else ""
      pure $ object
        [ "database" /\ J.fromString identity.database
        , "branch" /\ J.fromString identity.name
        , "running" /\ J.fromBoolean running
        , "status" /\ J.fromString (if running then "RUNNING" else "STOPPED")
        , "guest" /\ J.fromString st.os
        , "version" /\ J.fromString st.version
        , "port" /\ J.fromNumber (Int.toNumber st.port)
        , "url" /\ J.fromString url
        , "kind" /\ J.fromString (if identity.name == "main" then "server" else "branch")
        ]
    "export" -> do
      st <- liftEffect (State.load profile.tool) >>= maybe (fail "Branch is not initialized") pure
      unless (st.os == "linux") (fail "Cross-node snapshots currently require Linux branch runtimes")
      path <- text "path" payload
      Engine.ensureEngine
      vol <- volume profile
      Engine.ensureAttached profile vol "main"
      suffix <- liftEffect N.uuid
      let snapshot = profile.tool <> "/main@dbsandbox-" <> suffix
      check [ "exec", Docker.machineName, "zfs", "snapshot", snapshot ]
      finally (check [ "exec", Docker.machineName, "zfs", "destroy", snapshot ]) do
        N.transfer [ "exec", Docker.machineName, "zfs", "send", "-p", snapshot ] path false
        hash <- N.hashFile path
        host <- liftEffect Host.platform
        pure $ object
          [ "sha256" /\ J.fromString hash
          , "state" /\ object [ "runtime" /\ encodeState st, "arch" /\ J.fromString host.arch, "size_bytes" /\ J.fromNumber vol.sizeBytes ]
          ]
    "import" -> do
      saved <- liftEffect (State.load profile.tool)
      case saved of
        Just _ -> start profile $> ok
        Nothing -> do
          metadata <- maybe (fail "Missing snapshot metadata") pure (field "state" payload)
          source <- maybe (fail "Invalid snapshot runtime metadata") pure (field "runtime" metadata >>= Types.decode)
          arch <- text "arch" metadata
          host <- liftEffect Host.platform
          unless (arch == host.arch && source.os == "linux") (fail "Snapshot requires Linux and matching guest architecture")
          path <- text "path" payload
          allVolumes <- Zfs.list
          when (A.any (\v -> v.name == profile.tool) allVolumes) (fail "Partial branch volume exists; delete the failed branch before recreating it")
          size <- maybe (fail "Missing snapshot volume size") pure (field "size_bytes" metadata >>= J.toNumber)
          unless (size > 0.0) (fail "Invalid snapshot volume size")
          Engine.ensureEngine
          void $ Zfs.create profile.tool (Just (show (max 1 (Int.ceil (size / 1073741824.0))) <> "G"))
          vol <- volume profile
          Engine.ensureAttached profile vol "main"
          let dataset = profile.tool <> "/main"
          check [ "exec", Docker.machineName, "sh", "-c", "zfs unmount " <> shellQuote dataset <> " && zfs destroy " <> shellQuote dataset ]
          -- Receive into a fresh dataset without -F; existing data must fail.
          N.transfer [ "exec", Docker.machineName, "zfs", "receive", "-u", "-o", "mountpoint=none", "-o", "canmount=noauto", dataset ] path true
          void $ Zfs.attachAt (Zfs.target profile.tool (Just "main")) Docker.machineName (Just (Engine.mountPoint profile "main"))
          port <- choosePort profile source.version
          liftEffect (State.saveFor profile (source { branch = "main", port = port }))
          start profile
          pure ok
    _ -> fail "Unknown cluster worker action"
