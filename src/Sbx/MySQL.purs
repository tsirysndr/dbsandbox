module Sbx.MySQL (profile) where
import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object
import Sbx.MariaDB as MariaDB
import Sbx.BsdServer as Server
import Sbx.Native as Native
import Sbx.Profile (ClientCmd(..), FancyCmd(..), Creds, Os(..), Profile, shellQuote, withBsdPath)

profile :: Profile
profile = MariaDB.profile
  { cli = "dbsandbox mysql", tool = "mysql-sbx", product = "MySQL"
  , defaultTag = "8.4", linuxOnly = false
  , image = \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "mysql:" <> tag
  , defaults = { user: "root", password: "mysql", db: "sandbox" }
  , provision = case _ of
      Linux -> Nothing
      os -> Just (provision os)
  , env = \c -> Object.fromFoldable $ ["MYSQL_ROOT_PASSWORD" /\ c.password, "MYSQL_DATABASE" /\ c.db]
      <> if c.user == "root" then [] else ["MYSQL_USER" /\ c.user, "MYSQL_PASSWORD" /\ c.password]
  -- Local clones use ZFS snapshots instead of replication. Binary-log cache
  -- resizing is unsupported by the guest's shared ZFS filesystem.
  , command = const (Just ["--skip-log-bin"])
  , ready = \_ _ c -> withBsdPath ("MYSQL_PWD=" <> shellQuote c.password <> " mysql --protocol=TCP -h 127.0.0.1 -u " <> shellQuote c.user <> " " <> shellQuote c.db <> " -Nse 'SELECT 1'")
  , client = Guest \_ _ c -> withBsdPath ("mysql -h 127.0.0.1 -u " <> shellQuote c.user <> " -p" <> shellQuote c.password <> " " <> shellQuote c.db)
  , clientName = "mysql", clientAliases = []
  , url = const url
  , fancy = {name: "mycli", cmd: HostTool \c port -> ["mycli", url c port]}
  }


-- Keep the rc service disabled: the data branch must be mounted before start.
-- MySQL 8.4 is packaged on FreeBSD; pkgsrc currently provides MySQL 8.0.
provision :: Os -> String
provision os = String.joinWith "\n" $
  [ "set -eu"
  , "export PATH=/usr/local/bin:/usr/local/sbin:/usr/local/libexec:/usr/pkg/bin:/usr/pkg/sbin:$PATH"
  ] <> (case os of
    FreeBSD ->
      [ "pkg info -e mysql84-server >/dev/null 2>&1 || env ASSUME_ALWAYS_YES=yes pkg install -y mysql84-server"
      , "pkg clean -ay >/dev/null 2>&1 || true"
      , "sysrc -x mysql_enable >/dev/null 2>&1 || true"
      ]
    NetBSD ->
      [ "A=$(uname -p); [ \"$A\" = x86_64 ] && A=amd64"
      , "export PKG_PATH=\"https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$A/$(uname -r | cut -d. -f1).0/All/\""
      , "command -v pkgin >/dev/null 2>&1 || pkg_add pkgin"
      , "pkg_info -qE 'mysql-server-[0-9]*' >/dev/null 2>&1 || pkgin -y install mysql-server"
      , "pkgin clean >/dev/null 2>&1 || true"
      , "{ grep -v '^mysqld=YES' /etc/rc.conf || true; } > /etc/rc.conf.new && mv /etc/rc.conf.new /etc/rc.conf"
      ]
    Linux -> []) <>
  [ "dir=" <> shellQuote dir
  , "mkdir -p \"$dir\"; chown mysql:mysql \"$dir\""
  , "if [ ! -d \"$dir/mysql\" ]; then mysqld --no-defaults --initialize-insecure --user=mysql --datadir=\"$dir\" --skip-log-bin --mysqlx=0; fi"
  , Server.mysqlScript dir 3306 "start"
  , "i=0; until mysqladmin --no-defaults --socket=\"$dir/sbx.sock\" ping --silent >/dev/null 2>&1; do i=$((i+1)); if [ $i -ge 120 ]; then cat \"$dir/sbx-server.log\"; exit 1; fi; sleep 1; done"
  , "admin() { if mysql --no-defaults --socket=\"$dir/sbx.sock\" -u root -Nse 'SELECT 1' >/dev/null 2>&1; then mysql --no-defaults --socket=\"$dir/sbx.sock\" -u root; else MYSQL_PWD=\"$SBX_PASSWORD\" mysql --no-defaults --socket=\"$dir/sbx.sock\" -u root; fi; }"
  , "U=$(printf '%s' \"$SBX_USER\" | sed \"s/'/''/g\")"
  , "P=$(printf '%s' \"$SBX_PASSWORD\" | sed \"s/'/''/g\")"
  , "D=$(printf '%s' \"$SBX_DB\" | sed 's/`/``/g')"
  , "admin <<SQL"
  , "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';"
  , "CREATE USER IF NOT EXISTS '$U'@'%' IDENTIFIED BY '$P';"
  , "ALTER USER '$U'@'%' IDENTIFIED BY '$P';"
  , "GRANT ALL PRIVILEGES ON *.* TO '$U'@'%' WITH GRANT OPTION;"
  , "CREATE DATABASE IF NOT EXISTS \\`$D\\`;"
  , "ALTER USER 'root'@'localhost' IDENTIFIED BY '$P';"
  , "SQL"
  ]
  where
  dir = MariaDB.profile.dataDir os


url :: Creds -> Int -> String
url c port = "mysql://" <> Native.encodeURIComponent c.user <> ":" <> Native.encodeURIComponent c.password <> "@127.0.0.1:" <> show port <> "/" <> Native.encodeURIComponent c.db
