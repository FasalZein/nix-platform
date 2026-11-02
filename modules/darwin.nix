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
  ymcqDevEnvFile = "${secretsDir}/ymcq-dev.env";
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

  # Dev Postgres for bayland-portfolio-v1 on localhost:5433, native instead of
  # Docker/OrbStack (owner decision 2026-10-28: OrbStack's Docker hung after a
  # lid close). Label org.nixos.postgresql (nix-darwin services.postgresql, a
  # user agent: RunAtLoad, KeepAlive). Its first start runs initdb. The
  # data folder is outside every repo and keeps the major in its name, so a
  # new major gets a new folder (pg_upgrade or dump/restore). Settings replace
  # postgresql.conf on every start; ALTER SYSTEM still works through
  # postgresql.auto.conf. The module also adds psql, pg_dump and the other
  # client tools to the system profile.
  services.postgresql =
    let home = config.users.users.tothemoon.home;
    in {
      enable = true;
      # postgresql_17 through the overlay; expected-versions.nix pins 17.11.
      package = pkgs.postgresql;
      port = 5433;
      dataDir = "${home}/.local/state/nix-platform/postgresql-17";
      initdbArgs = [
        # Dev-only password 'postgres', the one every repo doc URL uses
        # (postgresql://postgres:postgres@localhost:5433/postgres). It is no
        # secret, so a store file is fine here.
        "--pwfile=${pkgs.writeText "postgres-dev-password" "postgres"}"
        "--auth-host=scram-sha-256"
        # The Docker cluster is UTF8 with glibc en_US.utf8 collation. macOS libc
        # en_US.UTF-8 collates near byte order, so ICU en-US is the closer match.
        "--encoding=UTF8"
        "--locale=en_US.UTF-8"
        "--locale-provider=icu"
        "--icu-locale=en-US"
      ];
      # Above the module's defaults (local peer, host md5). enableTCPIP stays
      # false: listen_addresses = localhost (127.0.0.1 and ::1) only.
      authentication = ''
        host all all 127.0.0.1/32 scram-sha-256
        host all all ::1/128      scram-sha-256
      '';
      # Timestamps in each line: the module default "[%p] " expects journald.
      logLinePrefix = "%m [%p] ";
      settings = {
        # Logging as docker-compose.yml in bayland-portfolio-v1 declares it:
        # files in <dataDir>/pg_log, daily rotation, statements over 1 s.
        logging_collector = true;
        log_directory = "pg_log";
        log_filename = "postgresql-%Y-%m-%d_%H%M%S.log";
        log_rotation_age = "1d";
        log_rotation_size = "100MB";
        log_truncate_on_rotation = true;
        log_min_duration_statement = 1000;
        # Values the Docker cluster has (read 2026-10-28). initdb writes the
        # locale and time zone lines into postgresql.conf, which the module
        # replaces, so they are set here.
        TimeZone = "Etc/UTC";
        log_timezone = "Etc/UTC";
        DateStyle = "ISO, MDY";
        lc_messages = "en_US.UTF-8";
        lc_monetary = "en_US.UTF-8";
        lc_numeric = "en_US.UTF-8";
        lc_time = "en_US.UTF-8";
        default_text_search_config = "pg_catalog.english";
        max_connections = 100;
        shared_buffers = "128MB";
        max_wal_size = "1GB";
        min_wal_size = "80MB";
      };
    };
  # Start-up errors before the logging collector runs (a busy port, a bad
  # data folder) go here; launchd retries every 10 s while KeepAlive holds.
  launchd.user.agents.postgresql.serviceConfig =
    let home = config.users.users.tothemoon.home;
    in {
      StandardOutPath = "${home}/Library/Logs/postgresql.log";
      StandardErrorPath = "${home}/Library/Logs/postgresql.log";
    };

  # SuperTokens core (auth service of bayland-platform) on 127.0.0.1:3567,
  # native instead of OrbStack (owner decision 2026-11-02). Label
  # org.nixos.supertokens. It stores its data in the `supertokens` database of
  # the Postgres above. The config lives in the store: the values match
  # bayland-platform docker/local/supertokens/config.yaml (the container's
  # effective config on 2026-11-02), with these changes: host 127.0.0.1 (the
  # container listened on 0.0.0.0 inside its own network), Postgres on
  # localhost:5433, and logs on stdout ("null"), so launchd writes them to the
  # log file. api_keys must equal SUPERTOKENS_API_KEY in bayland-platform
  # apps/api/start_server.py. The API key and the password are local dev
  # values from that repo, no secrets.
  # Start order: when Postgres is not ready, the core does not exit. It tries
  # again about every 10 s for up to 60 minutes and opens its port when the
  # database answers (tested 2026-11-02). If it gives up and exits, KeepAlive
  # starts it again after launchd's 10 s throttle.
  # Cutover prerequisite: bayland-platform scripts/local-infra-up.sh and
  # compose.local.yml start the OrbStack container bayland-platform-supertokens-local
  # on the same port 3567. Land the bayland-platform change that stops them
  # first, then stop the container, then switch. Keep the container only for
  # rollback.
  launchd.user.agents.supertokens.serviceConfig =
    let
      home = config.users.users.tothemoon.home;
      supertokens = pkgs.callPackage ../packages/supertokens.nix { };
      supertokensConfig = pkgs.writeText "supertokens-config.yaml" ''
        core_config_version: 0
        port: 3567
        host: "127.0.0.1"
        api_keys: "changeme-supertokens-api-key"
        disable_telemetry: true
        info_log_path: "null"
        error_log_path: "null"

        postgresql_config_version: 0
        postgresql_host: "localhost"
        postgresql_port: ${toString config.services.postgresql.port}
        postgresql_user: "postgres"
        postgresql_password: "postgres"
        postgresql_database_name: "supertokens"
      '';
    in {
      ProgramArguments = [ (lib.getExe supertokens) "${supertokensConfig}" ];
      RunAtLoad = true;
      KeepAlive = true;
      EnvironmentVariables = {
        HOME = home;
        # Writable install folder, Java temp files and JNA libraries; outside
        # every repo. launchd does not expand $HOME, so the path is absolute.
        SUPERTOKENS_STATE_DIR = "${home}/.local/state/nix-platform/supertokens";
        # mkdir and ln for the wrapper script.
        PATH = "/usr/bin:/bin";
      };
      StandardOutPath = "${home}/Library/Logs/supertokens.log";
      StandardErrorPath = "${home}/Library/Logs/supertokens.log";
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
        "${../secrets/ymcq-dev.env.tpl}" ymcqDevEnvFile
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

  # Key-only SSH login to this Mac (owner decision 2026-10-26). Remote Login listens on
  # every network, including public Wi-Fi; phone access (Moshi pairing keys, then mosh)
  # and agents use keys. sshd takes the first value per option, and 100-macos.conf
  # sets neither option, so these win.
  services.openssh.extraConfig = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
  '';

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
  # ~/.pi/agent/bin holds the agent tools every repo uses (heavy, wt, ralph-lane).
  # pi adds it only to its own env; a pi started in a direnv-loaded shell loses it
  # when env-wrap restores the pre-direnv PATH. Home Manager zsh integration is off,
  # so home.sessionPath would not reach shells; systemPath reaches every zsh.
  environment.systemPath = lib.mkAfter [
    "${config.users.users.tothemoon.home}/.pi/agent/bin"
    "${config.users.users.tothemoon.home}/.npm-global/bin"
    "${pkgs.coreutils}/bin"
  ];

  # Homebrew stays unmanaged for now; move casks into homebrew.casks later.
}
