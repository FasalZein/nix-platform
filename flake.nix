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
    # nodejs_22 of the locked nixpkgs, without the overlay's security pin.
    nixpkgsNode22 = nixpkgs.legacyPackages.${system}.nodejs_22.version;
  in {
    overlays.default = import ./overlays/default.nix;

    devenvModules.default = ./devenv/devenv.nix;

    packages.${system} = {
      inherit (pkgs) bun nodejs nodejs_22 nodejs_24 uv postgresql;
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
      # Run by the supertokens-log-cap launchd agent in modules/darwin.nix.
      log-size-cap = pkgs.callPackage ./packages/log-size-cap.nix { };
      # Run by the supertokens launchd agent in modules/darwin.nix.
      supertokens = pkgs.callPackage ./packages/supertokens.nix { };
      # Run by the memory-sampler launchd agent in modules/darwin.nix.
      memory-sampler = pkgs.callPackage ./packages/memory-sampler.nix { };
      # Installed by environment.systemPackages in modules/darwin.nix, for `wt new`.
      wt-clonefile = pkgs.callPackage ./packages/wt-clonefile.nix { };
      # Run by the worktrees-sweep launchd agent in modules/worktrees-sweep.nix.
      worktrees-sweep = pkgs.callPackage ./packages/worktrees-sweep.nix { };
      # TLC engine for pstack statechart; installed and set as JAVA in modules/darwin.nix.
      tla-ts = pkgs.callPackage ./packages/tla-ts.nix { };
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
        check nodejs "$(${pkgs.nodejs}/bin/node --version)" "v${expected.nodejs_24}"
        check nodejs_22 "$(${pkgs.nodejs_22}/bin/node --version)" "v${expected.nodejs_22}"
        check nodejs_24 "$(${pkgs.nodejs_24}/bin/node --version)" "v${expected.nodejs_24}"
        # The nodejs_22 override must not outlive its reason.
        ${if pkgs.lib.versionAtLeast nixpkgsNode22 expected.nodejs_22 then ''
          echo "STALE nodejs_22 override: nixpkgs ships ${nixpkgsNode22} >= pin ${expected.nodejs_22}; remove the nodejs_22 line in overlays/default.nix"; fail=1
        '' else ''
          echo "ok   nodejs_22 override still needed (nixpkgs ${nixpkgsNode22} < ${expected.nodejs_22})"
        ''}
        check uv "$(${pkgs.uv}/bin/uv --version | cut -d' ' -f2)" "${expected.uv}"
        check postgresql "$(${pkgs.postgresql}/bin/postgres --version | cut -d' ' -f3)" "${expected.postgresql}"
        [ "$fail" = 0 ] && touch $out
      '';
      # Builds the package; the tarball hash pins the app version.
      "9router" = self.packages.${system}."9router";
      # writeShellApplication runs shellcheck on the script.
      linux-builder-on-demand = self.packages.${system}.linux-builder-on-demand;
      # The overlay replaces nodejs_22 for every nixpkgs package. zx is a small
      # buildNpmPackage consumer of nodejs_22: it must build with the release-binary
      # Node (npmConfigHook reads nodejs.python and srcOnly nodejs) and run on it.
      nodejs_22-npm-consumer = pkgs.runCommand "nodejs_22-npm-consumer" { } ''
        ${pkgs.lib.getExe pkgs.zx} --version
        grep -rqF ${pkgs.nodejs_22}/bin/node ${pkgs.zx}
        touch $out
      '';
      # The npm tarball hash and package-lock.json pin 2password and its dependencies.
      "2password" = self.packages.${system}."2password";
      secrets-render = self.packages.${system}.secrets-render;
      secrets-refresh = self.packages.${system}.secrets-refresh;
      env-file-exec = self.packages.${system}.env-file-exec;
      # writeShellApplication runs shellcheck on the script.
      worktrees-sweep = self.packages.${system}.worktrees-sweep;
      # tla-ts-174 reproduces TLC 1.7.4, which pstack's corpus matches; plain
      # tla-ts without a v1.7.4 jar reproduces TLC nightly. A parameterised
      # action tells them apart: 1.7.4 prints `<Set line`, nightly `<Set(1) line`.
      # Both exit 12 (TLC: invariant violated). The jar path need not exist.
      tla-ts = pkgs.runCommand "tla-ts-check" { } ''
        tlats=${self.packages.${system}.tla-ts}/bin
        printf '%s\n' '---- MODULE Pick ----' 'VARIABLE x' 'Init == x = 0' \
          "Set(v) == x = 0 /\\ x' = v" 'Next == \E v \in {1, 2} : Set(v)' \
          'Zero == x = 0' '====' > Pick.tla
        printf '%s\n' 'INIT Init' 'NEXT Next' 'INVARIANT Zero' > Pick.cfg
        run() { rc=0; "$tlats/$1" -cp /nonexistent/tla2tools.jar tlc2.TLC -config Pick.cfg Pick.tla > "$1.out" 2>&1 || rc=$?; [ "$rc" = 12 ]; }
        run tla-ts-174
        grep -q 'Invariant Zero is violated' tla-ts-174.out
        grep -q '^State 2: <Set line' tla-ts-174.out
        run tla-ts
        grep -q '^State 2: <Set(1) line' tla-ts.out
        touch $out
      '';
      # Builds the package; the image digest and hash pin the core version, and
      # the build fails when version.yaml names another core version.
      supertokens = self.packages.${system}.supertokens;
      # A file over the limit is emptied in place (same inode) and gets one
      # marker line; a writer that holds an O_APPEND handle (as launchd's
      # StandardOutPath) keeps writing at the new end; a file at or under the
      # limit and a missing file stay untouched.
      # Against fake memory_pressure, sysctl and ps: one line with free %, swap
      # used and the 10 largest processes by RSS (base name, pid, MiB), in RSS
      # order; a log at the limit stays, a log over it moves to <log>.1 and a
      # new log starts; wrong arguments give usage and exit 64.
      memory-sampler = pkgs.runCommand "memory-sampler" { } ''
        run=${pkgs.lib.getExe self.packages.${system}.memory-sampler}
        mkdir $TMPDIR/bin
        printf '%s\n' '#!/bin/sh' \
          'echo "The system has 51539607552 (3145728 pages with a page size of 16384)."' \
          'echo "System-wide memory free percentage: 42%"' > $TMPDIR/bin/memory_pressure
        printf '%s\n' '#!/bin/sh' \
          'echo "total = 4096.00M  used = 2615.06M  free = 1480.94M  (encrypted)"' > $TMPDIR/bin/sysctl
        {
          echo '#!/bin/sh'
          echo 'cat <<EOF'
          echo '  2048   7 /usr/libexec/small'
          for i in 1 2 3 4 5 6 7 8 9 10; do echo "$((i * 10240)) $((100 + i)) /Applications/A B.app/p$i"; done
          echo 'EOF'
        } > $TMPDIR/bin/ps
        chmod +x $TMPDIR/bin/*
        export PATH=$TMPDIR/bin:$PATH
        log=$TMPDIR/m.log
        $run $log 1000000
        [ "$(wc -l < $log)" = 1 ]
        line=$(cat $log)
        grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} ' $log
        [ "''${line#* }" = 'free=42% swap_used=2615.06M top_rss=p10[110]=100M,p9[109]=90M,p8[108]=80M,p7[107]=70M,p6[106]=60M,p5[105]=50M,p4[104]=40M,p3[103]=30M,p2[102]=20M,p1[101]=10M' ]
        size=$(stat -c %s $log)
        $run $log $size
        [ "$(wc -l < $log)" = 2 ] && [ ! -e $log.1 ]
        $run $log $((size * 2 - 1))
        [ "$(wc -l < $log)" = 1 ] && [ "$(wc -l < $log.1)" = 2 ]
        if $run $log 2> $TMPDIR/err; then exit 1; else [ $? = 64 ]; fi
        grep -q usage $TMPDIR/err
        touch $out
      '';
      # A directory with a file and a relative symlink clones to an equal tree
      # (no output, exit 0) whose files are separate copies; an existing DST,
      # a missing SRC and a symlink SRC (also with trailing slashes) each fail
      # with one stderr line and leave no DST; wrong arguments give usage and
      # exit 64. EXDEV and
      # ENOTSUP need a second volume (hdiutil), so they are checked by hand.
      wt-clonefile = pkgs.runCommand "wt-clonefile" { } ''
        run=${pkgs.lib.getExe self.packages.${system}.wt-clonefile}
        cd $TMPDIR
        fails() { if "$run" "$@" 2> err; then echo "FAIL $* succeeded"; exit 1; fi; [ "$(wc -l < err)" = 1 ]; }
        mkdir -p src/sub && echo x > src/sub/f && ln -s sub/f src/link
        "$run" src dst > out 2>&1
        [ ! -s out ]
        diff -r --no-dereference src dst
        [ "$(readlink dst/link)" = sub/f ]
        echo y >> dst/sub/f
        [ "$(cat src/sub/f)" = x ]
        fails src dst
        grep -qF 'wt-clonefile: clonefile src -> dst: File exists' err
        fails none x
        grep -q 'No such file or directory' err && [ ! -e x ]
        ln -s src srclink
        # A trailing slash must not make lstat follow the top-level symlink.
        for s in srclink srclink/ srclink//; do
          fails "$s" y
          grep -q 'Not a directory' err && [ ! -e y ]
        done
        for args in "" "a b c"; do
          # shellcheck disable=SC2086
          if "$run" $args 2> err; then exit 1; else [ $? = 64 ]; fi
          grep -qx 'usage: wt-clonefile SRC DST' err
        done
        touch $out
      '';
      log-size-cap = pkgs.runCommand "log-size-cap" { } ''
        run=${pkgs.lib.getExe self.packages.${system}.log-size-cap}
        size() { stat -c %s "$1"; }
        head -c 2000 /dev/zero > $TMPDIR/big.log
        head -c 1000 /dev/zero > $TMPDIR/limit.log
        head -c 10 /dev/zero > $TMPDIR/small.log
        inode=$(stat -c %i $TMPDIR/big.log)
        exec 3>> $TMPDIR/big.log
        $run 1000 $TMPDIR/big.log $TMPDIR/limit.log $TMPDIR/small.log $TMPDIR/missing.log
        [ "$(stat -c %i $TMPDIR/big.log)" = "$inode" ]
        [ "$(wc -l < $TMPDIR/big.log)" = 1 ]
        grep -q "log-size-cap: truncated $TMPDIR/big.log at 2000 bytes (limit 1000)" $TMPDIR/big.log
        marker=$(size $TMPDIR/big.log)
        echo after >&3
        exec 3>&-
        [ "$(size $TMPDIR/big.log)" = $((marker + 6)) ]
        [ "$(tail -n 1 $TMPDIR/big.log)" = after ]
        [ "$(size $TMPDIR/limit.log)" = 1000 ] && [ "$(size $TMPDIR/small.log)" = 10 ]
        [ ! -e $TMPDIR/missing.log ]
        if $run 1000 2> $TMPDIR/err; then exit 1; fi
        grep -q usage $TMPDIR/err
        touch $out
      '';
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
