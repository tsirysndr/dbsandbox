module Sbx.UI.Terminal.Native where

import Effect (Effect)

foreign import timestamp :: Effect String

foreign import clean :: String -> String

foreign import lastChar :: String -> String
