{ config, osConfig, pkgs, lib, ... }:

let
  home = config.home.homeDirectory;
  # launchd does not expand $HOME, so the path is absolute.
  log = "${home}/Library/Logs/worktrees-sweep.log";
in
{
  # Nightly at 03:30, when the owner is away (owner decision D5, spec
  # worktree-home, issue #31): run `worktrees-landed <repo> --remove` in every
  # repo under ~/Dev and every repo with a worktree under WT_ROOT. `wt new`
  # sweeps only its own repo, and about 70 linked worktrees built up across
  # ~/Dev. Label org.nix-community.home.worktrees-sweep. launchd runs a missed
  # run once after the Mac wakes.
  launchd.agents.worktrees-sweep = {
    # Enabled (owner decision 2026-11-24). It removes only "landed" worktrees:
    # clean, with HEAD in origin/HEAD, in origin's copy of the main checkout's
    # branch, or in a merged PR's head commit. Only remote facts count, so a
    # commit merged only into the local main ("unpushed") is kept. It keeps
    # dirty, busy, fresh, pushed, local and unpushed worktrees (D7). It never
    # stops devenv services: a worktree whose services run is kept, and the
    # hourly worktree-idle-sweep agent (modules/darwin.nix) stops idle services,
    # so a later night removes it. Before each removal it checks again at the
    # path, renames the worktree to a private name, checks again there, and
    # moves it back when anything changed; a failed lsof counts as "in use".
    # The promise and its model check (WorktreeRemovalWindow.cfg,
    # WorktreeRemovalSnapFail.cfg, late-change-repro.sh):
    # ~/.pi/agent/.pi/skills/worktree-removal-verify/SKILL.md (sync commit
    # 9c3cd45). Enabled after both configs passed and the repro printed "kept"
    # for fresh, local, busy, snapfail, svc-late, svc-idle and unpushed on
    # ~/.pi/agent 507b859 (#52 and finding 3 fixed).
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe (pkgs.callPackage ../packages/worktrees-sweep.nix { })) ];
      StartCalendarInterval = [{ Hour = 3; Minute = 30; }];
      ProcessType = "Background";
      LowPriorityIO = true;
      # git and gh (merged PRs) from the user profile; lsof from /usr/sbin
      # (process snapshot), ps from /bin. The sweep runs no devenv. Same PATH
      # as worktree-idle-sweep.
      EnvironmentVariables = {
        HOME = home;
        DEV_ROOT = "${home}/Dev";
        # Set by modules/darwin.nix (issue #30); launchd agents do not get
        # environment.variables, so it is passed here.
        WT_ROOT = osConfig.environment.variables.WT_ROOT;
        WORKTREES_SWEEP_LOG = log;
        PATH = "/etc/profiles/per-user/tothemoon/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin";
      };
      StandardOutPath = log;
      StandardErrorPath = log;
    };
  };
}
