{ config, lib, pkgs, ... }:

let
  settings = pkgs.writeText "pi-managed-settings.json" (builtins.toJSON (import ../pi/settings.nix));
  emptySettings = pkgs.writeText "pi-empty-settings.json" "{}";
  # Deliberately use the main checkout, even when building from a worktree.
  checkout = "${config.home.homeDirectory}/Dev/nix-platform/pi";
  files = [
    "extensions/shell-guard.ts"
    # Link leaves, not the directory: env-wrap.before-hm/index.ts would autoload.
    "extensions/env-wrap/core.ts"
    "extensions/env-wrap/index.ts"
    "extensions/pi-tps.ts"
    "extensions/skill-gate.ts"
    "extensions/cbcn-compat.ts"
    "extensions/sys1-launch-risk.ts"
    "packages/request-telemetry/index.ts"
    "packages/request-telemetry/package.json"
  ];
  updateSettings = pkgs.writeShellScript "pi-update-settings" ''
    set -eu
    settingsDir="$HOME/.pi/agent"
    ${pkgs.coreutils}/bin/mkdir -p "$settingsDir"
    settingsFile="$settingsDir/settings.json"
    input="$settingsFile"
    if [ ! -e "$input" ]; then
      input=${emptySettings}
    fi

    # Keep settings writable and replace atomically on the same filesystem.
    tmp=$(${pkgs.coreutils}/bin/mktemp "$settingsDir/settings.json.XXXXXX")
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
    ${pkgs.jq}/bin/jq -e -s --slurpfile managed ${settings} '
      if length == 1 and (.[0] | type) == "object" then
        .[0] + $managed[0]
      else
        error("pi settings.json must contain one JSON object")
      end
    ' "$input" > "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$settingsFile"
  '';
in
{
  home.file = lib.genAttrs (map (file: ".pi/agent/${file}") files) (name: {
    source = config.lib.file.mkOutOfStoreSymlink
      "${checkout}/${lib.removePrefix ".pi/agent/" name}";
  });

  # `run` honors Home Manager dry runs; never link settings.json into the store.
  home.activation.piSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${updateSettings}
  '';
}
