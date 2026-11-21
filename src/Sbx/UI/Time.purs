-- | Present instants in the viewer's local timezone, leaving stored values intact.
module Sbx.UI.Time (created, timestamp, now) where

import Data.Nullable (Nullable)
import Effect (Effect)

foreign import created :: Nullable Number -> String

foreign import timestamp :: String -> String

foreign import now :: Effect String
