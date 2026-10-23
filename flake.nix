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
