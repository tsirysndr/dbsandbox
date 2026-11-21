module Sbx.UI.Terminal.Model (Prompt(..), Mode(..), Model, LogSpec, initial, filtered, current, busy, databases, selectedDatabase, branches, updateRows) where

import Prelude
import Data.Array as A
import Data.Maybe (Maybe, fromMaybe)
import Sbx.UI.Control as Control
import Sbx.UI.Terminal.Fuzzy as Fuzzy
import Sbx.Management.Inventory as Inventory
import Sbx.Management.System as System
import Sbx.Branch.Graph as Graph

data Prompt = Fork | New | Resources | ExportLogs LogSpec
type LogSpec = { database :: String, branch :: String, source :: String, id :: String, offset :: Int, column :: Int, follow :: Boolean, filter :: String, searching :: Boolean, timestamps :: Boolean }

data Mode = Normal | DatabaseSelect | Search | Input Prompt | Confirm Control.Action String | Help | LogView LogSpec

type Model = { graph :: Boolean, graphOffset :: Int, database :: String, databaseCursor :: Int, nerdFont :: Boolean, logCapturedAt :: String, rows :: Array Inventory.ServerRow, engine :: System.EngineInfo, cursor :: Int, mode :: Mode, query :: String, input :: String, searchCursor :: Int, jobs :: Array Control.Job, notice :: String, loading :: Boolean, logText :: String, logError :: String, logsLoading :: Boolean }

initial :: Model
initial = { graph: true, graphOffset: 0, database: "", databaseCursor: 0, nerdFont: true, logCapturedAt: "", rows: [], engine: { status: "UNKNOWN", machine: "", cpus: 0, memoryMiB: 0, diskBytes: 0.0, filesystem: "", storageDriver: "", containers: 0, version: "", message: "" }, cursor: 0, mode: Normal, query: "", input: "", searchCursor: 0, jobs: [], notice: "Loading configured servers…", loading: true, logText: "", logError: "", logsLoading: false }

filtered :: Model -> Array Inventory.ServerRow
filtered m = Fuzzy.rank m.query (branches m)

current :: Model -> Maybe Inventory.ServerRow
current m = A.index (branches m) m.cursor

busy :: Model -> Boolean
busy m = A.any (\j -> j.status == "RUNNING" && j.kind == "operation") m.jobs

databases :: Model -> Array String
databases m = A.sort (A.nub (map _.database m.rows))

selectedDatabase :: Model -> String
selectedDatabase m = if A.elem m.database (databases m) then m.database else fromMaybe "" (A.head (databases m))

branches :: Model -> Array Inventory.ServerRow
branches m = map _.item (Graph.layout (A.filter (\row -> row.database == selectedDatabase m) m.rows))

-- | Polling must not move keyboard actions to a different branch after a fork.
updateRows :: Array Inventory.ServerRow -> Model -> Model
updateRows rows model =
  let
    next = model { rows = rows, database = selectedDatabase (model { rows = rows }) }
    chosen = current model >>= \row -> A.findIndex (\candidate -> candidate.tool == row.tool) (branches next)
  in
    next { cursor = fromMaybe (min model.cursor (max 0 (A.length (branches next) - 1))) chosen }
