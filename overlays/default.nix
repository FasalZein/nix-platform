# Pins for tools that package.json and lockfiles do not pin.
# Rust is not here: each repo pins it in rust-toolchain.toml (devenv languages.rust.toolchainFile).
# pnpm is not here: repos pin it in package.json "packageManager"; corepack enforces it.
# Worker caps (VITEST_MAX_WORKERS, CARGO_BUILD_JOBS) are not here: heavy owns them.
# Expected versions: ../expected-versions.nix (checked by `nix flake check`).
final: prev: {
  # nixpkgs ships a newer bun; repos pin bun@1.4.0. Same derivation, older release zips.
  bun = prev.bun.overrideAttrs (old: {
    version = "1.4.0";
    passthru = old.passthru // {
      sources = {
        aarch64-darwin = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-darwin-aarch64.zip";
          hash = "sha256-xmnpf2Fk4cluBwF0jbmN+ndJKQjL2DlMdVcTSnNd44E=";
        };
        aarch64-linux = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-linux-aarch64.zip";
          hash = "sha256-SxozLuhhmD65O8/m93D/+U4+MbLDiL2uo8jtNeWO7Q4=";
        };
        x86_64-linux = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-linux-x64-baseline.zip";
          hash = "sha256-GE+0WV8NQBohfPfHjBvEMLqDMU2reouUgFurv3+nCX8=";
        };
      };
    };
  });

  # Major versions are chosen here; the exact version comes from flake.lock (nixpkgs).
  nodejs = final.nodejs_24;
  postgresql = final.postgresql_17;
  # uv: the nixpkgs version from flake.lock, checked against expected-versions.nix.
}
