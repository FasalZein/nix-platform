# Pins for tools that package.json and lockfiles do not pin.
# Rust is not here: each repo pins it in rust-toolchain.toml (devenv languages.rust.toolchainFile).
# pnpm is not here: repos pin it in package.json "packageManager"; corepack enforces it.
# Worker caps (VITEST_MAX_WORKERS, CARGO_BUILD_JOBS) are not here: heavy owns them.
# Expected versions: ../expected-versions.nix (checked by `nix flake check`).
final: prev: {
  # Repos pin bun@1.4.4 (security fix over 1.4.0); the locked nixpkgs ships 1.4.2. Same derivation, other release zips.
  bun = prev.bun.overrideAttrs (old: {
    version = "1.4.4";
    # src follows passthru.sources below, so the version and src do change together.
    __intentionallyOverridingVersion = true;
    passthru = old.passthru // {
      sources = {
        aarch64-darwin = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-darwin-aarch64.zip";
          hash = "sha256-wkDX8My5DCY6hJ/NsJt+5iYw2SE0jtaq/ahrnVd7xRA=";
        };
        aarch64-linux = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-aarch64.zip";
          hash = "sha256-uqa7NvUdblhWHgK76oJQOKnfRU9nPW13bou/hvjHhQ4=";
        };
        x86_64-linux = final.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-x64-baseline.zip";
          hash = "sha256-4ERutVmVdy65iUvrrppr42jZhai5Jx7hJEhvmUbu3XY=";
        };
      };
    };
  });

  # Major versions are chosen here; the exact version comes from flake.lock (nixpkgs).
  nodejs = final.nodejs_24;
  postgresql = final.postgresql_17;
  # uv: the nixpkgs version from flake.lock, checked against expected-versions.nix.
}
