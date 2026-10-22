{ pkgs, ... }:

{
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
  ];

  # Writes ~/.config/direnv/direnvrc with nix-direnv (cached, GC-rooted envs).
  # The shell hook itself lives in /etc/zshrc (modules/darwin.nix).
  programs.direnv = {
    enable = true;
    enableZshIntegration = false;
    nix-direnv.enable = true;
  };
}
