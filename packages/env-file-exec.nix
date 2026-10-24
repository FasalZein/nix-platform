# env-file-exec: wait for a rendered env file, load it, exec a command; the
# logic is in env-file-exec.sh, the parser in secrets/load-shell-secrets.zsh.
# Used by the 9router launchd agent in modules/darwin.nix.
{ writeTextFile, zsh }:

writeTextFile {
  name = "env-file-exec";
  executable = true;
  destination = "/bin/env-file-exec";
  text = "#!${zsh}/bin/zsh -f\n"
    + builtins.replaceStrings [ "@loader@" ] [
        (builtins.replaceStrings [ "@shellEnvFile@" ] [ "$env_file" ]
          (builtins.readFile ../secrets/load-shell-secrets.zsh))
      ] (builtins.readFile ./env-file-exec.sh);
  checkPhase = "${zsh}/bin/zsh -n $target";
  meta.mainProgram = "env-file-exec";
}
