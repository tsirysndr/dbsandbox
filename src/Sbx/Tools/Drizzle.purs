-- | Reuse a complete installation, or provision an isolated pinned toolchain.
module Sbx.Tools.Drizzle (Kit, locate, ensure, usable) where

import Prelude
import Control.Alt ((<|>))
import Bsdkrun.Internal (Async, toAff)
import Control.Monad.Error.Class (throwError)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), maybe)
import Data.Nullable (toMaybe)
import Data.String as S
import Effect.Aff (Aff, attempt)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (error)
import Foreign.Object as O
import Sbx.Database.Profile (Profile)
import Sbx.Platform.Native as N

type Kit = { cmd :: String, args :: Array String, where :: String }

foreign import usableImpl :: String -> String -> Array String -> Async Boolean

usable :: Kit -> String -> Aff Boolean
usable kit driver = do
  bun <- liftEffect (N.findExecutable "bun") <#> toMaybe
  node <- liftEffect (N.findExecutable "node") <#> toMaybe
  case bun <|> node of
    Nothing -> pure false
    Just runtime -> toAff (usableImpl runtime kit.where [ "drizzle-orm", driver ])

locate :: Aff Kit
locate = do
  root <- liftEffect N.toolRoot
  node <- liftEffect N.nodePath
  let bin = N.pathJoin root "node_modules/drizzle-kit/bin.cjs"
  local <- liftEffect (N.fileExists bin)
  onPath <- liftEffect (N.findExecutable "drizzle-kit") <#> toMaybe
  case local, onPath of
    true, _ -> pure { cmd: node, args: [ bin ], where: bin }
    _, Just cmd -> pure { cmd, args: [], where: cmd }
    _, _ -> throwError (error "drizzle-kit is not installed")

-- A standalone binary has no node_modules. Keep Studio and all its supported
-- drivers together rather than depending on unrelated global installations.
manifest :: String
manifest = "{\"private\":true,\"dependencies\":{\"drizzle-kit\":\"0.31.11\",\"drizzle-orm\":\"0.45.4\",\"@libsql/client\":\"0.18.0\",\"pg\":\"8.23.1\",\"mysql2\":\"3.24.6\"}}\n"

ensure :: Profile -> Aff Kit
ensure profile = do
  existing <- attempt locate
  complete <- case existing of
    Right kit -> usable kit profile.driver
    Left _ -> pure false
  case existing of
    Right kit | complete -> pure kit
    _ -> do
      root <- liftEffect (N.configDir "dbsandbox")
      bunRuntime <- liftEffect (N.findExecutable "bun") <#> toMaybe
      nodeRuntime <- liftEffect (N.findExecutable "node") <#> toMaybe
      runtime <- maybe (throwError (error "Install Bun or Node.js to run Drizzle Studio")) pure (bunRuntime <|> nodeRuntime)
      let dir = N.pathJoin root ("tools/drizzle-" <> S.take 16 (N.sha256 manifest))
      let bin = N.pathJoin dir "node_modules/drizzle-kit/bin.cjs"
      let kit = { cmd: runtime, args: [ bin ], where: bin }
      cached <- usable kit profile.driver
      unless cached do
        bun <- liftEffect (N.findExecutable "bun") <#> toMaybe >>= maybe
          (throwError (error "Install Bun to provision Drizzle Studio and its database drivers"))
          pure
        liftEffect do
          N.mkdirp dir
          N.writeText (N.pathJoin dir "package.json") manifest
          log "Installing Drizzle Studio with its SQLite, PostgreSQL and MySQL drivers ..."
        code <- N.spawnInheritIn bun [ "install", "--ignore-scripts" ] O.empty (Just dir)
        unless (code == 0) (throwError (error "Installing the managed Drizzle toolchain failed; retry Studio after fixing package access"))
        ready <- usable kit profile.driver
        unless ready (throwError (error ("The managed Drizzle toolchain cannot load " <> profile.driver)))
      pure kit
