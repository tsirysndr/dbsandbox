{
  description = "Database sandboxes with parallel ZFS branches";

  nixConfig = {
    extra-substituters = [ "https://bsdkrun.cachix.org" ];
    extra-trusted-public-keys = [
      "bsdkrun.cachix.org-1:KzvN59TR6k15k7Fl7SxTEhxJnE0MvbxLC2HpxdVlC9Q="
    ];
  };

  inputs = {
    bsdkrun.url = "github:tsirysndr/bsdkrun";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, bun2nix, bsdkrun }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      project = system: import ./nix/package.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        bsdkrun = bsdkrun.packages.${system}.bsdkrun;
        bunLib = bun2nix.packages.${system}.default;
      };
    in {
      packages = forAllSystems (system: {
        inherit (project system) dbsandbox;
        default = self.packages.${system}.dbsandbox;
      });
      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.dbsandbox}/bin/dbsandbox";
          meta.description = "Database sandboxes with parallel ZFS branches";
        };
      });
      devShells = forAllSystems (system: {
        default = (project system).devShell;
      });
    };
}
