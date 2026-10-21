{ pkgs, ... }:

{
  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    devenv
    nix-fast-build
    nixfmt
  ];

  # Writes ~/.config/direnv/direnvrc with nix-direnv (cached, GC-rooted envs).
  # The shell hook itself lives in /etc/zshrc (modules/darwin.nix).
  programs.direnv = {
    enable = true;
    enableZshIntegration = false;
    nix-direnv.enable = true;
  };
}
