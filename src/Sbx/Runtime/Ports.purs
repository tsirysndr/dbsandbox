-- | Docker publishes inside the VM before bsdkrun forwards a port on the host.
module Sbx.Runtime.Ports (Snapshot, parse, read, available, seed) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Docker as Docker
import Control.Monad.Error.Class (throwError)
import Data.Array as A
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.String.Regex as R
import Data.String.Regex.Flags (noFlags)
import Effect.Aff (Aff)
import Effect.Exception (error)

type Snapshot = { low :: Int, high :: Int, busy :: Array Int }

words :: String -> Array String
words text = case R.regex "\\s+" noFlags of
  Left _ -> []
  Right pattern -> R.split pattern (S.trim text)

parse :: String -> Either String Snapshot
parse text = do
  let lines = S.split (S.Pattern "\n") (S.trim text)
  let range = words (fromMaybe "" (A.head lines))
  case A.index range 0 >>= Int.fromString, A.index range 1 >>= Int.fromString of
    Just low, Just high | low > 0 && high >= low && high <= 65535 && S.contains (S.Pattern "local_address") text ->
      Right { low, high, busy: A.nub (A.mapMaybe localPort (A.drop 1 lines)) }
    _, _ -> Left "Cannot read TCP port allocation from the Docker VM"
  where
  localPort line = do
    local <- A.index (words line) 1
    hex <- A.last (S.split (S.Pattern ":") local)
    port <- Int.fromStringAs Int.hexadecimal hex
    if port > 0 && port <= 65535 then Just port else Nothing

read :: Aff Snapshot
read = do
  engine <- B.get Docker.machineName
  result <- B.exec [ "sh", "-c", "cat /proc/sys/net/ipv4/ip_local_port_range /proc/net/tcp && { test ! -r /proc/net/tcp6 || cat /proc/net/tcp6; }" ] engine
  if result.exitCode /= 0 then throwError (error "Cannot inspect TCP ports inside the Docker VM")
  else case parse result.stdout of
    Left reason -> throwError (error reason)
    Right snapshot -> pure snapshot

-- Explicit ports may use the ephemeral range; automatic forks avoid competing
-- with connections the VM opens between allocation and container startup.
available :: Boolean -> Snapshot -> Int -> Boolean
available automatic snapshot port = not (A.elem port snapshot.busy) && (not automatic || port < snapshot.low || port > snapshot.high)

seed :: Snapshot -> Int -> Int
seed snapshot port
  | port >= snapshot.low && port <= snapshot.high = if snapshot.high < 65535 then snapshot.high + 1 else 1024
  | otherwise = port
