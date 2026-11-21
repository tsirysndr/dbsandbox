-- | A native OpenTUI component tree: flex layout, background panels, focus
-- | backgrounds and centered overlays. There are no hand-drawn ASCII frames.
module Sbx.UI.Terminal.View (tree) where

import Prelude
import Data.Array as A
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toMaybe)
import Data.String as S
import OpenTUI.Renderer as UI
import Sbx.UI.Terminal.Model (Model, Mode(..), Prompt(..), current, filtered, branches, databases, selectedDatabase)
import Sbx.UI.Terminal.Native as Text
import Sbx.Management.Logs as Logs
import Sbx.Branch.Graph as Graph
import Sbx.Branch.Graph.Metadata as Metadata
import Sbx.UI.LogPresentation as Presentation

accent :: String
accent = "#8129ff"

muted :: String
muted = "#71717a"

label :: String -> String -> UI.Node
label color content = UI.text (UI.textOptions { content = Text.clean content, foreground = color })

space :: UI.Node
space = label muted " "

panel :: String -> Int -> Array UI.Node -> UI.Node
panel title height children = UI.box (UI.boxOptions { title = "", border = false, borderColor = "#303036", background = "#111113", paddingX = 2, paddingY = 1, height = height, width = "100%" }) ([ label muted title ] <> children)

cell :: String -> Int -> String -> UI.Node
cell color width content = UI.text (UI.textOptions { content = Text.clean content, foreground = color, width = show width })

row :: Boolean -> Boolean -> Array UI.Node -> UI.Node
row selected heading = UI.box (UI.boxOptions { direction = "row", height = if heading then 2 else 1, gap = 1, background = if selected then "#241d35" else "transparent", paddingX = 1 })

tree :: { columns :: Int, rows :: Int } -> Model -> UI.Node
tree dimensions m =
  let
    width = dimensions.columns
    compact = width < 90
    room = max 1 (dimensions.rows - (if dimensions.rows >= 40 then 34 else if dimensions.rows >= 30 then 27 else if dimensions.rows >= 24 then 20 else 14))
    offset = max 0 (m.cursor - room + 1)
    branchRows = branches m
    visible = A.slice offset (offset + room) branchRows
    nodes = Graph.layout branchRows
    graphLanes = fromMaybe 1 (map (\node -> (Graph.position nodes node).lanes) (A.head nodes))
    graphWidth = min (if compact then 12 else 18) (graphLanes * 3)
    graphOffset = min m.graphOffset (max 0 (graphLanes * 3 - graphWidth))
    selected = current m
    modeName = case m.mode of
      Normal -> "NORMAL"
      DatabaseSelect -> "DATABASE"
      Search -> "SEARCH"
      Input _ -> "COMMAND"
      Confirm _ _ -> "CONFIRM"
      Help -> "HELP"
      LogView _ -> "LOGS"
    sidebar = UI.box (UI.boxOptions { width = "22", height = 0, grow = 0, paddingX = 2, paddingY = 1, border = false, borderColor = "#27272a", background = "#111113", title = "", gap = 1 })
      [ label accent "◈ dbsandbox", space, label "#d4d4d8" "◉  Databases", label muted "⑂  Branches", label muted "▣  VM resources", space, label muted "LOCAL ENVIRONMENT", label (if m.engine.status == "RUNNING" then "#00ffc3" else "#d4d4d8") m.engine.status, label muted (show m.engine.cpus <> " CPU · " <> show m.engine.memoryMiB <> " MiB"), space, label accent "/  Find a branch", label muted "?  Keyboard shortcuts" ]
    metric title value = UI.box (UI.boxOptions { border = false, borderColor = "#27272a", background = "#111113", paddingX = 2, paddingY = 1, height = 5, grow = 1 }) [ label muted title, label (if title == "ENGINE" && value == "RUNNING" then "#00ffc3" else accent) value ]
    metrics = UI.box (UI.boxOptions { direction = "row", height = 5, gap = 1 })
      [ metric "ENGINE" m.engine.status, metric "VM RESOURCES" (show m.engine.cpus <> " CPU · " <> show m.engine.memoryMiB <> " MiB"), metric "SERVERS" (show (A.length (A.filter _.running m.rows)) <> " running / " <> show (A.length m.rows)) ]
    columns = [ cell muted 1 " " ] <> (if m.graph then [ cell muted graphWidth "GRAPH" ] else []) <> if compact then [ cell muted 26 "BRANCH", cell muted 9 "STATUS" ] else [ cell muted 25 "BRANCH", cell muted 9 "GUEST", cell muted 10 "STATUS", cell muted 7 "PORT", cell muted 16 "CREATED (LOCAL)" ]
    serverLine i r = row (offset + i == m.cursor) false $
      [ cell accent 1 (if offset + i == m.cursor then "›" else " ") ]
        <>
          ( if not m.graph then []
            else case A.index nodes (offset + i) of
              Nothing -> [ cell muted graphWidth "" ]
              Just node -> [ UI.styledText (UI.textOptions { width = show graphWidth }) (A.slice graphOffset (graphOffset + graphWidth) (Graph.terminal (Graph.position nodes node))) ]
          )
        <> [ cell (if r.active then accent else "#a1a1aa") (if compact then 26 else 25) ((if r.active then "⑂ " else "  ") <> r.branch) ]
        <> (if compact then [] else [ cell muted 9 r.guest ])
        <> [ cell (if r.running then "#00ffc3" else muted) (if compact then 9 else 10) ((if r.running then "● " else "○ ") <> r.status) ]
        <> (if compact then [] else [ cell muted 7 (if r.port == 0 then "—" else show r.port), cell muted 16 (S.take 16 (Metadata.dateLabel r.createdAt)) ])
    table = UI.box (UI.boxOptions { border = false, borderColor = "#303036", background = "#111113", title = "", paddingX = 1, paddingY = 1, grow = 1, width = "100%" })
      ( [ label muted "SERVERS & BRANCHES", label accent ("DATABASE  ▾ " <> selectedDatabase m <> "  [Tab]"), row false true columns ]
          <> (if A.null branchRows then [ label muted (if m.loading then "Loading servers…" else "No servers yet. Press n to start a database.") ] else A.mapWithIndex serverLine visible)
      )
    connection = panel "CONNECTION" 6
      [ label "#d4d4d8"
          ( case selected of
              Nothing -> "Select a server"
              Just r -> r.url
          )
      , label muted
          ( case selected of
              Nothing -> ""
              Just r -> "Created: " <> Metadata.dateLabel r.createdAt <> " · " <> (fromMaybe "parent unknown" (map ("from " <> _) (toMaybe r.parent)))
          )
      , label muted "y copy URL  ·  u open database UI  ·  Enter select branch"
      ]
    tasks = panel "ACTIVITY" 6 ([ label accent m.notice ] <> map (\j -> label (if j.status == "RUNNING" then "#00ffc3" else muted) (j.action <> " " <> j.database <> "  " <> j.status)) (A.take 1 (A.reverse m.jobs)))
    body = UI.box (UI.boxOptions { grow = 1, gap = 1, paddingX = 1, width = "" })
      ([ UI.box (UI.boxOptions { height = 3, paddingX = 1 }) [ UI.text (UI.textOptions { content = "dbsandbox_", foreground = accent, bold = true }), label muted "Independent databases. Parallel branches." ] ] <> (if dimensions.rows < 24 then [] else [ metrics ]) <> [ table ] <> (if dimensions.rows < 30 then [] else [ connection ]) <> (if dimensions.rows < 40 then [] else [ tasks ]))
    main = UI.box (UI.boxOptions { direction = "row", gap = 1, grow = 1, paddingX = 1, paddingY = 1, width = "100%" }) ((if width < 115 then [] else [ sidebar ]) <> [ body ])
    selection = case selected of
      Nothing -> "no selection"
      Just r -> (if m.nerdFont then "\xe0a0 " else "⑂ ") <> r.branch
    bar = UI.box (UI.boxOptions { direction = "row", height = 1, background = "#202024", width = "100%" })
      [ UI.text (UI.textOptions { content = " " <> modeName <> " ", foreground = "#ffffff", background = accent, bold = true, width = show (S.length modeName + 2) }), UI.text (UI.textOptions { content = "  dbsandbox  │  " <> selection, foreground = "#d4d4d8", grow = 1 }), UI.text (UI.textOptions { content = " " <> show (if A.null branchRows then 0 else m.cursor + 1) <> "/" <> show (A.length branchRows) <> " ", foreground = "#ffffff", background = accent }) ]
    hint = UI.box (UI.boxOptions { paddingX = 2, height = 1 }) [ label (if m.notice == "Ready" then muted else accent) (if m.notice == "Ready" then "g graph  j/k move  / find  b fork  s start/stop  y copy  l/L logs  o output  ? help  q quit" else m.notice) ]
    modal title height children = UI.box (UI.boxOptions { position = "absolute", left = max 1 ((width - min 84 (width - 4)) / 2), top = max 1 ((dimensions.rows - height) / 2), width = show (max 20 (min 84 (width - 4))), height = height, border = false, borderColor = accent, background = "#15111d", title = "", paddingX = 2, paddingY = 1, gap = 1, zIndex = 100 }) ([ label accent title ] <> children)
    overlay = case m.mode of
      LogView spec ->
        let
          rows = Logs.filterLines spec.filter m.logText
          count = max 1 (dimensions.rows - 12)
          end = max 0 (A.length rows - spec.offset)
          start = max 0 (end - count)
          content = A.slice start end rows
          title = if spec.source == "operation" then "OPERATION OUTPUT" else if spec.source == "server" then "DATABASE LOGS" else if spec.source == "boot" then "VM BOOT LOG" else "VM CONSOLE LOG"
          lines = if m.logText == "" then [ label muted (if m.logsLoading then "Loading logs…" else "No log output yet.") ] else map (\line -> UI.styledText UI.textOptions (Presentation.chunks spec.timestamps m.logCapturedAt spec.filter spec.column (max 1 (width - 10)) (Text.clean line))) content
        in
          [ UI.box (UI.boxOptions { position = "absolute", left = 2, top = 1, width = show (max 20 (width - 4)), height = max 8 (dimensions.rows - 4), border = false, borderColor = accent, background = "#111113", title = "", paddingX = 2, paddingY = 1, zIndex = 100 })
              ( [ label accent title, space, label accent (spec.database <> (if spec.branch == "" then "" else "/" <> spec.branch) <> "  ·  " <> spec.source <> "  ·  " <> (if spec.follow then "FOLLOWING" else "PAUSED")), label muted "v source  f follow  / filter  t dates  d export  j/k scroll  h/l pan  G bottom  Esc close", label (if spec.searching then accent else muted) ("⌕ " <> spec.filter <> (if spec.searching then "▏" else "") <> "  ·  " <> show (A.length rows) <> " lines"), space ]
                  <> (if m.logError == "" then [] else [ label "#fbbf24" m.logError ])
                  <> lines
              )
          ]
      Normal -> []
      DatabaseSelect ->
        let
          names = databases m
          start = max 0 (m.databaseCursor - 5)
          options = A.mapWithIndex (\i name -> UI.box (UI.boxOptions { height = 1, paddingX = 1, background = if start + i == m.databaseCursor then "#392b54" else "transparent" }) [ label (if start + i == m.databaseCursor then accent else "#d4d4d8") ((if name == selectedDatabase m then "✓ " else "  ") <> name) ]) (A.slice start (start + 8) names)
        in
          [ modal "SELECT DATABASE" (min 17 (dimensions.rows - 4)) ([ label muted "↑↓ / j/k choose  ·  Enter select  ·  Esc cancel" ] <> options) ]
      Search ->
        let
          found = filtered m
          start = max 0 (m.searchCursor - 5)
          matches = A.slice start (start + 6) found
          lines = A.mapWithIndex (\i r -> UI.box (UI.boxOptions { height = 1, background = if start + i == m.searchCursor then "#392b54" else "transparent", paddingX = 1 }) [ label (if start + i == m.searchCursor then accent else "#d4d4d8") r.branch ]) matches
        in
          [ modal "FIND A BRANCH" (min 17 (dimensions.rows - 4))
              ( [ label accent ("⌕  " <> m.query <> "▏"), label muted (show (A.length found) <> " matches  ·  ↑↓ move  ·  Enter jump  ·  Esc cancel") ]
                  <> (if A.null found then [ label muted "No matching branches" ] else lines)
              )
          ]
      Help ->
        [ modal "KEYBOARD SHORTCUTS" (min 21 (dimensions.rows - 4))
            (map (label "#d4d4d8") [ "Tab              Choose database", "g / [ / ]        Graph toggle / pan lanes", "j/k or ↑↓        Navigate servers", "/ or Ctrl-P      Fuzzy branch search", "Enter            Select branch", "b                Fork branch", "d                Delete inactive branch", "s                Start / stop selected server", "u / U            Open / close database UI", "y                Copy connection URL", "l / L            Database / VM logs", "o                Captured operation output", "n                Start a database", "e                Override VM CPU / memory", "S                Stop all servers", "r                Refresh", "q / Ctrl-C       Quit; owned UI sessions close", "Esc / ?          Close help" ])
        ]
      Confirm _ prompt -> [ modal "CONFIRM ACTION" 8 [ label "#e4e4e7" prompt, label accent "y confirm     n / Esc cancel" ] ]
      Input prompt ->
        [ modal
            ( case prompt of
                Fork -> "FORK BRANCH"
                New -> "START DATABASE"
                Resources -> "VM RESOURCES"
                ExportLogs _ -> "EXPORT LOGS AS TEXT"
            )
            9
            [ label muted
                ( case prompt of
                    Fork -> "New branch name"
                    New -> "database [guest] [version] [CPU] [MiB]"
                    Resources -> "CPU cores and memory MiB (e.g. 4 4096)"
                    ExportLogs _ -> "File path for the full current raw log snapshot"
                )
            , label accent ("> " <> m.input <> "▏")
            , label muted "Enter submit  ·  Esc cancel"
            ]
        ]
  in
    UI.box (UI.boxOptions { width = "100%", height = dimensions.rows, background = "#09090b" }) ([ main, hint, bar ] <> overlay)
