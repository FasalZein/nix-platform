# On-demand start and idle stop for the nix-darwin linux-builder VM.
# Used by modules/darwin.nix; the logic is in linux-builder-on-demand.sh.
{ writeShellApplication }:

writeShellApplication {
  name = "linux-builder-on-demand";
  text = builtins.readFile ./linux-builder-on-demand.sh;
}
