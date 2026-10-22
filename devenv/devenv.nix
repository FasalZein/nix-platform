# Shared devenv module. Repos import it from devenv.yaml:
#   imports: [ nix-platform/devenv ]
# Keep it small: settings every repo shares. Repos enable their own languages and services.
{ lib, ... }:
{
  # Repos keep their own hook managers (husky, lefthook). devenv installs no git hooks.
  git-hooks.hooks = lib.mkDefault { };

  # Repos keep .env files for their apps; devenv must not load them or print a hint about them.
  dotenv.disableHint = lib.mkDefault true;
}
