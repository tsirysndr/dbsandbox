-- | Browser policy and foreground web-tool lifetimes. Native supplies only IO.
module Sbx.UI.Browser (open, await, session, validatePort, studioUrl, connectHost, listening) where

import Prelude
import Control.Monad.Error.Class (throwError)
import Data.Either (either)
import Data.Foldable (or)
import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Data.Traversable (traverse)
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (Aff, attempt, delay, finally, forkAff, joinFiber, killFiber, launchAff_)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (error)
import Effect.Ref as Ref
import Sbx.Platform.Native as N

validatePort :: Int -> Aff Unit
validatePort port = unless (port > 0 && port <= 65535) $ throwError (error "Port must be between 1 and 65535")

connectHost :: String -> String
connectHost host | host == "0.0.0.0" = "127.0.0.1"
connectHost host | host == "::" = "::1"
connectHost host = host

-- Binding a hostname can select a different address family than the web
-- server. Probe both localhost addresses so IPv6-only servers are detected.
listening :: String -> Int -> Aff Boolean
listening host port = or <$> traverse (flip N.tcpOpen port)
  (if host == "localhost" then [ "127.0.0.1", "::1" ] else [ connectHost host ])

studioUrl :: { port :: Int, host :: String } -> String
studioUrl o = "https://local.drizzle.studio" <> case port <> host of
  "" -> ""
  params -> "?" <> params
  where
  port = if o.port == 4983 then "" else "port=" <> show o.port
  host =
    if connectHost o.host == "127.0.0.1" then ""
    else
      (if port == "" then "" else "&") <> "host=" <> N.encodeURIComponent (connectHost o.host)

open :: String -> Aff Unit
open url = do
  host <- liftEffect N.platform
  display <- liftEffect (N.readEnv "DISPLAY")
  wayland <- liftEffect (N.readEnv "WAYLAND_DISPLAY")
  let
    opener = case host.os of
      "macos" -> Just "open"
      "linux" | display /= "" || wayland /= "" -> Just "xdg-open"
      _ -> Nothing
  available <- case opener of
    Nothing -> pure Nothing
    Just name -> liftEffect (N.findExecutable name) <#> toMaybe
  case available of
    Nothing -> liftEffect $ Console.warn ("Open " <> url <> " in your browser (automatic opening is unavailable).")
    Just program -> do
      result <- N.captureTimeout 5000 program [ url ]
      unless (result.exitCode == 0) $ liftEffect $ Console.warn ("Could not open the browser; open " <> url <> " manually.")

await :: String -> Aff Boolean -> Aff Unit
await label probe = go 60
  where
  go 0 = throwError (error (label <> " did not become ready"))
  go remaining = probe >>= \ready -> unless ready (delay (Milliseconds 500.0) *> go (remaining - 1))

-- | Ctrl-C closes web-tool subprocesses and containers through their finalizers.
session :: Aff Int -> Aff Int
session action = do
  signalCode <- liftEffect (Ref.new 0)
  fiber <- forkAff action
  remove <- liftEffect $ N.onInterrupt \signal -> do
    Ref.write (if signal == "SIGINT" then 130 else 143) signalCode
    launchAff_ $ killFiber (error "Web session interrupted") fiber
  result <- finally
    (liftEffect remove *> killFiber (error "Web session closed") fiber)
    (attempt (joinFiber fiber))
  code <- liftEffect (Ref.read signalCode)
  if code /= 0 then pure code else either throwError pure result
