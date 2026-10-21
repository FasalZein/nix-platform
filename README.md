# nix-platform

Machine config for MacBook-Pro-2 (nix-darwin + home-manager, Lix). Later: shared overlays and devenv modules for every repository.

Plan and decisions: `~/.pi/artifacts/nix-plan/nix-migration-plan-20261021.md`.

## First install (run by hand; needs sudo)

1. Install Lix:
   ```
   curl -sSf -L https://install.lix.systems/lix | sh -s -- install
   ```
   Open a new terminal. Check: `nix --version` prints Lix.
2. nix-darwin refuses to overwrite files in /etc it did not create. Move them aside:
   ```
   sudo mv /etc/nix/nix.conf /etc/nix/nix.conf.before-nix-darwin
   sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
   sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
   ```
3. First switch (stage 1, default Linux builder):
   ```
   cd ~/Dev/nix-platform
   sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake .#MacBook-Pro-2
   ```
   Open a new terminal. Check: `darwin-rebuild --help`, `devenv version`, `direnv version`.
4. Check the Linux builder: `nix build --system aarch64-linux nixpkgs#hello --print-out-paths`.
5. Stage 2: set `builderTuned = true` in `modules/darwin.nix` (6 cores, 12 GiB RAM, 80 GiB disk), then
   `sudo darwin-rebuild switch --flake .#MacBook-Pro-2`.

## Daily use

- Apply a change: `sudo darwin-rebuild switch --flake ~/Dev/nix-platform#MacBook-Pro-2`
- Roll back: `sudo darwin-rebuild --rollback`
- Update inputs: `nix flake update`, then switch. Commit `flake.lock`.

## Not verified yet

Nix is not installed, so this flake has not been evaluated. Expect small fixes on the first switch (option or package names).
