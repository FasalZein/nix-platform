# nix-platform

- Apply changes with `sudo darwin-rebuild switch --flake .#MacBook-Pro-2`; first-install steps are in README.md.
- When a pin changes (overlays/default.nix or flake.lock), update expected-versions.nix in the same commit and run `nix flake check`. It builds the whole system too (check `darwin-system`).
- The linux-builder runs tuned (`builderTuned = true` in modules/darwin.nix). A change to its config is built by the running Linux builder.
