module Sbx.Management.Operations (runEntry, stopAll) where

import Prelude
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (maybe)
import Data.Traversable (traverse)
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Sbx.Database.App as App
import Sbx.Cli (Command(..))
import Sbx.Branch.Identity as I
import Sbx.Management.Inventory as Inventory

runEntry :: Inventory.Entry -> Command -> Aff Int
runEntry e cmd = App.run (Inventory.scoped e) (Inventory.target e cmd)

stopAll :: Aff Int
stopAll = do
  inventory <- Inventory.snapshot
  for_ inventory.errors (liftEffect <<< Console.error)
  -- Children first: a root BSD VM may also host its forked processes.
  let ordered = A.filter (I.isInstance <<< _.tool) inventory.entries <> A.filter (not <<< I.isInstance <<< _.tool) inventory.entries
  results <- traverse
    ( \e -> do
        let shouldStop = maybe false (\r -> r.kind /= "data" && r.status /= "STOPPED") (A.find (\r -> r.tool == e.tool) inventory.rows)
        if not shouldStop then pure true
        else do
          result <- attempt (runEntry e Stop)
          case result of
            Right 0 -> pure true
            _ -> liftEffect (Console.error ("Could not stop " <> e.database <> "/" <> e.state.branch)) $> false
    )
    ordered
  let ok = A.all identity results && A.null inventory.errors
  liftEffect $ Console.log ((if ok then "Stop-all complete" else "Stop-all finished with errors") <> "; database data and the shared Docker engine are preserved.")
  pure (if ok then 0 else 1)
