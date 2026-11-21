module Sbx.State.Native where

import Prelude
import Effect (Effect)

foreign import prepare :: String -> Effect Unit
foreign import protect :: String -> Effect Unit
