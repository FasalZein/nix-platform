# Expected versions of the tools that overlays/default.nix pins.
# `nix flake check` (checks.<system>.pin-drift) runs each tool and fails when
# its reported version differs from the value here. To bump a tool, change the
# overlay (or run `nix flake update`), then change the value here in the same commit.
{
  bun = "1.4.4"; # Bayland, runbook, costwise, bwf-astro pin bun@1.4.4 in packageManager
  # The default nodejs is major 24; pin-drift checks it against nodejs_24.
  nodejs_22 = "22.23.4"; # security floor (bwf-astro, bayland-platform, Bayland portfolio); nixpkgs ships it since 9397dcb
  nodejs_24 = "24.22.2"; # major 24 matches CI (actions/setup-node node-version: 24)
  uv = "0.13.7";
  postgresql = "17.12"; # major 17 matches the Homebrew server that holds today's data
}
