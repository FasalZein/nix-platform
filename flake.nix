{
  description = "nix-platform: nix-darwin + home-manager for MacBook-Pro-2, shared overlay and devenv module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }:
  let
    # Checks and packages run on this Mac only; the overlay itself works on every system.
    system = "aarch64-darwin";
    pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
    expected = import ./expected-versions.nix;
  in {
    overlays.default = import ./overlays/default.nix;

    devenvModules.default = ./devenv/devenv.nix;

    packages.${system} = {
      inherit (pkgs) bun nodejs uv postgresql;
      # Run by the launchd agent in modules/darwin.nix.
      "9router" = pkgs.callPackage ./packages/9router.nix { };
      # Run by the linux-builder ProxyCommand and idle timer in modules/darwin.nix.
      linux-builder-on-demand = pkgs.callPackage ./packages/linux-builder-on-demand.nix { };
      # Run by the secrets-render login agent in modules/darwin.nix.
      "2password" = pkgs.callPackage ./packages/2password { };
      secrets-render = pkgs.callPackage ./packages/secrets-render.nix { };
      secrets-refresh = pkgs.callPackage ./packages/secrets-refresh.nix { };
    };

    # Fails when a pinned tool reports a version other than expected-versions.nix.
    checks.${system} = {
      pin-drift = pkgs.runCommand "pin-drift" { } ''
        fail=0
        check() {
          if [ "$2" = "$3" ]; then echo "ok   $1 $2"
          else echo "DRIFT $1: got '$2', expected '$3' (expected-versions.nix)"; fail=1; fi
        }
        check bun "$(${pkgs.bun}/bin/bun --version)" "${expected.bun}"
        check nodejs "$(${pkgs.nodejs}/bin/node --version)" "v${expected.nodejs}"
        check uv "$(${pkgs.uv}/bin/uv --version | cut -d' ' -f2)" "${expected.uv}"
        check postgresql "$(${pkgs.postgresql}/bin/postgres --version | cut -d' ' -f3)" "${expected.postgresql}"
        [ "$fail" = 0 ] && touch $out
      '';
      # Builds the package; the tarball hash pins the app version.
      "9router" = self.packages.${system}."9router";
      # writeShellApplication runs shellcheck on the script.
      linux-builder-on-demand = self.packages.${system}.linux-builder-on-demand;
      # The npm tarball hash and package-lock.json pin 2password and its dependencies.
      "2password" = self.packages.${system}."2password";
      secrets-render = self.packages.${system}.secrets-render;
      secrets-refresh = self.packages.${system}.secrets-refresh;
      # Values rendered by 2password's own env renderer survive the zsh loader
      # byte for byte ($, backticks, quotes, backslashes, newlines, key pools).
      shell-secrets-loader = pkgs.runCommand "shell-secrets-loader" {
        nativeBuildInputs = [ pkgs.bun pkgs.zsh ];
        loader = builtins.replaceStrings [ "@shellEnvFile@" ] [ "$RENDERED" ]
          (builtins.readFile ./secrets/load-shell-secrets.zsh);
      } ''
        export HOME=$TMPDIR
        cp -R ${self.packages.${system}."2password"}/lib/node_modules/2password $TMPDIR/tp
        chmod -R u+w $TMPDIR/tp
        cp ${./secrets/loader-test.ts} $TMPDIR/tp/loader-test.ts
        export RENDERED=$TMPDIR/shell.env
        bun $TMPDIR/tp/loader-test.ts $RENDERED $TMPDIR/expected
        printf '%s\n' "$loader" > $TMPDIR/loader.zsh
        zsh -f -c '
          source $TMPDIR/loader.zsh
          while read -r name hex; do
            got=$(printf "%s" "''${(P)name}" | od -An -tx1 | tr -d " \n")
            if [[ $got == $hex ]]; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi
          done < $TMPDIR/expected
          exit ''${fail:-0}
        '
        # A name that is already set keeps its value.
        PLAIN=preset zsh -f -c 'source $TMPDIR/loader.zsh && [[ $PLAIN == preset && -n $POOL ]]'
        # With xtrace on, the trace holds no value, and the values still load.
        zsh -f -c 'setopt xtrace; source $TMPDIR/loader.zsh; unsetopt xtrace; [[ $PLAIN == abc123XYZ ]]' 2> $TMPDIR/trace
        if grep -qF abc123XYZ $TMPDIR/trace; then echo "FAIL xtrace leaks a value"; exit 1; fi
        # Without a rendered file the loader exports nothing and succeeds.
        RENDERED=$TMPDIR/missing zsh -f -c 'source $TMPDIR/loader.zsh && [[ -z ''${PLAIN-} ]]'
        touch $out
      '';
    };

    darwinConfigurations."MacBook-Pro-2" = nix-darwin.lib.darwinSystem {
      modules = [
        ./modules/darwin.nix
        {
          system.configurationRevision = self.rev or self.dirtyRev or null;
          # System and home-manager packages (useGlobalPkgs) get the pinned bun, node and uv.
          nixpkgs.overlays = [ self.overlays.default ];
        }
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          # Existing dotfiles are moved aside, never overwritten.
          home-manager.backupFileExtension = "before-hm";
          home-manager.users.tothemoon = import ./modules/home.nix;
        }
      ];
    };
  };
}
