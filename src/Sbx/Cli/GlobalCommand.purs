module Sbx.Cli.GlobalCommand where

import Data.Maybe (Maybe)

data GlobalCommand
  = Ps { all :: Boolean, json :: Boolean }
  | Databases { json :: Boolean }
  | Doctor { json :: Boolean }
  | StopAll
  | EngineStatus { json :: Boolean }
  | Completion String
  | Dashboard { port :: Maybe Int, noOpen :: Boolean }

  | Tui
