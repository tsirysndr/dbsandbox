-- | The terminal renderer owns input parsing, Unicode cell measurement,
-- | layout and paint. Application state and actions stay in PureScript.
module OpenTUI.Renderer where

import Prelude
import Control.Promise (Promise, toAffE)
import Effect (Effect)
import Effect.Aff (Aff)

foreign import data Renderer :: Type

foreign import data Node :: Type

type Key = { name :: String, text :: String, ctrl :: Boolean, meta :: Boolean }

type BoxOptions =
  { id :: String
  , direction :: String
  , width :: String
  , height :: Int
  , grow :: Int
  , paddingX :: Int
  , paddingY :: Int
  , gap :: Int
  , border :: Boolean
  , borderColor :: String
  , background :: String
  , title :: String
  , position :: String
  , left :: Int
  , top :: Int
  , zIndex :: Int
  }

type TextOptions =
  { id :: String
  , content :: String
  , foreground :: String
  , background :: String
  , bold :: Boolean
  , width :: String
  , height :: Int
  , grow :: Int
  }

boxOptions :: BoxOptions
boxOptions = { id: "", direction: "column", width: "", height: 0, grow: 0, paddingX: 0, paddingY: 0, gap: 0, border: false, borderColor: "#27272a", background: "#09090b", title: "", position: "", left: 0, top: 0, zIndex: 0 }

textOptions :: TextOptions
textOptions = { id: "", content: "", foreground: "#d4d4d8", background: "transparent", bold: false, width: "", height: 1, grow: 0 }

foreign import available :: Effect Boolean

foreign import openImpl :: Effect (Promise Renderer)

open :: Aff Renderer
open = toAffE openImpl

foreign import closeImpl :: Renderer -> Effect (Promise Unit)

close :: Renderer -> Aff Unit
close = toAffE <<< closeImpl

foreign import box :: BoxOptions -> Array Node -> Node

foreign import text :: TextOptions -> Node

type TextSpan = { text :: String, foreground :: String, background :: String, bold :: Boolean }

foreign import styledText :: TextOptions -> Array TextSpan -> Node

foreign import render :: Renderer -> Node -> Effect Unit

foreign import size :: Renderer -> Effect { columns :: Int, rows :: Int }

foreign import onKey :: Renderer -> (Key -> Effect Unit) -> Effect (Effect Unit)

foreign import onResize :: Renderer -> Effect Unit -> Effect (Effect Unit)

foreign import clipboard :: Renderer -> String -> Effect Unit

type TerminalCommand = { program :: String, args :: Array String, label :: String }

foreign import terminalImpl :: Renderer -> TerminalCommand -> Effect (Promise Unit)

terminal :: Renderer -> TerminalCommand -> Aff Unit
terminal renderer command = toAffE (terminalImpl renderer command)
