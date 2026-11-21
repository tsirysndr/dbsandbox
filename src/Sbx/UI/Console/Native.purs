module Sbx.UI.Console.Native (resolve) where

import Effect (Effect)
import Sbx.UI.Console.Plan (Plan)
import OpenTUI.Renderer (TerminalCommand)

foreign import resolve :: Plan -> Effect TerminalCommand
