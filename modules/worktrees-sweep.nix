{ config, osConfig, pkgs, lib, ... }:

let
  home = config.home.homeDirectory;
  # launchd does not expand $HOME, so the path is absolute.
  log = "${home}/Library/Logs/worktrees-sweep.log";
in
{
  # Nightly at 03:30, when the owner is away (owner decision D5, spec
  # worktree-home, issue #31): remove landed, clean, idle linked worktrees in
  # every repo under ~/Dev and every repo with a worktree under WT_ROOT.
  # `wt new` sweeps only its own repo, and about 70 linked worktrees built up
  # across ~/Dev. worktrees-landed keeps dirty, busy, fresh, pushed and local
  # worktrees (D7). Label org.nix-community.home.worktrees-sweep. launchd runs
  # a missed run once after the Mac wakes.
  launchd.agents.worktrees-sweep = {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe (pkgs.callPackage ../packages/worktrees-sweep.nix { })) ];
      StartCalendarInterval = [{ Hour = 3; Minute = 30; }];
      ProcessType = "Background";
      LowPriorityIO = true;
      # git, gh (merged PRs) and devenv (devenv processes down) from the user
      # profile; lsof from /usr/sbin. Same PATH as worktree-idle-sweep.
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
