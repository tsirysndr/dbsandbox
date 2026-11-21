-- | Clipboard tool selection stays in PureScript; the FFI only starts a
-- | process with argv and writes bytes to stdin (never through a shell).
module Sbx.UI.Clipboard (copy) where

import Prelude
import Bsdkrun.Internal (Async, toAff)
import Data.Array as A
import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Sbx.Platform.Native as N

foreign import writeImpl :: String -> Array String -> String -> Async Int

copy :: String -> Aff Boolean
copy text = do
  host <- liftEffect N.platform
  wayland <- liftEffect (N.readEnv "WAYLAND_DISPLAY")
  display <- liftEffect (N.readEnv "DISPLAY")
  let
    candidates =
      if host.os == "macos" then [ { name: "pbcopy", args: [] } ]
      else
        (if wayland == "" then [] else [ { name: "wl-copy", args: [] } ])
          <> (if display == "" then [] else [ { name: "xclip", args: [ "-selection", "clipboard" ] }, { name: "xsel", args: [ "--clipboard", "--input" ] } ])
  let
    tryTools tools = case A.uncons tools of
      Nothing -> pure false
      Just { head, tail } -> do
        found <- liftEffect (N.findExecutable head.name) <#> toMaybe
        case found of
          Nothing -> tryTools tail
          Just program -> do
            code <- toAff (writeImpl program head.args text)
            if code == 0 then pure true else tryTools tail
  tryTools candidates
