-- | Read the CLI's wire dates without losing RFC3339 strings in SDK conversion.
module Sbx.Branch.Graph.Metadata (list, dateLabel) where

import Bsdkrun.Internal (Async, toAff)
import Bsdkrun.Types (ZfsVolumeInfo)
import Data.Nullable (Nullable)
import Effect.Aff (Aff)

list :: Aff (Array ZfsVolumeInfo)
list = toAff listImpl

foreign import listImpl :: Async (Array ZfsVolumeInfo)

foreign import dateLabel :: Nullable Number -> String
