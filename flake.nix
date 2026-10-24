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
      # Run by the 9router launchd agent in modules/darwin.nix.
      env-file-exec = pkgs.callPackage ./packages/env-file-exec.nix { };
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
      env-file-exec = self.packages.${system}.env-file-exec;
      # Several templates in one run, against fake 2password and tmutil: each
      # target renders atomically with mode 0400, a failing template keeps its
      # last good file while the others render, and the log holds no value.
      secrets-render-multi = pkgs.runCommand "secrets-render-multi" {
        nativeBuildInputs = [ pkgs.bash pkgs.gnugrep pkgs.gnused pkgs.coreutils ];
        script = ./packages/secrets-render.sh;
      } ''
        mkdir -p $TMPDIR/bin
        # Fake 2password: fails for a template that holds FAIL, else writes
        # NAME="fake-value-NAME" for each reference, copies other lines as they
        # are (as 2password does), and counts its calls.
        cat > $TMPDIR/bin/2password <<'EOF'
        #!/usr/bin/env bash
        echo "$3" >> "$TMPDIR/calls"
        if grep -q FAIL "$3"; then echo "fake failure" >&2; exit 1; fi
        sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=op:.*/\1="fake-value-\1"/' "$3" > "$5"
        EOF
        printf '#!/usr/bin/env bash\n[ "$1" = isexcluded ] && echo "[Excluded] $2"\nexit 0\n' > $TMPDIR/bin/tmutil
        # The script calls BSD stat (/usr/bin on the Mac) for the file time.
        printf '#!/usr/bin/env bash\necho 2026-10-24T00:00:00+0000\n' > $TMPDIR/bin/stat
        chmod +x $TMPDIR/bin/*
        patchShebangs $TMPDIR/bin
        export PATH=$TMPDIR/bin:$PATH RENDER_RETRY_SECONDS=0 RENDER_ATTEMPTS=2
        render() { bash -euo pipefail $script "$@"; }
        gnustat() { ${pkgs.coreutils}/bin/stat "$@"; }
        printf 'A=op://v/i/A\nB=op://v/i/B\n' > $TMPDIR/one.tpl
        # A plain (non-reference) line is copied and is not counted as a variable.
        printf '# comment\nPLAIN=dev\nC=op://v/j/C\n' > $TMPDIR/two.tpl
        s=$TMPDIR/state/secrets

        render $TMPDIR/one.tpl $s/one.env $TMPDIR/two.tpl $s/two.env > $TMPDIR/log
        grep -qx 'A="fake-value-A"' $s/one.env && grep -qx 'C="fake-value-C"' $s/two.env
        grep -qx 'PLAIN=dev' $s/two.env
        grep -q 'rendered 1 of 1 variables into .*/two.env' $TMPDIR/log
        [ "$(gnustat -c %a $s/one.env) $(gnustat -c %a $s/two.env) $(gnustat -c %a $s)" = "400 400 700" ]
        [ "$(wc -l < $TMPDIR/calls)" = 2 ]
        grep -q 'rendered 2 of 2 variables into .*/one.env' $TMPDIR/log
        [ "$(tail -n 1 $TMPDIR/log | cut -d' ' -f2-)" = "secrets-render: done: 2 of 2 files rendered" ]
        [ "$(ls -A $s)" = "$(printf 'one.env\ntwo.env')" ]  # no scratch folder left

        # The second template now fails: its last good file stays, the first renders.
        cp $s/two.env $TMPDIR/two.good
        echo 'FAIL=op://v/j/FAIL' >> $TMPDIR/two.tpl
        rm $TMPDIR/calls
        if render $TMPDIR/one.tpl $s/one.env $TMPDIR/two.tpl $s/two.env > $TMPDIR/log; then
          echo "FAIL a failed template must give a non-zero exit"; exit 1
        fi
        cmp $s/two.env $TMPDIR/two.good
        [ "$(wc -l < $TMPDIR/calls)" = 3 ]  # one.tpl once, two.tpl on both attempts
        grep -q 'render failed for .*/two.env; last good file kept (1 variables, 2026-10-24T00:00:00+0000)' $TMPDIR/log
        [ "$(tail -n 1 $TMPDIR/log | cut -d' ' -f2-)" = "secrets-render: done: 1 of 2 files rendered" ]
        if grep -q fake-value $TMPDIR/log; then echo "FAIL the log holds a value"; exit 1; fi

        # A failed install (mv) is a failed render: non-zero exit, last good file kept.
        cp $s/one.env $TMPDIR/one.good
        printf '#!/bin/sh\nexit 1\n' > $TMPDIR/bin/mv; chmod +x $TMPDIR/bin/mv; patchShebangs $TMPDIR/bin/mv
        if render $TMPDIR/one.tpl $s/one.env > $TMPDIR/log; then
          echo "FAIL a failed install must give a non-zero exit"; exit 1
        fi
        cmp $s/one.env $TMPDIR/one.good
        grep -q 'failed for .*/one.env: could not install the rendered file' $TMPDIR/log
        rm $TMPDIR/bin/mv

        # An odd argument count is a usage error.
        if render $TMPDIR/one.tpl 2> $TMPDIR/err; then exit 1; fi
        grep -q usage $TMPDIR/err
        touch $out
      '';
      # 9router start: env-file-exec waits for a late rendered env file, loads
      # it and runs the command; without the file it exits after the bound.
      env-file-exec-wait = pkgs.runCommand "env-file-exec-wait" { } ''
        run=${pkgs.lib.getExe self.packages.${system}.env-file-exec}
        f=$TMPDIR/9router.env
        ( sleep 2; printf 'SECRET="a$HOME\\"b"\n' > $f.tmp; mv $f.tmp $f ) &
        $run $f 30 /bin/sh -c 'printf %s "$SECRET" > '$TMPDIR'/got' > $TMPDIR/log
        wait
        [ "$(cat $TMPDIR/got)" = 'a$HOME"b' ]
        grep -q "waiting up to 30s for $f" $TMPDIR/log
        grep -q "loading $f (waited [1-9]s)" $TMPDIR/log

        # Missing file: exit 1 after the bound, with a clear log line, no start.
        if $run $TMPDIR/missing 2 /bin/sh -c 'touch '$TMPDIR'/started' > $TMPDIR/log; then exit 1; fi
        [ ! -e $TMPDIR/started ]
        grep -q "error: $TMPDIR/missing missing after 2s; not starting /bin/sh" $TMPDIR/log
        touch $out
      '';
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
