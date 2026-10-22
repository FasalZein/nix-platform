# nix-platform

- Apply changes with `sudo darwin-rebuild switch --flake .#MacBook-Pro-2`; first-install steps are in README.md.
- When a pin changes (overlays/default.nix or flake.lock), update expected-versions.nix in the same commit and run `heavy -- nix flake check`.
- Keep the linux-builder at defaults until a stage-1 switch has worked; see `builderTuned` in modules/darwin.nix.
