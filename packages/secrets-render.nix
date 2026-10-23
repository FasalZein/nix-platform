# Login-agent renderer for env templates; the logic is in secrets-render.sh.
# Used by modules/darwin.nix. op comes from PATH (Homebrew 1password-cli cask:
# unfree in nixpkgs); osascript and tmutil from /usr/bin.
{ writeShellApplication, callPackage }:

writeShellApplication {
  name = "secrets-render";
  runtimeInputs = [ (callPackage ./2password { }) ];
  text = builtins.readFile ./secrets-render.sh;
}
