{ pkgs, lib, ... }:

let
  gib = n: n * 1024 * 1024 * 1024;

  # Stage 1: false. The first switch must use the default linux-builder,
  # because a changed builder config has to be built by a Linux builder
  # (nix-darwin modules/nix/linux-builder.nix). Set true after stage 1 works.
  builderTuned = false;
in
{
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 6;
  system.primaryUser = "tothemoon";
  # home-manager reads the home directory from here.
  users.users.tothemoon.home = "/Users/tothemoon";

  # Lix, installed by the Lix installer and managed here (nix.enable = true is
  # required by nix.linux-builder).
  nix.package = pkgs.lix;

  nix.settings = {
    experimental-features = "nix-command flakes";
    trusted-users = [ "@admin" "tothemoon" ];
    # Many agents share 14 cores: Nix builds take at most 2 jobs x 6 cores.
    max-jobs = 2;
    cores = 6;
    # Garbage-collect during builds when free space drops under 20 GiB,
    # until 60 GiB are free.
    min-free = gib 20;
    max-free = gib 60;
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };

  nix.gc = {
    automatic = true;
    interval = [{ Weekday = 0; Hour = 3; Minute = 0; }];
    options = "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = true;
    interval = [{ Weekday = 0; Hour = 4; Minute = 0; }];
  };

  # aarch64-linux builds for local CI and NixOS VM tests.
  nix.linux-builder = {
    enable = true;
    ephemeral = true;
    maxJobs = 2;
  } // lib.optionalAttrs builderTuned {
    config = {
      virtualisation.cores = 6;
      virtualisation.darwin-builder.memorySize = 12 * 1024;  # MiB
      virtualisation.darwin-builder.diskSize = 80 * 1024;    # MiB
    };
  };

  # direnv hook in /etc/zshrc, so ~/.zshrc stays untouched.
  programs.zsh.interactiveShellInit = ''
    eval "$(${pkgs.direnv}/bin/direnv hook zsh)"
  '';

  # Default caps for every shell, including agent shells. `heavy` lowers them
  # further per slot. Without a cap each vitest run starts cores-1 workers.
  environment.variables = {
    VITEST_MAX_WORKERS = "4";
    CARGO_BUILD_JOBS = "4";
  };

  # Homebrew stays unmanaged for now; move casks into homebrew.casks later.
}
