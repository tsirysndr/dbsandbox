-- | UI operations run in an isolated child. Even SDK commands using inherited
-- | file descriptors write into this child's pipes, never OpenTUI's terminal.
module Sbx.UI.Session (Journal, create, append, read, runAction, redact, limit) where

import Prelude hiding (append)
import Bsdkrun.Internal (Async, toAff)
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Effect (Effect)
import Effect.Aff (Aff, bracket)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import Foreign.Object as O
import Sbx.Database.Profiles as Profiles
import Sbx.Branch.Identity as I
import Sbx.State as State
import Sbx.UI.Control as Control
import Sbx.Platform.Native as N

foreign import data Child :: Type

foreign import start :: String -> (String -> Effect Unit) -> Effect Child

foreign import launch :: { program :: String, args :: Array String } -> (String -> Effect Unit) -> Effect Child

foreign import waitImpl :: Child -> Async Int

foreign import stopImpl :: Child -> Async Unit

type Journal = Ref.Ref { logs :: O.Object String, order :: Array String }

limit :: Int
limit = 262144

create :: Effect Journal
create = Ref.new { logs: O.empty, order: [] }

redact :: Array String -> String -> String
redact secrets text = foldl (\value secret -> if secret == "" then value else S.replaceAll (S.Pattern secret) (S.Replacement "***") (S.replaceAll (S.Pattern (N.encodeURIComponent secret)) (S.Replacement "***") value)) text secrets

append :: Journal -> String -> Array String -> String -> Effect Unit
append journal id secrets chunk = Ref.modify_
  ( \buffer ->
      let
        existing = fromMaybe "" (O.lookup id buffer.logs)
        content = redact secrets (existing <> chunk)
        order = if A.elem id buffer.order then buffer.order else buffer.order <> [ id ]
        kept = A.drop (max 0 (A.length order - 50)) order
        logs = O.filterKeys (flip A.elem kept) (O.insert id (S.drop (max 0 (S.length content - limit)) content) buffer.logs)
      in
        { logs, order: kept }
  )
  journal

read :: Journal -> String -> Effect (Maybe String)
read journal id = O.lookup id <<< _.logs <$> Ref.read journal

currentSecrets :: Control.Action -> Effect (Array String)
currentSecrets action = case Profiles.find action.database of
  Nothing -> pure []
  Just db -> do
    root <- State.load db.profile.tool
    let
      tool = case root of
        Just st | action.branch == "" || st.branch == action.branch -> db.profile.tool
        _ -> I.instanceName db.profile.tool action.branch
    selected <- State.load tool
    pure (A.nub ([ db.profile.defaults.password ] <> map _.password (A.catMaybes [ root, selected ])))

runAction :: Journal -> String -> Control.Action -> Int -> Aff Int
runAction journal id action port = do
  liftEffect (append journal id [] "")
  let request = action { uiPort = if port > 0 then Just port else Nothing }
  let
    collect chunk = do
      secrets <- currentSecrets action
      append journal id secrets chunk
  bracket (liftEffect (start (J.stringify (Control.encode request)) collect))
    (toAff <<< stopImpl)
    (toAff <<< waitImpl)
