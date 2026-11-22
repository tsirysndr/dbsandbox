module Sbx.Cluster.Cli (Command(..), parser) where

import Prelude
import Options.Applicative (Parser, command, help, helper, info, long, metavar, progDesc, strOption, subparser)

data Command = Serve { config :: String } | Join { config :: String, server :: String }

parser :: Parser Command
parser = subparser
  ( command "serve" (info (helper <*> (Serve <<< { config: _ } <$> config)) (progDesc "Run a cluster node and its unified database and branch API"))
      <> command "join" (info (helper <*> join) (progDesc "Join through any live node; existing nodes keep running"))
  )
  where
  config = strOption (long "config" <> metavar "FILE" <> help "Cluster JSON configuration (Consul or etcd)")
  join = ado
    path <- config
    server <- strOption (long "server" <> metavar "URL" <> help "Any live dbsandbox API node")
    in Join { config: path, server }
