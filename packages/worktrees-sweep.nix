# Nightly sweep of landed linked worktrees in every repo (issue #31, spec
# worktree-home D5-D7). `wt new` sweeps only the repo it runs in, so linked
# worktrees built up in the other repos. This script lists every repo that has
# linked worktrees and runs `worktrees-landed <repo> --remove` once for each.
# The removal rules belong to worktrees-landed (pi-agent-config): it removes
# landed, clean, idle worktrees only and keeps dirty, busy, fresh, pushed and
# local ones. This script adds no removal rule of its own.
#
# Repos come from two sources, de-duplicated by main checkout:
# - DEV_ROOT (default $HOME/Dev): repos with a .git directory (a .git file is a
#   linked worktree or a submodule) whose `git worktree list` has more than
#   one entry. Existing worktrees under ~/Dev stay where they are (D6).
# - WT_ROOT (unset: skipped): the main checkout of each linked worktree there.
#
# One repo's failure is logged and the loop continues; the exit code is 0.
# WORKTREES_SWEEP_LOG names the log file that launchd writes (StandardOutPath);
# when set, the script caps it at the start of the run. Usage: worktrees-sweep
{ writeShellApplication, callPackage, coreutils, findutils, gnugrep, git }:

writeShellApplication {
  name = "worktrees-sweep";
  runtimeInputs = [ coreutils findutils gnugrep git (callPackage ./log-size-cap.nix { }) ];
  text = ''
    dev_root=''${DEV_ROOT:-$HOME/Dev}
    wt_root=''${WT_ROOT:-}
    # Absolute path, as the worktree-idle-sweep agent runs worktrees-idle.
    landed=$HOME/.pi/agent/bin/worktrees-landed
    # A run writes about 3 lines per repo (about 10 KB for 70 repos), so 10 MB
    # keeps years of nights. Emptied in place (see log-size-cap.nix).
    log_max_bytes=$((10 * 1024 * 1024))
    # Search depth for .git under DEV_ROOT: repos up to 5 levels below it. On
    # 2026-11-10 the deepest repo with linked worktrees was 4 levels down
    # (~/Dev/AI/pi/extensions/pi-subagents). Under WT_ROOT a worktree sits at
    # <path under ~/Dev>/<branch>, so 2 levels more.
    dev_depth=6
    wt_depth=8

    if [ -n "''${WORKTREES_SWEEP_LOG:-}" ]; then
      log-size-cap "$log_max_bytes" "$WORKTREES_SWEEP_LOG" || true
    fi
    echo "$(date +%Y-%m-%dT%H:%M:%S%z) worktrees-sweep: start (DEV_ROOT=$dev_root WT_ROOT=''${wt_root:-unset})"

    # Prints the main checkout of the repo that holds $1. Fails for a bare repo
    # or a path outside git.
    main_checkout() {
      local common
      common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
      case "$common" in */.git) printf '%s\n' "''${common%/.git}" ;; *) return 1 ;; esac
    }

    # find prints each .git of type $3 at most $2 levels below $1; it does not
    # descend into node_modules, .devenv or .git.
    find_git() {
      find "$1" -maxdepth "$2" \( -name node_modules -o -name .devenv -o -name .git \) -prune \
        -name .git -type "$3" -print 2>/dev/null
    }

    list_repos() {
      local g d n gitdir
      if [ -d "$dev_root" ]; then
        while IFS= read -r g; do
          d=''${g%/.git}
          n=$(git -C "$d" worktree list --porcelain 2>/dev/null | grep -c '^worktree ') || continue
          if [ "$n" -gt 1 ]; then
            main_checkout "$d" || echo "worktrees-sweep: skipped $d: no main checkout" >&2
          fi
        done < <(find_git "$dev_root" "$dev_depth" d)
      fi
      if [ -n "$wt_root" ] && [ -d "$wt_root" ]; then
        while IFS= read -r g; do
          d=''${g%/.git}
          # A linked worktree's git dir is <common dir>/worktrees/<name>; a
          # submodule's .git file points elsewhere and is skipped.
          gitdir=$(git -C "$d" rev-parse --path-format=absolute --git-dir 2>/dev/null) || gitdir=
          case "$gitdir" in
            */.git/worktrees/*) main_checkout "$d" || echo "worktrees-sweep: skipped $d: no main checkout" >&2 ;;
            "") echo "worktrees-sweep: skipped $d: git cannot read it" >&2 ;;
          esac
        done < <(find_git "$wt_root" "$wt_depth" f)
      fi
    }

    mapfile -t repos < <(list_repos | sort -u)
    failed=0
    for repo in "''${repos[@]}"; do
      echo "worktrees-sweep: repo $repo"
      # worktrees-landed exits 0 for a path that is not a git repo (checked
      # 2026-11-10), so a repo that is gone since the listing is caught here.
      if [ "$(main_checkout "$repo")" != "$repo" ]; then
        failed=$((failed + 1))
        echo "worktrees-sweep: $repo is no longer a git main checkout; continuing"
        continue
      fi
      "$landed" "$repo" --remove </dev/null || {
        rc=$?
        failed=$((failed + 1))
        echo "worktrees-sweep: worktrees-landed failed for $repo (exit $rc); continuing"
      }
    done
    echo "$(date +%Y-%m-%dT%H:%M:%S%z) worktrees-sweep: done: ''${#repos[@]} repos seen, $failed with failures"
  '';
}
