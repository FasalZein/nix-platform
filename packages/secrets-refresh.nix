# `secrets-refresh` command (secrets refresh); the logic is in secrets-refresh.sh.
{ writeShellApplication }:

writeShellApplication {
  name = "secrets-refresh";
  text = builtins.readFile ./secrets-refresh.sh;
}
