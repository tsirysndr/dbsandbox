module Sbx.Cli.Global (run) where

import Prelude
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Foldable (for_)
import Data.String as S
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Sbx.Management.Catalog as Catalog
import Sbx.Cli.Completion as Completion
import Sbx.UI.Web.Server as Dashboard
import Sbx.Cli.GlobalCommand (GlobalCommand(..))
import Sbx.Management.Inventory as Inventory
import Sbx.Platform.Native as N
import Sbx.Management.Operations as Operations
import Sbx.Management.System as System
import Sbx.UI.Terminal.App as Tui

say :: String -> Aff Unit
say = liftEffect <<< Console.log

pad :: Int -> String -> String
pad width value = value <> S.take (max 1 (width - S.length value)) (S.joinWith "" (A.replicate width " "))

run :: GlobalCommand -> Aff Int
run = case _ of
  Completion shell -> say (Completion.generate shell) $> 0
  Databases options -> do
    if options.json then say (J.stringify Catalog.json)
    else do
      say (pad 15 "DATABASE" <> pad 20 "DEFAULT VERSION" <> pad 8 "PORT" <> "GUEST OS")
      for_ Catalog.rows \r -> say (pad 15 r.name <> pad 20 r.version <> pad 8 (show r.port) <> S.joinWith ", " r.guests)
    pure 0
  Ps options -> do
    inventory <- Inventory.snapshot
    let rows = A.filter (\r -> options.all || r.running || r.status == "UNKNOWN") inventory.rows
    if options.json then say (J.stringify (J.fromArray (map Inventory.rowJson rows)))
    else do
      tint <- liftEffect N.colorOutput
      let paint flag text = if tint && flag then N.ansi "38;2;0;255;195" text else text
      let width = max 20 (A.foldl (\n r -> max n (S.length r.branch + 4)) 0 rows)
      say (pad 15 "DATABASE" <> pad width "BRANCH (* selected)" <> pad 10 "GUEST" <> pad 10 "STATUS" <> pad 8 "PORT" <> "URL")
      for_ rows \r -> say (pad 15 r.database <> paint r.active (pad width ((if r.active then "* " else "  ") <> r.branch)) <> pad 10 r.guest <> paint r.running (pad 10 r.status) <> pad 8 (if r.port == 0 then "-" else show r.port) <> r.url)
      when (A.null rows) $ say (if options.all then "No configured sandboxes." else "No running sandboxes; use `dbsandbox ps --all` to include stopped instances.")
    for_ inventory.errors (liftEffect <<< Console.error)
    pure (if A.null inventory.errors then 0 else 1)
  Doctor options -> do
    checks <- System.doctor
    if options.json then say (J.stringify (J.fromArray (map System.checkJson checks)))
    else
      for_ checks \c -> say (pad 10 (if c.ok then "ok" else if c.required then "FAIL" else "optional") <> pad 18 c.name <> c.detail)
    pure (if A.all (\c -> c.ok || not c.required) checks then 0 else 1)
  StopAll -> Operations.stopAll
  EngineStatus options -> do
    info <- System.engine
    if options.json then say (J.stringify (System.engineJson info))
    else do
      say ("Engine: " <> info.status)
      say ("  VM: " <> info.machine <> "  CPU: " <> show info.cpus <> " vCPU  Memory: " <> show info.memoryMiB <> " MiB")
      say ("  Configured image-store disk: " <> show info.diskBytes <> " bytes")
      say ("  Filesystem usage: " <> info.filesystem)
      say ("  Docker: " <> info.version <> "  Driver: " <> info.storageDriver <> "  Containers: " <> show info.containers)
      unless (info.message == "") (say info.message)
    pure (if info.status == "UNAVAILABLE" then 1 else 0)
  Dashboard options -> Dashboard.run options
  Tui -> Tui.run
