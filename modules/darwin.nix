{ config, pkgs, lib, ... }:

let
  gib = n: n * 1024 * 1024 * 1024;

  # Stage 1: false. The first switch must use the default linux-builder,
  # because a changed builder config has to be built by a Linux builder
  # (nix-darwin modules/nix/linux-builder.nix). Set true after stage 1 works.
  builderTuned = true;
  linuxBuilderOnDemand = pkgs.callPackage ../packages/linux-builder-on-demand.nix { };

  # Rendered env files: outside every repo and the Nix store, in one folder.
  secretsDir = "${config.users.users.tothemoon.home}/.local/state/nix-platform/secrets";
  shellEnvFile = "${secretsDir}/shell.env";
  ninerouterEnvFile = "${secretsDir}/9router.env";
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
  # Store maintenance yields to interactive work: efficiency cores, low I/O priority.
  launchd.daemons.nix-gc.serviceConfig = { ProcessType = "Background"; LowPriorityIO = true; };
  launchd.daemons.nix-optimise.serviceConfig = { ProcessType = "Background"; LowPriorityIO = true; };

  # Hourly (owner decision 2026-10-23): stop per-worktree devenv services, such as a
  # worktree's test Postgres, that no process uses. They start again with the next
  # `devenv up`. Add a repo here when its devenv.nix declares services.
  launchd.user.agents.worktree-idle-sweep.serviceConfig =
    let
      home = config.users.users.tothemoon.home;
      repos = [ "${home}/Dev/Bayland/bayland-portfolio-v1" ];
    in {
      ProgramArguments = [ "/bin/bash" "-c"
        ''for r in ${lib.escapeShellArgs repos}; do ${home}/.pi/agent/bin/worktrees-idle "$r" --stop; done'' ];
      StartInterval = 3600;
      ProcessType = "Background";
      LowPriorityIO = true;
      # devenv from the user profile; lsof from /usr/sbin.
      EnvironmentVariables = {
        HOME = home;
        PATH = "/etc/profiles/per-user/tothemoon/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin";
      };
      StandardOutPath = "${home}/Library/Logs/worktree-idle-sweep.log";
      StandardErrorPath = "${home}/Library/Logs/worktree-idle-sweep.log";
    };

  # 9router AI gateway on 127.0.0.1:20128, native instead of Docker (owner
  # decision 2026-10-23). Label org.nixos.9router. Secrets stay out of the
  # store: env-file-exec exports the 4 secrets from ninerouterEnvFile (rendered
  # by secrets-render below) at start. Data stays in ~/.9router.
  launchd.user.agents."9router".serviceConfig =
    let
      home = config.users.users.tothemoon.home;
      ninerouter = pkgs.callPackage ../packages/9router.nix { };
      envFileExec = pkgs.callPackage ../packages/env-file-exec.nix { };
      baseUrl = "http://localhost:20128";
      # Both agents start at login. The first render retries for about 2
      # minutes when the network is down (4 attempts, 30 s apart), so 9router
      # waits up to 300 s, as secrets-refresh does. Then it exits with a log
      # line, and KeepAlive starts it again (and it waits again) after
      # launchd's 10 s throttle. A file from an earlier login is used at once.
      maxWaitSeconds = "300";
    in {
      ProgramArguments = [ (lib.getExe envFileExec) ninerouterEnvFile maxWaitSeconds (lib.getExe ninerouter) ];
      RunAtLoad = true;
      KeepAlive = true;
      EnvironmentVariables = {
        HOME = home;
        DATA_DIR = "${home}/.9router";
        PORT = "20128";
        HOSTNAME = "127.0.0.1";
        NODE_ENV = "production";
        BASE_URL = baseUrl;
        NEXT_PUBLIC_BASE_URL = baseUrl;
        PATH = "/usr/bin:/bin:/usr/sbin";
      };
      StandardOutPath = "${home}/Library/Logs/9router.log";
      StandardErrorPath = "${home}/Library/Logs/9router.log";
    };

  # Secrets (ADR 0001). Label org.nixos.secrets-render. At login the agent
  # renders each env template (1Password references only) through the saved
  # 2password service account into its rendered env file in secretsDir (mode
  # 0400, folder 0700, excluded from Time Machine). A failed render keeps the
  # last good file of that target. `secrets-refresh` restarts the agent.
  # Values never enter the store.
  launchd.user.agents.secrets-render.serviceConfig =
    let home = config.users.users.tothemoon.home;
    in {
      ProgramArguments = [
        (lib.getExe (pkgs.callPackage ../packages/secrets-render.nix { }))
        "${../secrets/shell.env.tpl}" shellEnvFile
        "${../secrets/9router.env.tpl}" ninerouterEnvFile
      ];
      RunAtLoad = true;
      EnvironmentVariables = {
        HOME = home;
        # Fresh values on every render, also from a long-running op daemon. One
        # uncached render costs 1 service-account read request per template
        # (measured 2026-10-24).
        OP_CACHE = "false";
        # op from the Homebrew 1password-cli cask; osascript (Keychain) and tmutil.
        PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin";
      };
      StandardOutPath = "${home}/Library/Logs/secrets-render.log";
      StandardErrorPath = "${home}/Library/Logs/secrets-render.log";
    };
  environment.systemPackages = [ (pkgs.callPackage ../packages/secrets-refresh.nix { }) ];
  # /etc/zshenv runs for every zsh, interactive or not; ~/.zshenv and ~/.zshrc stay untouched.
  programs.zsh.shellInit = builtins.replaceStrings [ "@shellEnvFile@" ] [ shellEnvFile ]
    (builtins.readFile ../secrets/load-shell-secrets.zsh);

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

  # On-demand builder (owner decision 2026-10-24): the VM no longer runs while
  # idle. The first ssh to linux-builder (nix-daemon dispatching an
  # aarch64-linux build) starts it through the ProxyCommand below and waits
  # for the guest sshd; a timer stops it after 30 idle minutes. Only host-side
  # launchd and ssh settings change, so the VM package needs no rebuild.
  launchd.daemons.linux-builder.serviceConfig = {
    KeepAlive = lib.mkForce false;
    RunAtLoad = lib.mkForce false;
  };
  # ssh takes the first value per option and reads ssh_config.d in lexical
  # order, so this file adds ProxyCommand ahead of nix-darwin's 100-linux-builder.conf.
  environment.etc."ssh/ssh_config.d/099-linux-builder-on-demand.conf".text = ''
    Host linux-builder
      ProxyCommand ${lib.getExe linuxBuilderOnDemand} wake 127.0.0.1 %p
  '';
  launchd.daemons.linux-builder-idle-stop.serviceConfig = {
    ProgramArguments = [ (lib.getExe linuxBuilderOnDemand) "reap" ];
    StartInterval = 300;
    ProcessType = "Background";
    StandardOutPath = "/var/log/linux-builder-idle-stop.log";
    StandardErrorPath = "/var/log/linux-builder-idle-stop.log";
  };

  # direnv hook in /etc/zshrc, so ~/.zshrc stays untouched.
  programs.zsh.interactiveShellInit = ''
    eval "$(${pkgs.direnv}/bin/direnv hook zsh)"
  '';

  # Nix profile dirs first in login zsh. ~/.zprofile and ~/.zshrc prepend
  # Homebrew, ~/.bun/bin and ~/.local/bin after /etc/zshenv sets PATH; zsh
  # reads /etc/zlogin after ~/.zshrc, so ~/.zshrc stays untouched. nix-darwin
  # does not generate /etc/zlogin (modules/programs/zsh), so we own it here.
  # Only login shells read it (Terminal, herdr panes); a nested interactive
  # zsh re-runs ~/.zshrc and puts those dirs in front again.
  environment.etc."zlogin".text = ''
    # /etc/zlogin: generated by nix-platform (modules/darwin.nix).
    () {
      local -a nix_dirs
      nix_dirs=(${lib.concatMapStringsSep " " (p: ''"${p}/bin"'') config.environment.profiles})
      # Keep only the Nix dirs PATH already has, in profile order.
      nix_dirs=(''${nix_dirs:*path})
      path=($nix_dirs ''${path:|nix_dirs})
    }
  '';

  # Default caps for every shell, including agent shells. `heavy` lowers them
  # further per slot. Without a cap each vitest run starts cores-1 workers.
  environment.variables = {
    VITEST_MAX_WORKERS = "4";
    CARGO_BUILD_JOBS = "4";
    # The Nix npm's default global prefix is inside the read-only store, so
    # `npm i -g` needs a user prefix. Homebrew globals stay where they are.
    NPM_CONFIG_PREFIX = "${config.users.users.tothemoon.home}/.npm-global";
  };

  # GNU coreutils after /usr/bin and /bin (mkAfter = order 1500; the system
  # dirs use 1200). Missing commands (timeout, nproc) resolve to GNU; stat,
  # date and mktemp keep their BSD flags. Not in a profile, so it stays last.
  # Globals from `npm i -g` (NPM_CONFIG_PREFIX above) come just before it.
  environment.systemPath = lib.mkAfter [
    "${config.users.users.tothemoon.home}/.npm-global/bin"
    "${pkgs.coreutils}/bin"
  ];

  # Homebrew stays unmanaged for now; move casks into homebrew.casks later.
}
