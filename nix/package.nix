{ pkgs, bunLib, bsdkrun, craneLib }:
let
  inherit (pkgs) lib;
  manifest = builtins.fromJSON (builtins.readFile ../package.json);
  version = manifest.version;
  bunFetchers = import ./bun-deps.nix { inherit (pkgs) fetchurl; };
  lockMatches = bunFetchers.lockfileHash == builtins.hashFile "sha256" ../bun.lock;
  bunDeps = bunLib.fetchBunDeps { bunNix = ./bun-deps.nix; };
  pursDeps = import ./purescript-deps.nix { inherit pkgs; };
  linuxLibraries = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.stdenv.cc.cc.lib pkgs.openssl pkgs.zlib
  ];
  installFlags = [
    "--frozen-lockfile" "--offline" "--linker=hoisted"
    "--os=*" "--cpu=*" "--libc=*"
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ "--backend=copyfile" ];
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json ../bun.lock ../spago.yaml ../spago.lock
      ../src (lib.fileset.fileFilter (file: file.name != "native.node") ../packages) ../bin ../ui/src ../ui/assets ../ui/build.mjs
      ../Cargo.toml ../Cargo.lock ../crates ../scripts/build-cluster.mjs
      ../scripts/generate-bun-nix.mjs ./bun-deps.nix
    ];
  };
  # Include devDependencies, with lifecycle downloads disabled. Nix supplies purs.
  nodeModules = assert lib.assertMsg lockMatches
    "Run bun scripts/generate-bun-nix.mjs after changing bun.lock";
    pkgs.stdenvNoCC.mkDerivation {
      pname = "dbsandbox-node-modules";
      inherit version bunDeps;
      src = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [ ../package.json ../bun.lock ];
      };
      nativeBuildInputs = [ pkgs.bun pkgs.nodejs_24 bunLib.hook ];
      bunInstallFlags = installFlags;
      dontRunLifecycleScripts = true;
      dontUseBunBuild = true;
      dontUseBunCheck = true;
      dontUseBunInstall = true;
      dontFixup = true;
      buildPhase = ''
        rm -f node_modules/.bin/purs
        ln -s ${pkgs.purescript}/bin/purs node_modules/.bin/purs
      '';
      installPhase = ''
        mkdir -p "$out"
        cp -R node_modules "$out/"
      '';
    };
  rustSource = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ../Cargo.toml ../Cargo.lock ../crates ];
  };
  rustArgs = {
    pname = "dbsandbox-cluster-native";
    inherit version;
    src = rustSource;
    strictDeps = true;
    cargoExtraArgs = "--locked -p dbsandbox-cluster-neon";
    cargoProfile = "release";
    doCheck = false;
  };
  cargoArtifacts = craneLib.buildDepsOnly rustArgs;
  clusterNative = craneLib.buildPackage (rustArgs // {
    inherit cargoArtifacts;
    installPhaseCommand = ''
      mkdir -p "$out/lib"
      artifact=$(find target -type f -name 'libdbsandbox_cluster_neon${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}' -print -quit)
      test -n "$artifact"
      install -m755 "$artifact" "$out/lib/native.node"
    '';
  });
  toolchain = [ pkgs.cargo pkgs.rustc pkgs.rustfmt pkgs.clippy pkgs.bun pkgs.nodejs_24 pkgs.purescript pkgs.git pkgs.curl pkgs.pkg-config ];
  dbsandbox = pkgs.stdenv.mkDerivation {
    pname = "dbsandbox";
    inherit version;
    src = source;
    nativeBuildInputs = toolchain ++ [ pkgs.makeWrapper ];
    # Bun appends its application to the executable; stripping or ELF fixups
    # destroy that payload. The Nix-provided Bun already has its runtime loader.
    dontFixup = true;
    buildInputs = linuxLibraries;
    configurePhase = ''
      runHook preConfigure
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      cp -R ${nodeModules}/node_modules .
      chmod -R u+w node_modules
      export PATH="$PWD/node_modules/.bin:$PATH"
      runHook postConfigure
    '';
    buildPhase = ''
      runHook preBuild
      bun scripts/generate-bun-nix.mjs --check
      purs compile 'src/**/*.purs' 'packages/*/src/**/*.purs' \
        ${lib.concatMapStringsSep " " (path: lib.escapeShellArg "${path}/src/**/*.purs") (builtins.attrValues pursDeps)}
      bun ui/build.mjs
      cp ${clusterNative}/lib/native.node packages/cluster/native.node
      mkdir -p dist
      bun build --compile --minify bin/dbsandbox.js --outfile dist/dbsandbox
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 dist/dbsandbox "$out/bin/dbsandbox"
      wrapProgram "$out/bin/dbsandbox" \
        --prefix PATH : ${lib.makeBinPath [ bsdkrun pkgs.docker-client ]} \
        ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux
          "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath linuxLibraries}"}
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      actual=$("$out/bin/dbsandbox" --version)
      printf '%s\n' "$actual"
      test "$actual" = 'dbsandbox ${version}'
      "$out/bin/dbsandbox" --help
    '';
    meta = {
      description = manifest.description;
      homepage = "https://github.com/tsirysndr/dbsandbox";
      license = lib.licenses.mit;
      mainProgram = "dbsandbox";
      platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    };
  };
  devShell = pkgs.mkShell {
    packages = toolchain ++ [ bsdkrun pkgs.docker-client pkgs.jq pkgs.sqlite pkgs.python3 pkgs.gnumake ];
    buildInputs = linuxLibraries;
    LD_LIBRARY_PATH = lib.optionalString pkgs.stdenv.hostPlatform.isLinux
      (lib.makeLibraryPath linuxLibraries);
    shellHook = ''
      # Keep dependencies writable so bun install remains usable in the checkout.
      if [ ! -d node_modules ] || [ "$(cat node_modules/.dbsandbox-nix-deps 2>/dev/null)" != "${nodeModules}" ]; then
        if [ -L node_modules ]; then rm node_modules; fi
        mkdir -p node_modules
        cp -R ${nodeModules}/node_modules/. node_modules/
        chmod -R u+w node_modules
        printf '%s\n' '${nodeModules}' > node_modules/.dbsandbox-nix-deps
      fi
      export PATH="$PWD/node_modules/.bin:$PATH"
    '';
  };
in { inherit dbsandbox devShell; }
