# nix-platform

Machine config for MacBook-Pro-2 (nix-darwin + home-manager, Lix), plus a shared overlay and devenv module for every repository.

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

The Linux builder VM runs on demand. The first Linux build starts it and waits for its boot. A timer stops it after 30 idle minutes and logs to `/var/log/linux-builder-idle-stop.log`. To start it by hand: `sudo launchctl kickstart system/org.nixos.linux-builder`.

## Shared overlay and devenv module

- `overlays.default` (overlays/default.nix) pins bun, node, uv, and postgres. Rust stays per repo in `rust-toolchain.toml`; pnpm stays in `package.json` `packageManager`.
- `devenvModules.default` (devenv/devenv.nix) holds settings every repo shares. Repos enable their own languages.
- `nix flake check` runs `checks.aarch64-darwin.pin-drift`. It fails when a pinned tool reports a version other than `expected-versions.nix`.

Repo template (`devenv.yaml`). `git+https` uses the git credential helper; a `github:` URL needs a Nix access token for this private repo.

```yaml
inputs:
  nix-platform:
    url: git+https://github.com/FasalZein/nix-platform
    overlays:
      - default
  nixpkgs:
    follows: nix-platform/nixpkgs
imports:
  - nix-platform/devenv
```

Add `.envrc` with `eval "$(devenv direnvrc)"` and `use devenv`, then run `direnv allow`. After a push here, run `devenv update` in each repo to pick up the change.

## Daily use

- Apply a change: `sudo darwin-rebuild switch --flake ~/Dev/nix-platform#MacBook-Pro-2`
- Roll back: `sudo darwin-rebuild --rollback`
- Update inputs: `nix flake update`, then switch. Commit `flake.lock`.

## Not verified yet

State on 2026-10-24. The first install and stage 2 are done: Lix 2.95.4 runs, and the active system is the `main` configuration. `nix flake check` passes (10 checks). The shell, 9router and ymcq dev env files render at login.

These parts are not done or not verified yet:

- Phase-2 repos do not use the devenv module yet (#9 to #15). Only Bayland portfolio and trading-platform import it today.
- The overlay has Node 24 only. Node 22 and its security pin come with #8. The x86_64-linux build of that pin is proven only by the first CI run that uses it.
- No CI job runs inside devenv yet (#23 to #25).
- Homebrew is not declared in nix-darwin yet (#16 to #22).
- Bayland dev and staging do not read rendered env files yet (#5).
- The repository is still private, so the credential-free `github:FasalZein/nix-platform` fetch is not verified (#7).
