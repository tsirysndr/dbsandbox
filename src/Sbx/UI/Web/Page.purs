-- | The offline Svelte/Tailwind bundle. The per-session CSP nonce and API token
-- | are injected by PureScript; database operations remain in Sbx.UI.Web.Server.
module Sbx.UI.Web.Page (page) where

import Data.String as S

foreign import template :: String

page :: String -> String
page token = S.replaceAll (S.Pattern "__TOKEN__") (S.Replacement token) template
