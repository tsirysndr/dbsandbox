# Nix

The root flake builds dbsandbox from source for Linux x86_64/ARM64 and macOS
ARM64. `nix develop` includes the compiler, package manager, formatters, all Bun
dependencies, bsdkrun, and the Docker CLI. The package does not need Node or Bun
at runtime. macOS follows bsdkrun's Homebrew libkrun setup; see the root README.

After changing `bun.lock`, regenerate its integrity-pinned Nix fetchers:

```sh
bun scripts/generate-bun-nix.mjs
bun scripts/generate-bun-nix.mjs --check
```

PureScript registry sources are fetched using `spago.lock` integrity hashes.
When its bsdkrun SDK revision changes, update the archive hash in
`nix/purescript-deps.nix`. `nix flake update` updates the flake inputs.

Pushes build all three platforms. Version tags publish to FlakeHub and Flakestry
through FluentCI modules using GitHub OIDC. Both publishing workflows also accept
an existing version tag through their manual trigger.
