{ pkgs, ... }:

{
  imports = [ ./worktrees-sweep.nix ];

  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    devenv
    nix-fast-build
    nixfmt
    # Fast search and inspection tools named in ~/.pi/agent/AGENTS.md (Tooling).
    ripgrep
    fd
    ast-grep
    jq
    bat
    eza
    hyperfine
    dust
    # Pinned by overlays/default.nix (versions in expected-versions.nix).
    # Ahead of Homebrew, ~/.bun/bin and ~/.local/bin via /etc/zlogin (modules/darwin.nix).
    bun
    uv
    nodejs
    git
    gh
  ];

  # Writes ~/.config/direnv/direnvrc with nix-direnv (cached, GC-rooted envs).
  # The shell hook itself lives in /etc/zshrc (modules/darwin.nix).
  programs.direnv = {
    enable = true;
    enableZshIntegration = false;
    nix-direnv.enable = true;
    # Writes ~/.config/direnv/direnv.toml. disable_stdin points .envrc stdin at
    # /dev/null, so a slow devenv eval cannot read keys typed into a new pane (#28).
    config.global.disable_stdin = true;
  };
}
