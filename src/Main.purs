module Main (main) where

import Prelude
import Data.Nullable (toMaybe)
import Data.Maybe (Maybe(..))
import Sbx.Platform.Native as N
import Sbx.UI.Control as Control
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (runAff_)
import Effect.Console (error)
import Effect.Exception (message)
import Node.Process (setExitCode)
import Sbx.Database.App as App
import Sbx.Cli as Cli
import Sbx.Cli.Help as Help
import Sbx.Cli.Global as Global

version :: String
version = "0.1.0"

main :: Effect Unit
main = do
  Help.setup
  action <- N.internalAction
  case toMaybe action of
    Just body -> runAff_ finish (Control.execute body)
    Nothing -> do
      selected <- Cli.parseRoot version
      runAff_ finish case selected of
        Cli.Database profile command -> App.run profile command
        Cli.Global command -> Global.run command
  where
  finish = case _ of
    Left err -> error ("error: " <> message err) *> setExitCode 1
    Right code -> setExitCode code
