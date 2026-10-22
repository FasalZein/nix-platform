# Shared devenv module. Repos import it from devenv.yaml:
#   imports: [ nix-platform/devenv ]
# Keep it small: settings every repo shares. Repos enable their own languages and services.
# Git hooks: nothing to set. devenv installs hooks only when a repo enables a git-hooks.hooks entry,
# so repos keep their own hook managers (husky, lefthook).
{ lib, ... }:
{
  # Repos keep .env files for their apps; devenv does not load them and does not print a hint.
  dotenv.disableHint = lib.mkDefault true;

  # Agent shells are non-interactive: let corepack fetch the packageManager version without a prompt.
  env.COREPACK_ENABLE_DOWNLOAD_PROMPT = lib.mkDefault "0";
}
