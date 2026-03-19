# overstory-cli

Nix packaging for `@os-eco/overstory-cli` using Bun and `bun2nix`.

## Package

- Upstream package: `@os-eco/overstory-cli`
- Pinned version: `0.9.1`
- Description: multi-agent orchestration for AI coding agents with tmux worktrees, SQLite mail, and pluggable runtimes
- Installed binary: `overstory`
- Upstream executable invoked by Bun: `overstory`

## What This Repo Does

- Uses `bun.lock` and generated `bun.nix` as the dependency lock surface for Nix
- Builds the upstream package as an internal Bun application with `bun2nix`
- Exposes only the canonical binary name `overstory`
- Provides a manifest sync script for updating the pinned npm metadata

## Files

- `flake.nix`: flake entrypoint
- `nix/package.nix`: Nix derivation
- `nix/package-manifest.json`: pinned package metadata and exposed binary name
- `scripts/sync-from-npm.ts`: updates pinned npm metadata without changing the canonical output binary

## Notes

- The default `out` output installs the longform binary name `overstory`.
- The shortform name `ov` is available as a separate Nix output, not in the default `out` output.
- The packaged output removes the bundled Pi guard extension files and the `pi.ts` integration that writes them.
- Pi guard handling is intended to live in `RogerNavelsaker/os-eco-pi-extension`, not in this package.
