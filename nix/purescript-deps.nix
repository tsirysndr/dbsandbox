{ pkgs }:
let
  lock = builtins.fromJSON (builtins.readFile ../spago.lock);
  gitSources = {
    "12307006922b696126e277f7e96ef27397dc32ae" = "sha256-i9cl1w2p4bzEFGzAQlsfAvm+PLzkDDI633ZzjRIupPE=";
  };
in pkgs.lib.mapAttrs (name: package:
  let
    archive = if package.type == "registry" then pkgs.fetchurl {
      url = "https://packages.registry.purescript.org/${name}/${package.version}.tar.gz";
      hash = package.integrity;
    } else if package.type == "git" && name == "bsdkrun" then pkgs.fetchurl {
      url = "https://codeload.github.com/tsirysndr/bsdkrun-purescript/tar.gz/${package.rev}";
      hash = gitSources.${package.rev};
    } else throw "Unsupported PureScript dependency ${name}; update nix/purescript-deps.nix";
  in pkgs.runCommand "purescript-${name}-source" {} ''
    mkdir -p "$out"
    tar -xzf ${archive} --strip-components=1 -C "$out"
  ''
) lock.packages
