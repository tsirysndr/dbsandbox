-- | WebSocket/PTY transport; sandbox policy and command selection are PureScript.
module Sbx.UI.Web.Terminal.Native (Manager, create, attach, reserve, close) where

import Prelude
import Bsdkrun.Internal (Async, toAff)
import Effect (Effect)
import Effect.Aff (Aff)
import Sbx.UI.Web.Native (Server)
import Sbx.UI.Console.Plan (Plan)

foreign import data Manager :: Type

foreign import create :: Effect Manager

foreign import attach :: Manager -> Int -> Server -> Effect Unit

foreign import reserve :: Manager -> Plan -> Effect { id :: String, ticket :: String, label :: String }

foreign import closeImpl :: Manager -> Async Unit

close :: Manager -> Aff Unit
close manager = toAff (closeImpl manager)
