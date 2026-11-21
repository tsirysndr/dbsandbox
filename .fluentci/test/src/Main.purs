module Main (all, unit, e2e) where

import Prelude
import Data.Either (either)
import Data.Maybe (Maybe, fromMaybe)
import Effect (Effect)
import Effect.Exception (throw)
import FluentCI.Plugin as P

run :: P.Pipeline -> Effect String
run plan = P.stdout plan >>= either (throw <<< P.errorMessage) pure

-- | Install bsdkrun with verified archives and test normal sandbox startup, then run PureScript/Bun unit and live database/ZFS tests.
-- | @param directory Project checkout directory; defaults to the current directory.
-- | @param bsdkrunVersion Official bsdkrun release to install; defaults to v0.12.2.
all :: { directory :: Maybe String, bsdkrunVersion :: Maybe String } -> Effect String
all args = run $ P.pipeline "dbsandbox-test"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "bun", "bin/ci.js", "install", fromMaybe "v0.12.2" args.bsdkrunVersion ]
  # P.exec [ "bun", "run", "test" ]
  # P.exec [ "bun", "run", "build:bin" ]
  # P.exec [ "bun", "run", "test:e2e" ]

-- | Run PureScript unit tests and Bun CLI/CI tests without installing a VM runtime.
-- | @param directory Project checkout directory; defaults to the current directory.
unit :: { directory :: Maybe String } -> Effect String
unit args = run $ P.pipeline "dbsandbox-unit"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "bun", "run", "test" ]

-- | Run Bun's real VM, password, port, persistence and ZFS branch tests using an installed bsdkrun.
-- | @param directory Project checkout directory; defaults to the current directory.
e2e :: { directory :: Maybe String } -> Effect String
e2e args = run $ P.pipeline "dbsandbox-e2e"
  # P.withWorkdir (fromMaybe "." args.directory)
  # P.exec [ "bun", "run", "test:e2e" ]
