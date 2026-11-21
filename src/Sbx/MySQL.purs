module Sbx.MySQL (profile) where
import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object
import Sbx.MariaDB as MariaDB
import Sbx.Profile (ClientCmd(..), Profile, shellQuote, withBsdPath)

profile :: Profile
profile = MariaDB.profile
  { cli = "dbsandbox mysql", tool = "mysql-sbx", product = "MySQL"
  , defaultTag = "8.4", linuxOnly = true
  , image = \tag -> if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag else "mysql:" <> tag
  , defaults = { user: "root", password: "mysql", db: "mysql" }
  , dataDir = const "/var/lib/mysql", rootDisk = const Nothing, provision = const Nothing
  , env = \c -> Object.fromFoldable $ ["MYSQL_ROOT_PASSWORD" /\ c.password, "MYSQL_DATABASE" /\ c.db]
      <> if c.user == "root" then [] else ["MYSQL_USER" /\ c.user, "MYSQL_PASSWORD" /\ c.password]
  -- Local clones use ZFS snapshots instead of replication. Binary-log cache
  -- resizing is unsupported by the guest's shared ZFS filesystem.
  , command = const (Just ["--skip-log-bin"])
  , ready = \_ _ c -> withBsdPath ("MYSQL_PWD=" <> shellQuote c.password <> " mysql --protocol=TCP -h 127.0.0.1 -u " <> shellQuote c.user <> " " <> shellQuote c.db <> " -Nse 'SELECT 1'")
  , client = Guest \_ _ c -> withBsdPath ("mysql -h 127.0.0.1 -u " <> shellQuote c.user <> " -p" <> shellQuote c.password <> " " <> shellQuote c.db)
  , clientName = "mysql", clientAliases = []
  }
