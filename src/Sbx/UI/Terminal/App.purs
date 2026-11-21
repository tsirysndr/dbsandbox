module Sbx.UI.Terminal.App (run) where

import Prelude
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (Aff, Fiber, attempt, bracket, delay, finally, forkAff, killFiber, launchAff_)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (error, message)
import Effect.Ref as Ref
import Sbx.UI.Browser as Browser
import Sbx.UI.Clipboard as Clipboard
import Sbx.UI.Control as Control
import Sbx.UI.Session as Session
import Sbx.UI.Terminal.Model (Mode(..), Prompt(..), initial, current, filtered, busy, branches, databases, selectedDatabase, updateRows)
import Sbx.UI.Terminal.View as View
import OpenTUI.Renderer as T
import Sbx.Management.Inventory as Inventory
import Sbx.Platform.Native as N
import Sbx.Management.System as System
import Sbx.Management.Logs as Logs
import Sbx.UI.Terminal.Native as Text
import Sbx.UI.Console.Plan as ConsolePlan
import Sbx.UI.Console.Native as ConsoleNative
import Sbx.UI.Time as Time

type Task = { id :: String, fiber :: Fiber Unit }

emptyAction :: String -> Control.Action
emptyAction action = { action, database: "", branch: "", name: "", guest: "", version: "", id: "", cpus: Nothing, mem: Nothing, uiPort: Nothing }

rowAction :: Inventory.ServerRow -> String -> Control.Action
rowAction row action = (emptyAction action) { database = row.database, branch = row.branch }

run :: Aff Int
run = do
  tty <- liftEffect T.available
  if not tty then liftEffect (Console.error "dbsandbox tui needs an interactive terminal; use `dbsandbox ps --all --json` for scripts.") $> 1
  else Browser.session $ bracket T.open T.close \screen -> do
    font <- liftEffect (N.readEnv "DBSANDBOX_NERD_FONT")
    model <- liftEffect (Ref.new (initial { nerdFont = not (A.elem (S.toLower font) [ "0", "false", "off" ]) }))
    journal <- liftEffect Session.create
    tasks <- liftEffect (Ref.new ([] :: Array Task))
    ending <- liftEffect (Ref.new Nothing)
    refreshing <- liftEffect (Ref.new false)
    keyQueue <- liftEffect (Ref.new ([] :: Array T.Key))
    let
      redraw = liftEffect do
        dimensions <- T.size screen
        snapshot <- Ref.read model
        T.render screen (View.tree dimensions snapshot)
    let modify f = liftEffect (Ref.modify_ f model) *> redraw
    let
      refresh = do
        acquired <- liftEffect (Ref.modify' (\old -> { state: true, value: not old }) refreshing)
        when acquired $ finally (liftEffect (Ref.write false refreshing)) do
          result <- attempt do
            inventory <- Inventory.snapshot
            engine <- System.engine
            modify (\m -> (updateRows inventory.rows m) { engine = engine, loading = false, notice = if A.null inventory.errors then "Ready" else S.joinWith "; " inventory.errors })
          case result of
            Left err -> modify (\m -> m { loading = false, notice = message err })
            _ -> pure unit
    let status id value = modify (\m -> m { jobs = map (\j -> if j.id == id then j { status = value } else j) m.jobs })
    let
      perform action = do
        snapshot <- liftEffect (Ref.read model)
        if busy snapshot then modify (\m -> m { notice = "A database operation is running; wait for it to finish" })
        else if action.action == "open-ui" && A.any (\j -> j.status == "RUNNING" && j.kind /= "operation" && j.database == action.database && j.branch == action.branch) snapshot.jobs then
          modify (\m -> m { notice = "A UI is already open for this branch (U closes it)" })
        else do
          result <- attempt (Control.plan snapshot.jobs action)
          case result of
            Left err -> modify (\m -> m { notice = message err })
            Right (Left text) -> modify (\m -> m { notice = text })
            Right (Right next) -> do
              id <- liftEffect N.randomPassword <#> S.take 16
              createdAt <- liftEffect Time.epochNow
              modify (\m -> m { notice = action.action <> " started", mode = Normal, jobs = m.jobs <> [ { id, action: action.action, database: action.database, branch: action.branch, status: "RUNNING", url: next.url, port: next.port, kind: next.kind, createdAt } ] })
              fiber <- forkAff $ finally
                ( do
                    modify (\m -> m { jobs = map (\j -> if j.id == id && j.status == "RUNNING" then j { status = if next.kind == "operation" then "FAILED" else "CLOSED" } else j) m.jobs })
                    refresh
                )
                do
                  outcome <- attempt (Session.runAction journal id action next.port)
                  case outcome of
                    Right 0 -> status id (if next.kind == "operation" then "DONE" else "CLOSED")
                    Right code | next.kind /= "operation" && A.elem code [ 130, 137, 143 ] -> status id "CLOSED"
                    Left _ -> status id "FAILED" *> modify (\m -> m { notice = action.action <> " failed" })
                    _ -> status id "FAILED"
              liftEffect (Ref.modify_ (_ <> [ { id, fiber } ]) tasks)
    let
      submit prompt = do
        m <- liftEffect (Ref.read model)
        let parts = A.filter (_ /= "") (S.split (S.Pattern " ") (S.trim m.input))
        case prompt of
          ExportLogs spec -> do
            let path = S.trim m.input
            exists <- liftEffect (N.fileExists path)
            if path == "" then modify (_ { notice = "Enter a file path" })
            else if exists then modify (_ { notice = "File already exists; choose another path" })
            else do
              result <- attempt (liftEffect (N.exportText path m.logText))
              case result of
                Left err -> modify (_ { notice = "Cannot export logs: " <> message err })
                Right _ -> modify (_ { mode = LogView (spec { follow = false, searching = false }), notice = "Exported logs to " <> path })
          Fork -> case current m of
            Nothing -> modify (_ { mode = Normal, notice = "Select a server first" })
            Just row -> perform ((rowAction row "branch") { name = S.trim m.input })
          Resources -> case A.index parts 0 >>= Int.fromString, A.index parts 1 >>= Int.fromString of
            Just cpus, Just mem | A.length parts == 2 -> modify (\state -> state { mode = Confirm ((emptyAction "configure-engine") { cpus = Just cpus, mem = Just mem }) "Resize shared VM? Every Linux server will restart." })
            _, _ -> modify (_ { notice = "Enter two integers, e.g. 4 4096" })
          New -> case A.head parts of
            Nothing -> modify (_ { notice = "Enter a database name" })
            Just database -> do
              let numeric i = A.index parts i >>= Int.fromString
              let action = (emptyAction "start") { database = database, guest = fromMaybe "linux" (A.index parts 1), version = fromMaybe "" (A.index parts 2), cpus = numeric 3, mem = numeric 4 }
              if A.length parts > 5 || (A.length parts > 3 && numeric 3 == Nothing) || (A.length parts > 4 && numeric 4 == Nothing) then modify (_ { notice = "CPU and memory must be integers" })
              else if action.guest == "linux" && (action.cpus /= Nothing || action.mem /= Nothing) then modify (_ { mode = Confirm action "Start with resource overrides? Linux servers may restart." })
              else perform action
    let
      closeUi row = do
        m <- liftEffect (Ref.read model)
        allTasks <- liftEffect (Ref.read tasks)
        for_ (A.filter (\j -> j.kind /= "operation" && j.status == "RUNNING" && j.database == row.database && j.branch == row.branch) m.jobs) \job ->
          for_ (A.find (\task -> task.id == job.id) allTasks) \task -> killFiber (error "TUI closed database UI") task.fiber *> status job.id "CLOSED"
    let
      copyUrl row = do
        result <- Control.connection row.database row.branch
        case result of
          Left text -> modify (_ { notice = text })
          Right url -> do
            copied <- Clipboard.copy url
            unless copied (liftEffect (T.clipboard screen url))
            modify (_ { notice = if copied then "Connection URL copied to clipboard" else "Connection URL sent to terminal clipboard (OSC 52)" })

    let
      openLogs database branch source = do
        snapshot <- liftEffect (Ref.read model)
        let recent = A.find (\j -> (database == "" || j.database == database) && (branch == "" || j.branch == branch)) (A.reverse snapshot.jobs)
        let id = fromMaybe "" (_.id <$> recent)
        modify (_ { mode = LogView { database, branch, source, id, offset: 0, column: 0, follow: true, filter: "", searching: false, timestamps: true }, logText = "", logError = "", logsLoading = true })

    let
      refreshLogs = do
        snapshot <- liftEffect (Ref.read model)
        case snapshot.mode of
          LogView spec | spec.follow || snapshot.logsLoading -> do
            result <- attempt
              ( if spec.source == "operation" then do
                  value <- liftEffect (Session.read journal spec.id)
                  pure case value of
                    Nothing -> Left "No captured operation output for this branch yet"
                    Just text -> Right text
                else Logs.read spec.database spec.branch spec.source <#> map _.text
              )
            capturedAt <- liftEffect Text.timestamp
            let
              output = case result of
                Left err -> Left (message err)
                Right value -> value
            modify
              ( \state -> case state.mode of
                  LogView newer | newer.database == spec.database && newer.branch == spec.branch && newer.source == spec.source && newer.id == spec.id -> case output of
                    Left text -> state { logsLoading = false, logError = text }
                    Right text -> state { logsLoading = false, logText = text, logError = "", logCapturedAt = if state.logText == text then state.logCapturedAt else capturedAt }
                  _ -> state
              )
          _ -> pure unit

    let
      openConsole row kind = do
        result <- attempt (ConsolePlan.prepare { database: row.database, branch: row.branch, kind })
        case result of
          Left err -> modify (_ { notice = message err })
          Right (Left reason) -> modify (_ { notice = reason })
          Right (Right plan) -> do
            command <- liftEffect (ConsoleNative.resolve plan)
            T.terminal screen command
            refresh

    let validated = perform
    let
      handle key = do
        m <- liftEffect (Ref.read model)
        let move delta = modify (\state -> state { cursor = max 0 (min (A.length (branches state) - 1) (state.cursor + delta)) })
        let text = key.text
        let quit code = liftEffect (Ref.write (Just code) ending)
        if key.ctrl && key.name == "c" then quit 130
        else case m.mode of
          LogView spec -> do
            let adjust f = modify (\state -> state { mode = LogView (f spec) })
            let total = A.length (Logs.filterLines spec.filter m.logText)
            if spec.searching then
              if key.name == "escape" || key.name == "return" then adjust (_ { searching = false })
              else if key.name == "backspace" then adjust (\value -> value { filter = Text.lastChar value.filter, offset = 0 })
              else when (not key.ctrl && not key.meta && key.name /= "tab") (adjust (\value -> value { filter = S.take 200 (value.filter <> Text.clean text), offset = 0 }))
            else if text == "/" then adjust (_ { searching = true, offset = 0 })
            else if text == "t" then adjust (\value -> value { timestamps = not value.timestamps })
            else if text == "d" then do
              suffix <- liftEffect N.randomPassword
              modify (_ { mode = Input (ExportLogs spec), input = "dbsandbox-" <> spec.source <> "-" <> S.take 8 suffix <> ".txt" })
            else if key.name == "escape" || text == "q" then modify (_ { mode = Normal })
            else if text == "j" || key.name == "down" then adjust (\value -> value { offset = max 0 (value.offset - 1), follow = false })
            else if text == "k" || key.name == "up" then adjust (\value -> value { offset = min total (value.offset + 1), follow = false })
            else if key.name == "pageup" then adjust (\value -> value { offset = min total (value.offset + 10), follow = false })
            else if key.name == "pagedown" then adjust (\value -> value { offset = max 0 (value.offset - 10), follow = false })
            else if text == "h" || key.name == "left" then adjust (\value -> value { column = max 0 (value.column - 4) })
            else if text == "l" || key.name == "right" then adjust (\value -> value { column = value.column + 4 })
            else if text == "G" || key.name == "end" then adjust (\value -> value { offset = 0, follow = true })
            else if text == "f" then adjust (\value -> value { offset = 0, follow = not value.follow })
            else if text == "v" then do
              let
                next = case spec.source of
                  "server" -> "vm"
                  "vm" -> "boot"
                  "boot" -> "operation"
                  _ -> "server"
              modify (_ { mode = LogView (spec { source = next, offset = 0, column = 0 }), logText = "", logError = "", logsLoading = true })
            else pure unit
          Help -> modify (_ { mode = Normal })
          Confirm action _ -> if text == "y" then modify (_ { mode = Normal }) *> validated action else when (text == "n" || key.name == "escape" || text == "q") (modify (_ { mode = Normal }))
          DatabaseSelect ->
            if key.name == "escape" || key.name == "tab" then modify (_ { mode = Normal })
            else if key.name == "return" then case A.index (databases m) m.databaseCursor of
              Nothing -> pure unit
              Just database -> modify (_ { database = database, graphOffset = 0, cursor = 0, query = "", searchCursor = 0, mode = Normal })
            else if key.name == "down" || text == "j" then modify (\state -> state { databaseCursor = min (max 0 (A.length (databases state) - 1)) (state.databaseCursor + 1) })
            else if key.name == "up" || text == "k" then modify (\state -> state { databaseCursor = max 0 (state.databaseCursor - 1) })
            else pure unit
          Search ->
            if key.name == "escape" then modify (_ { mode = Normal })
            else if key.name == "return" then case A.index (filtered m) m.searchCursor of
              Nothing -> pure unit
              Just row -> modify (\state -> state { mode = Normal, cursor = fromMaybe state.cursor (A.findIndex (\r -> r.tool == row.tool) (branches state)) })
            else if key.name == "down" || (key.ctrl && key.name == "j") then modify (\state -> state { searchCursor = min (max 0 (A.length (filtered state) - 1)) (state.searchCursor + 1) })
            else if key.name == "up" || (key.ctrl && key.name == "k") then modify (\state -> state { searchCursor = max 0 (state.searchCursor - 1) })
            else if key.name == "backspace" then modify (\state -> state { query = Text.lastChar state.query, searchCursor = 0 })
            else when (not key.ctrl && not key.meta && key.name /= "tab" && S.length (Text.clean text) > 0) (modify (\state -> state { query = S.take 100 (state.query <> Text.clean text), searchCursor = 0 }))
          Input prompt ->
            if key.name == "escape" then modify (_ { mode = Normal })
            else if key.name == "return" then submit prompt
            else if key.name == "backspace" then modify (\state -> state { input = Text.lastChar state.input })
            else when (not key.ctrl && not key.meta && key.name /= "tab") (modify (\state -> state { input = S.take 250 (state.input <> Text.clean text) }))
          Normal -> case text, key.name of
            _, "tab" -> modify (_ { mode = DatabaseSelect, databaseCursor = fromMaybe 0 (A.findIndex (_ == selectedDatabase m) (databases m)) })
            "q", _ -> quit 0
            "/", _ -> modify (_ { mode = Search, query = "", searchCursor = 0 })
            _, "p" | key.ctrl -> modify (_ { mode = Search, query = "", searchCursor = 0 })
            "?", _ -> modify (_ { mode = Help })
            "j", _ -> move 1
            _, "down" -> move 1
            "k", _ -> move (-1)
            _, "up" -> move (-1)
            "g", _ -> modify (\state -> state { graph = not state.graph })
            "[", _ -> modify (\state -> state { graphOffset = max 0 (state.graphOffset - 3) })
            "]", _ -> modify (\state -> state { graphOffset = state.graphOffset + 3 })
            "r", _ -> refresh
            "n", _ -> modify (_ { mode = Input New, input = "", notice = "Enter database, guest and optional version/resources" })
            "e", _ -> modify (_ { mode = Input Resources, input = show (max 2 m.engine.cpus) <> " " <> show (max 2048 m.engine.memoryMiB) })
            "L", _ -> case current m of
              Nothing -> openLogs "" "" "vm"
              Just r -> openLogs r.database r.branch "vm"
            "o", _ -> case current m of
              Nothing -> openLogs "" "" "operation"
              Just r -> openLogs r.database r.branch "operation"
            "S", _ -> modify (_ { mode = Confirm (emptyAction "stop-all") "Stop every configured server? Data is preserved." })
            _, _ -> case current m of
              Nothing -> pure unit
              Just row -> case text, key.name of
                "c", _ -> openConsole row "console"
                "t", _ -> openConsole row "container"
                "v", _ -> openConsole row "vm"
                "l", _ -> openLogs row.database row.branch "server"
                "d", _ -> if row.deletable then modify (_ { mode = Confirm (rowAction row "delete") ("Delete " <> row.database <> "/" <> row.branch <> " and all its data? This cannot be undone.") }) else modify (_ { notice = "Cannot delete the selected branch, main, or the parent server dataset" })
                "b", _ -> modify (_ { mode = Input Fork, input = "" })
                "s", _ | row.kind == "data" -> validated (rowAction row "checkout")
                "s", _ -> if row.running then modify (_ { mode = Confirm (rowAction row "stop") ("Stop " <> row.database <> "/" <> row.branch <> "?") }) else validated (rowAction row "start")
                "u", _ -> validated (rowAction row "open-ui")
                "U", _ -> closeUi row
                "y", _ -> copyUrl row
                _, "return" -> validated (rowAction row "checkout")
                _, _ -> pure unit
    removeKeys <- liftEffect $ T.onKey screen (\key -> Ref.modify_ (_ <> [ key ]) keyQueue)
    removeResize <- liftEffect $ T.onResize screen (launchAff_ redraw)
    let
      pollLoop _ = do
        refresh
        delay (Milliseconds 3000.0)
        pollLoop unit
    poll <- forkAff (pollLoop unit)
    let
      logLoop _ = do
        refreshLogs
        delay (Milliseconds 1000.0)
        logLoop unit
    logPoll <- forkAff (logLoop unit)
    let
      cleanup = do
        liftEffect (removeKeys *> removeResize)
        killFiber (error "TUI closed") poll
        killFiber (error "Log viewer closed") logPoll
        activeTasks <- liftEffect (Ref.read tasks)
        for_ activeTasks \task -> killFiber (error "TUI closed") task.fiber
    finally cleanup do
      redraw
      let
        wait _ = do
          code <- liftEffect (Ref.read ending)
          case code of
            Just value -> pure value
            Nothing -> do
              next <- liftEffect $ Ref.modify'
                ( \queue -> case A.uncons queue of
                    Nothing -> { state: [], value: Nothing }
                    Just item -> { state: item.tail, value: Just item.head }
                )
                keyQueue
              for_ next handle
              delay (Milliseconds 25.0)
              wait unit
      wait unit
