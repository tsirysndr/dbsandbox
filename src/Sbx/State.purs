module Sbx.State (module Types, load, lookup, save, saveFor, clear) where

import Prelude
import Data.Maybe (Maybe)
import Effect (Effect)
import Sbx.State.Types (State, decode) as Types
import Sbx.State.Store as Store
import Sbx.Database.Profile (Profile)

load :: String -> Effect (Maybe Types.State)
load = Store.load

lookup :: String -> Effect (Maybe Types.State)
lookup = Store.load

save :: String -> Types.State -> Effect Unit
save = Store.save

clear :: String -> Effect Unit
clear = Store.clear

saveFor :: Profile -> Types.State -> Effect Unit
saveFor = Store.saveFor
