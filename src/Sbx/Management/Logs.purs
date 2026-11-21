-- | Bounded, read-only runtime log snapshots. No follow subprocess inherits
-- | the UI terminal; clients poll these snapshots while follow is enabled.
module Sbx.Management.Logs (Result, read, bounded, filterLines) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Docker as Docker
import Control.Alt ((<|>))
import Data.Array as A
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (Aff, attempt, delay, parallel, sequential)
import Effect.Exception (error, message)
import Sbx.Management.Inventory as Inventory
import Sbx.UI.Session as Session

type Result = { text :: String, source :: String, label :: String, truncated :: Boolean }

bounded :: String -> { text :: String, truncated :: Boolean }
bounded text = { text: S.drop (max 0 (S.length text - Session.limit)) text, truncated: S.length text > Session.limit }

read :: String -> String -> String -> Aff (Either String Result)
read database branch source = do
  entries <- Inventory.discover
  let selected = A.find (\e -> e.database == database && e.state.branch == branch) entries
  let secrets = map (_.password <<< _.state) entries
  if not (A.elem source [ "server", "vm", "boot" ]) then pure (Left "Unknown log source")
  else if
    source == "server" &&
      ( case selected of
          Nothing -> true
          Just e -> e.kind == "data"
      ) then pure (Left "Configured branch not found")
  else do
    result <- sequential (parallel (attempt (fetch selected)) <|> parallel (delay (Milliseconds 5000.0) $> Left (error "Reading logs timed out")))
    pure case result of
      Left err -> Left (Session.redact secrets (message err))
      Right output ->
        let
          trimmed = bounded (Session.redact secrets output)
          label =
            if source == "server" then database <> "/" <> branch
            else case selected of
              Just e | e.state.os /= "linux" -> e.profile.tool
              _ -> Docker.machineName
        in
          Right { text: trimmed.text, truncated: trimmed.truncated, source, label }
  where
  fetch selected = case selected of
    Just e | source == "server" && e.state.os == "linux" -> do
      output <- Docker.docker [ "logs", "--tail", "500", "--timestamps", e.tool ]
      if output.exitCode == 0 then pure (output.stdout <> output.stderr) else pure ("Container logs unavailable: " <> output.stderr)
    _ -> do
      let
        name = case selected of
          Just e | e.state.os /= "linux" -> e.profile.tool
          _ -> Docker.machineName
      machine <- B.get name
      B.logs (source == "boot") machine

filterLines :: String -> String -> Array String
filterLines query text =
  let
    terms = A.filter (_ /= "") (S.split (S.Pattern " ") (S.toLower (S.trim query)))
  in
    A.filter (\line -> A.all (\term -> S.contains (S.Pattern term) (S.toLower line)) terms) (S.split (S.Pattern "\n") text)
