-- | Run Debian package upgrades on tmpfs, then copy the finished rootfs into
-- | a fresh image layer. dpkg's hard-link backups require stable file handles;
-- | older Docker stores backed by virtio-fs cannot provide those under overlay.
module Sbx.Database.Debian (layer) where

import Prelude
import Data.String as S
import Sbx.Database.Profile (shellQuote)

layer :: String -> Array String -> Array String
layer base commands =
  [ "FROM " <> base <> " AS dbsandbox-debian-build"
  , S.joinWith " \\\n    "
      [ "RUN --mount=type=tmpfs,target=/tmp/dbsandbox-build-root set -eu;"
      , "target=/tmp/dbsandbox-build-root;"
      , "tar --one-file-system --exclude=./dev --exclude=./proc --exclude=./sys --exclude=./tmp --exclude=./run --exclude=./mnt -C / -cf - . | tar -C \"$target\" -xf -;"
      , "mkdir -p \"$target/dev\" \"$target/proc\" \"$target/sys\" \"$target/tmp\" \"$target/run\" \"$target/mnt\"; chmod 1777 \"$target/tmp\";"
      , "mknod -m 666 \"$target/dev/null\" c 1 3; mknod -m 666 \"$target/dev/zero\" c 1 5; mknod -m 666 \"$target/dev/random\" c 1 8; mknod -m 666 \"$target/dev/urandom\" c 1 9;"
      , "cp /etc/resolv.conf \"$target/etc/resolv.conf\";"
      , "chroot \"$target\" /usr/bin/env DEBIAN_FRONTEND=noninteractive SHELL=/bin/sh /bin/sh -ec " <> shellQuote (S.joinWith " && " commands) <> ";"
      , "rm -f \"$target/dev/null\" \"$target/dev/zero\" \"$target/dev/random\" \"$target/dev/urandom\";"
      , "mkdir /dbsandbox-rootfs; cp -a \"$target/.\" /dbsandbox-rootfs/"
      ]
  , "FROM scratch"
  , "COPY --from=dbsandbox-debian-build /dbsandbox-rootfs/ /"
  , "ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  , "CMD [\"bash\"]"
  ]
