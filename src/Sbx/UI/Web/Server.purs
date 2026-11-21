module Sbx.UI.Web.Server (run, authorized, decodeAction) where

import Prelude
import Bsdkrun.Port as Port
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Traversable (traverse)
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, Fiber, attempt, finally, forkAff, killFiber, never)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (error, message)
import Effect.Ref as Ref
import Foreign.Object as O
import Sbx.UI.Browser as Browser
import Sbx.Management.Catalog as Catalog
import Sbx.Management.Logs as Logs
import Sbx.UI.Control (Action, Job, plan)
import Sbx.UI.Control as Control
import Sbx.UI.Session as Session
import Sbx.UI.Web.Native as HTTP
import Sbx.UI.Web.Page as Page
import Sbx.Net.Http as Http
import Sbx.Management.Inventory as Inventory
import Sbx.Platform.Native as N
import Sbx.State.Store as Store
import Sbx.Management.System as System

type Task = { id :: String, fiber :: Fiber Unit }

decodeAction :: String -> Either String Action
decodeAction = Control.decodeAction

authorized :: Int -> String -> HTTP.Request -> Boolean
authorized port token request =
  A.elem request.host [ "127.0.0.1:" <> show port, "localhost:" <> show port ]
    && N.secureEqual token request.token
    && ((request.origin == "" && request.method == "GET") || A.elem request.origin [ "http://127.0.0.1:" <> show port, "http://localhost:" <> show port ])

jobJson :: Job -> Aff J.Json
jobJson j = do
  ready <-
    if j.status /= "RUNNING" || j.url == "" then pure false
    else if j.kind == "duckdb" then Http.healthy ("http://127.0.0.1:" <> show j.port) O.empty
    else Browser.listening "127.0.0.1" j.port
  pure $ J.fromObject $ O.fromFoldable
    [ "id" /\ J.fromString j.id
    , "action" /\ J.fromString j.action
    , "database" /\ J.fromString j.database
    , "branch" /\ J.fromString j.branch
    , "status" /\ J.fromString j.status
    , "url" /\ J.fromString j.url
    , "ready" /\ J.fromBoolean ready
    ]

run :: { port :: Maybe Int, noOpen :: Boolean } -> Aff Int
run options = Browser.session do
  port <- case options.port of
    Nothing -> Port.findFree 8787
    Just value -> do
      Browser.validatePort value
      free <- Port.isFreeOn "127.0.0.1" value
      unless free $ throwError (error "Dashboard port is in use; choose another with --port")
      pure value
  token <- liftEffect N.randomPassword
  journal <- liftEffect Session.create
  jobs <- liftEffect (Ref.new ([] :: Array Job))
  tasks <- liftEffect (Ref.new ([] :: Array Task))
  gate <- liftEffect (Ref.new false)
  let
    headers kind = O.fromFoldable
      [ "Content-Type" /\ kind
      , "Cache-Control" /\ "no-store"
      , "X-Content-Type-Options" /\ "nosniff"
      , "X-Frame-Options" /\ "DENY"
      , "Content-Security-Policy" /\ ("default-src 'self'; script-src 'nonce-" <> token <> "'; style-src 'nonce-" <> token <> "'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
      ]
  let reply status value = { status, headers: headers "application/json", body: J.stringify value }
  let problem status text = pure $ reply status (J.fromObject (O.singleton "error" (J.fromString text)))
  let setStatus id status = liftEffect $ Ref.modify_ (map (\j -> if j.id == id then j { status = status } else j)) jobs
  let finish id kind = liftEffect $ Ref.modify_ (map (\j -> if j.id == id && j.status == "RUNNING" then j { status = if kind == "operation" then "FAILED" else "CLOSED" } else j)) jobs
  let
    launch action next = do
      id <- liftEffect N.randomPassword <#> S.take 16
      liftEffect $ Ref.modify_ (_ <> [ { id, action: action.action, database: action.database, branch: action.branch, status: "RUNNING", url: next.url, port: next.port, kind: next.kind } ]) jobs
      fiber <- forkAff $ finally (finish id next.kind) do
        result <- attempt (Session.runAction journal id action next.port)
        case result of
          Right 0 -> setStatus id (if next.kind == "operation" then "DONE" else "CLOSED")
          Right code | next.kind /= "operation" && A.elem code [ 130, 137, 143 ] -> setStatus id "CLOSED"
          Left err -> liftEffect (Console.error (message err)) *> setStatus id "FAILED"
          _ -> setStatus id "FAILED"
      liftEffect $ Ref.modify_ (_ <> [ { id, fiber } ]) tasks
      pure $ reply 202 (J.fromObject (O.singleton "id" (J.fromString id)))
  let
    handler request = do
      let hostAllowed = A.elem request.host [ "127.0.0.1:" <> show port, "localhost:" <> show port ]
      if not hostAllowed then problem 403 "Invalid host"
      else if request.method == "GET" && request.path == "/" then pure { status: 200, headers: headers "text/html; charset=utf-8", body: Page.page token }
      else if request.method == "GET" && request.path == "/favicon.ico" then pure { status: 204, headers: headers "image/x-icon", body: "" }
      else if not (authorized port token request) then problem 403 "Invalid dashboard token or origin"
      else if request.method == "GET" && request.path == "/api/logs" then do
        if request.source == "operation" then do
          text <- liftEffect (Session.read journal request.id)
          case text of
            Nothing -> problem 404 "Operation logs are no longer available"
            Just value -> pure $ reply 200 (J.fromObject (O.fromFoldable [ "text" /\ J.fromString value, "source" /\ J.fromString "operation", "label" /\ J.fromString "Operation output", "truncated" /\ J.fromBoolean false ]))
        else do
          result <- Logs.read request.database request.branch request.source
          case result of
            Left text -> problem 400 text
            Right value -> pure $ reply 200 (J.fromObject (O.fromFoldable [ "text" /\ J.fromString value.text, "source" /\ J.fromString value.source, "label" /\ J.fromString value.label, "truncated" /\ J.fromBoolean value.truncated ]))
      else if request.method == "GET" && request.path == "/api/connection" then do
        result <- Control.connection request.database request.branch
        case result of
          Left text -> problem 404 text
          Right url -> pure $ reply 200 (J.fromObject (O.singleton "url" (J.fromString url)))
      else if request.method == "GET" && request.path == "/api/search" then do
        matches <- liftEffect (Store.search request.query)
        pure $ reply 200 (J.fromArray (map J.fromString matches))
      else if request.method == "GET" && request.path == "/api/snapshot" then do
        inventory <- Inventory.snapshot
        engine <- System.engine
        activeJobs <- liftEffect (Ref.read jobs) >>= traverse jobJson
        pure $ reply 200 $ J.fromObject $ O.fromFoldable
          [ "rows" /\ J.fromArray (map Inventory.rowJson inventory.rows)
          , "errors" /\ J.fromArray (map J.fromString inventory.errors)
          , "catalog" /\ Catalog.json
          , "engine" /\ System.engineJson engine
          , "jobs" /\ J.fromArray activeJobs
          ]
      else if request.method == "POST" && request.path == "/api/action" then do
        acquired <- liftEffect $ Ref.modify' (\busy -> { state: true, value: not busy }) gate
        if not acquired then problem 409 "Another request is being prepared; retry shortly"
        else finally (liftEffect (Ref.write false gate)) do
          case decodeAction request.body of
            Left err -> problem 400 err
            Right action | action.action == "close-ui" -> do
              active <- liftEffect (Ref.read tasks)
              allJobs <- liftEffect (Ref.read jobs)
              case A.find (\t -> t.id == action.id) active, A.find (\j -> j.id == action.id && j.kind /= "operation") allJobs of
                Just task, Just _ -> killFiber (error "UI closed from dashboard") task.fiber *> setStatus action.id "CLOSED" $> reply 200 (J.fromBoolean true)
                _, _ -> problem 404 "UI session not found"
            Right action -> do
              active <- liftEffect (Ref.read jobs)
              if A.any (\j -> j.status == "RUNNING" && j.kind == "operation") active then problem 409 "A database operation is running; wait for it to finish"
              else if action.action == "open-ui" && A.any (\j -> j.status == "RUNNING" && j.action == "open-ui" && j.database == action.database && j.branch == action.branch) active then problem 409 "This branch already has a UI session; use its task link"
              else do
                prepared <- plan active action
                case prepared of
                  Left err -> problem 400 err
                  Right next -> launch action next
      else problem 404 "Not found"
  server <- HTTP.listen port handler
  let
    cleanup = do
      active <- liftEffect (Ref.read tasks)
      for_ active \task -> killFiber (error "Dashboard closed") task.fiber
      HTTP.close server
  finally cleanup do
    let address = "http://127.0.0.1:" <> show port
    liftEffect $ Console.log ("dbsandbox dashboard: " <> address <> " (Ctrl-C closes the dashboard; database servers keep running)")
    unless options.noOpen $ Browser.open address
    never
