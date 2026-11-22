module Test.Sqlite where

import Prelude
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Sbx.Database.Sqlite (profile)
import Data.Maybe (Maybe(..))
import Data.String as String
import Sbx.Runtime.Engine (runtimeVersionAllowed)
import Sbx.Database.Profile (Os(..))

main :: Effect Unit
main = do
  unless (runtimeVersionAllowed "bsdkrun 0.12.1" && not (runtimeVersionAllowed "bsdkrun 0.12.0")) $ throw "image-store runtime requirement"
  let c = profile.defaults
  unless (profile.url "latest" c 8080 == "http://127.0.0.1:8080") $ throw "url"
  unless (profile.image "latest" == "ghcr.io/tursodatabase/libsql-server:latest" && profile.image "debian:trixie" == "debian:trixie" && profile.image "turso" == "sqlite-sbx-tools") $ throw "image"
  unless (profile.command "turso" == Just [ "sleep", "infinity" ] && profile.command "sqlite3" == Just [ "sleep", "infinity" ] && profile.command "latest" == Nothing && profile.linuxOnly && not (profile.studioSupported Linux "turso") && profile.studioSupported Linux "latest") $ throw "serverless variants"
  unless (profile.image "sqlite3" == "sqlite-sbx-tools") $ throw "sqlite3 image"
  unless (profile.dataDir Linux == "/var/lib/sqlite" && profile.studioSupported Linux "latest" && not (profile.studioSupported Linux "sqlite3")) $ throw "serverless engines have no studio"
  case profile.tools of
    Nothing -> throw "SQLite tools image is required"
    Just tools ->
      unless
        ( String.contains (String.Pattern "FROM debian:trixie-slim") tools.dockerfile
            && String.contains (String.Pattern "--mount=type=tmpfs") tools.dockerfile
            && String.contains (String.Pattern "chroot") tools.dockerfile
            && String.contains (String.Pattern "SHELL=/bin/sh") tools.dockerfile
            && String.contains (String.Pattern "COPY --from=dbsandbox-debian-build /dbsandbox-rootfs/ /") tools.dockerfile
        )
        $ throw "Trixie package installs need a stable build filesystem"
  log "sqlite-sbx tests passed"
