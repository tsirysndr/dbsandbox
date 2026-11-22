module Sbx.Cluster.App (run) where

import Prelude
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (either)
import Data.Maybe (fromMaybe, maybe)
import Effect.Aff (Aff, bracket, launchAff_)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (error)
import Foreign.Object as O
import Sbx.Cluster.Cli (Command(..))
import Sbx.Cluster.Native as N
import Sbx.Platform.Native as Host

run :: Command -> Aff Int
run command = do
  let
    path = case command of
      Serve opts -> opts.config
      Join opts -> opts.config
  body <- liftEffect (N.readText path)
  json <- either (throwError <<< error) pure (jsonParser body)
  object <- maybe (throwError (error "Expected a JSON configuration object")) pure (J.toObject json)
  invocation <- liftEffect N.invocation
  authentication <- resolveToken command object "DBSANDBOX_CLUSTER_TOKEN" "token"
  apiAuthentication <- resolveToken command object "DBSANDBOX_API_TOKEN" "api_token"
  storeToken <- liftEffect (Host.readEnv "DBSANDBOX_STORE_TOKEN")
  let
    configured = object
      # O.insert "executable" (J.fromString invocation.executable)
      # O.insert "executable_args" (J.fromArray (map J.fromString invocation.args))
      # O.insert "token" (J.fromString authentication.token)
      # O.insert "api_token" (J.fromString apiAuthentication.token)
      # (if storeToken == "" then identity else O.insert "store_token" (J.fromString storeToken))
      # case command of
          Serve _ -> O.delete "join"
          Join opts -> O.insert "join" (J.fromString opts.server)
  bracket (N.launch (J.stringify (J.fromObject configured))) (N.stop <<< _.server) \running -> do
    liftEffect do
      Console.log ("dbsandbox cluster listening on " <> running.address)
      when authentication.generated do
        Console.log ("Cluster auth token: " <> authentication.token)
        Console.log "Use this token in DBSANDBOX_CLUSTER_TOKEN on joining nodes."
      when apiAuthentication.generated do
        Console.log ("API auth token: " <> apiAuthentication.token)
        Console.log "Use this token as Bearer authorization for remote API requests (DBSANDBOX_API_TOKEN)."
    bracket
      (liftEffect (Host.onInterrupt (const (launchAff_ (N.stop running.server)))))
      liftEffect
      (const (N.wait running.server))
    pure 0

resolveToken :: Command -> O.Object J.Json -> String -> String -> Aff { token :: String, generated :: Boolean }
resolveToken command object environmentName field = do
  environmentToken <- liftEffect (Host.readEnv environmentName)
  let supplied = if environmentToken /= "" then environmentToken else fromMaybe "" (O.lookup field object >>= J.toString)
  if supplied /= "" then pure { token: supplied, generated: false }
  else case command of
    Join _ -> throwError (error ("Set " <> environmentName <> " to the existing server token before joining"))
    Serve _ -> do
      generated <- liftEffect Host.randomPassword
      pure { token: generated, generated: true }
