-- | Help is always plain text. The global color opt-out still applies to
-- | other CLI output, regardless of where --no-color appears in the command.
module Sbx.Cli.Help (setup) where

import Prelude
import Effect (Effect)

foreign import configureArgs :: Effect Boolean

setup :: Effect Unit
setup = void configureArgs
