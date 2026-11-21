module Sbx.Management.System (Check, EngineInfo, doctor, engine, engineJson, checkJson, compatible) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Host as Host
import Bsdkrun.Docker as Docker
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toMaybe)
import Data.String as S
import Data.Traversable (traverse)
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Foreign.Object as O
import Sbx.Platform.Native as N

type Check = { name :: String, ok :: Boolean, required :: Boolean, detail :: String }
type EngineInfo = { status :: String, machine :: String, cpus :: Int, memoryMiB :: Int, diskBytes :: Number, filesystem :: String, storageDriver :: String, containers :: Int, version :: String, message :: String }

compatible :: String -> Boolean
compatible text = fromMaybe false do
  let version = fromMaybe (S.trim text) (S.stripPrefix (S.Pattern "bsdkrun ") (S.trim text))
  case S.split (S.Pattern ".") version of
    [ a, b, c ] -> do
      major <- Int.fromString a
      minor <- Int.fromString b
      patch <- A.head (S.split (S.Pattern "-") c) >>= Int.fromString
      pure (major > 0 || (major == 0 && (minor > 12 || (minor == 12 && patch >= 2))))
    _ -> Nothing

doctor :: Aff (Array Check)
doctor = do
  host <- liftEffect N.platform
  override <- liftEffect (N.readEnv "BSDKRUN_BIN")
  binary <-
    if override == "" then liftEffect (N.findExecutable "bsdkrun") <#> toMaybe
    else do
      exists <- liftEffect (N.fileExists override)
      pure (if exists then Just override else Nothing)
  version <- case binary of
    Nothing -> pure Nothing
    Just _ -> attempt Host.version <#> case _ of
      Left _ -> Nothing
      Right value -> Just (S.trim value)
  probe <- case binary of
    Nothing -> pure false
    Just _ -> attempt Host.probe <#> case _ of
      Right true -> true
      _ -> false
  kvm <- if host.os == "linux" then liftEffect (N.readableWritable "/dev/kvm") else pure true
  tools <- traverse
    ( \name -> do
        found <- liftEffect (N.findExecutable name) <#> toMaybe
        pure { name, ok: found /= Nothing, required: name == "docker", detail: fromMaybe (if name == "docker" then "Install the Docker CLI; Docker Desktop is unnecessary" else "Optional host tool is not installed") found }
    )
    [ "docker", "node", "uvx", "pipx", "pgroll" ]
  root <- liftEffect N.toolRoot
  localKit <- liftEffect (N.fileExists (N.pathJoin root "node_modules/drizzle-kit/bin.cjs"))
  kit <- liftEffect (N.findExecutable "drizzle-kit") <#> toMaybe
  pure $
    [ { name: "host", ok: (host.os == "macos" && host.arch == "arm64") || (host.os == "linux" && A.elem host.arch [ "amd64", "arm64" ]), required: true, detail: host.os <> "/" <> host.arch }
    , { name: "bsdkrun", ok: binary /= Nothing, required: true, detail: fromMaybe "Install bsdkrun >= 0.12.2" binary }
    , { name: "runtime version", ok: fromMaybe false (compatible <$> version), required: true, detail: fromMaybe "Could not read runtime version (requires >= 0.12.2)" version }
    , { name: "hypervisor", ok: probe && kvm, required: true, detail: if probe && kvm then "Virtualization probe passed" else if not kvm then "/dev/kvm must be readable and writable" else "Check libkrun and host virtualization support" }
    ] <> tools <> [ { name: "drizzle-kit", ok: localKit || kit /= Nothing, required: false, detail: if localKit then "Installed with dbsandbox" else fromMaybe "Optional: install drizzle-kit and its database driver for Studio" kit } ]

emptyEngine :: EngineInfo
emptyEngine = { status: "UNAVAILABLE", machine: "", cpus: 0, memoryMiB: 0, diskBytes: 0.0, filesystem: "", storageDriver: "", containers: 0, version: "", message: "Cannot inspect bsdkrun's Docker engine" }

engine :: Aff EngineInfo
engine = do
  result <- attempt Docker.status
  case result of
    Left _ -> pure emptyEngine
    Right status -> do
      machines <- attempt (B.list true)
      let
        machine = case machines of
          Left _ -> Nothing
          Right list -> A.find (\m -> toMaybe m.name == Just Docker.machineName) list
      filesystem <-
        if status.running then do
          usage <- attempt do
            box <- B.get Docker.machineName
            B.exec [ "df", "-h", "/var/lib/docker" ] box
          pure case usage of
            Right r | r.exitCode == 0 -> fromMaybe "" (A.last (A.filter (_ /= "") (S.split (S.Pattern "\n") (S.trim r.stdout))))
            _ -> ""
        else pure ""
      driver <-
        if status.running then do
          found <- attempt (Docker.docker [ "info", "--format", "{{.Driver}}" ])
          pure case found of
            Right r | r.exitCode == 0 -> S.trim r.stdout
            _ -> ""
        else pure ""
      pure
        { status: if status.running then "RUNNING" else if toMaybe status.machineId == Nothing then "NOT CREATED" else "STOPPED"
        , machine: fromMaybe "" (toMaybe status.machineId)
        , cpus: fromMaybe 0 (_.cpus <$> machine)
        , memoryMiB: fromMaybe 0 (_.mem <$> machine)
        , diskBytes: fromMaybe 0.0 (toMaybe status.diskSize)
        , filesystem
        , storageDriver: driver
        , containers: fromMaybe 0 (toMaybe status.containers)
        , version: fromMaybe "" (toMaybe status.version)
        , message: case machines of
            Left _ -> "Cannot read VM resource configuration"
            Right _ -> ""
        }

checkJson :: Check -> J.Json
checkJson c = J.fromObject $ O.fromFoldable [ "name" /\ J.fromString c.name, "ok" /\ J.fromBoolean c.ok, "required" /\ J.fromBoolean c.required, "detail" /\ J.fromString c.detail ]

engineJson :: EngineInfo -> J.Json
engineJson e = J.fromObject $ O.fromFoldable
  [ "status" /\ J.fromString e.status
  , "machine" /\ J.fromString e.machine
  , "cpus" /\ J.fromNumber (Int.toNumber e.cpus)
  , "memoryMiB" /\ J.fromNumber (Int.toNumber e.memoryMiB)
  , "diskBytes" /\ J.fromNumber e.diskBytes
  , "filesystem" /\ J.fromString e.filesystem
  , "storageDriver" /\ J.fromString e.storageDriver
  , "containers" /\ J.fromNumber (Int.toNumber e.containers)
  , "version" /\ J.fromString e.version
  , "message" /\ J.fromString e.message
  ]
