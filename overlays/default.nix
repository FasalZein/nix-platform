# Pins for tools that package.json and lockfiles do not pin.
# Rust is not here: each repo pins it in rust-toolchain.toml (devenv languages.rust.toolchainFile).
# pnpm is not here: repos pin it in package.json "packageManager"; corepack enforces it.
# Worker caps (VITEST_MAX_WORKERS, CARGO_BUILD_JOBS) are not here: modules/darwin.nix sets them in environment.variables.
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

  # Node majors: repos pick one with languages.javascript.package = pkgs.nodejs_22 or pkgs.nodejs_24.
  # nodejs_22 and nodejs_24 come from nixpkgs (flake.lock).

  # Major versions are chosen here; the exact version comes from flake.lock (nixpkgs).
  nodejs = final.nodejs_24;
  postgresql = final.postgresql_17;
  # uv: the nixpkgs version from flake.lock, checked against expected-versions.nix.

  # ghui: the owner runs 0.9.1 (Homebrew); the locked nixpkgs ships 0.4.6. Same
  # build (bun build:cli). Upstream ships only bun.lock, so ghui/package-lock.json
  # is generated with `npm install --package-lock-only` from the v0.9.1 package.json
  # (workspace:* read as *, then put back in the root entry, as nixpkgs' lock has it).
  # buildNpmPackage computes npmDeps from its arguments, so npmDeps is set here.
  # dev/build-cli.ts bundles @effect/sql-sqlite-bun, and bun 1.4.4 renames the
  # `export * from "effect/unstable/sql/Migrator"` namespace in only one place:
  # the app stops on "ReferenceError: Migrator2 is not defined" at boot. It is a
  # runtime dependency in package.json, so it is left external like effect is.
  ghui = prev.ghui.overrideAttrs (old: rec {
    version = "0.9.1";
    src = final.fetchFromGitHub {
      owner = "kitlangton";
      repo = "ghui";
      tag = "v${version}";
      hash = "sha256-K051E6+da+JZs16Kna6/Xnwhkk5b6alpC3AT/4kq4pY=";
    };
    postPatch = ''
      cp ${./ghui/package-lock.json} package-lock.json
      substituteInPlace dev/build-cli.ts \
        --replace-fail 'external: [' 'external: ["@effect/sql-sqlite-bun", '
    '';
    npmDeps = final.fetchNpmDeps {
      name = "ghui-${version}-npm-deps";
      inherit src postPatch;
      hash = "sha256-2i7rkQi8K/+Pq/mw3TA+Gekm3elak8m+Tiv1eVVsnZU=";
      fetcherVersion = 2;
    };
  });
}
