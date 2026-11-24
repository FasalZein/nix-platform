# tla-ts, a TypeScript port of TLC, as the TLC engine for pstack's statechart
# skill (FasalZein/nix-platform#29). From the published npm tarballs by exact
# version and registry hash, so no package manager runs and the host's 7-day
# minimum release age (~/.bunfig.toml minimumReleaseAge) is neither read nor
# changed.
# Owner decision 2026-11-10: "bypass the minimum release for tla-ts" (for
# 0.0.9, published inside the 7-day window). 0.0.10 and every dependency
# below were published more than 7 days before the bump (2026-11-24), so the
# bypass is no longer needed: tla-ts 0.0.10 2026-11-11, fflate 0.8.3
# 2026-05-16, @typescript/typescript6 6.0.2 2026-07-06, typescript 6.0.3
# 2026-04-16.
# Evidence: in 1.7.4 mode tla-ts 0.0.9 matched Java TLC 1.7.4 byte for byte on
# pstack's corpus.test.ts (47/47); without the pin it failed 6/47
# (~/.pi/artifacts/pi-pstack/tla-ts-check-20261109.md). On 2026-11-24
# (pi-pstack bb03fac) corpus.test.ts has 50 tests; 0.0.10 and 0.0.9 in 1.7.4
# mode both pass 47 of 50, with the same output. The 3 failures, a gap of
# both versions: "a spec with an unknown name / a parse error / twelve
# unknown names gets SANY's line and column, not a Java stack trace" (added
# in pi-pstack 9ff8df8): tla-ts's SANY XML export prints a Java-style stack
# trace instead of SANY's "*** Errors" line and column.
# tla-ts is v0.0.x: re-run corpus.test.ts on every version bump.
# This is the one tla-ts on the host: TLA+ checks run `tla-ts` and the
# statechart skill runs `tla-ts-174` through $JAVA (modules/darwin.nix).
{ lib, stdenvNoCC, fetchurl, makeWrapper, nodejs }:

let
  # tla-ts 0.0.10 depends on fflate ^0.8.3 (0.8.3 is the newest 0.8.x) and
  # on @typescript/typescript6 6.0.2, which re-exports its own dependency
  # @typescript/old = npm:typescript@^6 (6.0.3 is the newest 6.x). Only the
  # `compile` subcommand (TypeScript to TLA+, dist/compile.js, loaded on
  # demand) uses TypeScript; model checking does not.
  # Hashes: the npm registry "integrity" field of each tarball.
  fflate = fetchurl {
    url = "https://registry.npmjs.org/fflate/-/fflate-0.8.3.tgz";
    hash = "sha512-tbZNuJrLwGUp3zshBtdy4W+ORxZuIh8a5ilyIEQDC5rY1f3U20JMry0Ll3WBzU58EZKsEuJFXhb5gwv8CsPvgA==";
  };
  typescript6 = fetchurl {
    url = "https://registry.npmjs.org/@typescript/typescript6/-/typescript6-6.0.2.tgz";
    hash = "sha512-mbCddXd+jm7hfx7w2YU64/Av4/NqqeG3GoRZgxPcgoTxYjhrcfJRw9ULch71SS4G+Q3bOXFhRvPqjguN0Hyp5w==";
  };
  typescript = fetchurl {
    url = "https://registry.npmjs.org/typescript/-/typescript-6.0.3.tgz";
    hash = "sha512-y2TvuxSZPDyQakkFRPZHKFm+KKVqIisdg9/CZwm9ftvKXLP8NRWj38/ODjNbr43SsoXqNuAisEf1GdCxqWcdBw==";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "tla-ts";
  # Exact pin, no range.
  version = "0.0.10";

  src = fetchurl {
    url = "https://registry.npmjs.org/tla-ts/-/tla-ts-${finalAttrs.version}.tgz";
    # npm registry "integrity" field.
    hash = "sha512-Ki4mbMjn3Gq8BjxlRVUISDQJCwZlPUsj3cSgg365eckHpoZMbqi3v0vRZ1ZPNcWfcRMzvC8S9lERtOQlNTD30A==";
  };

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  # Prebuilt JavaScript only: nothing to strip or patch.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    pkg=$out/lib/node_modules/tla-ts
    ts6=$pkg/node_modules/@typescript/typescript6
    mkdir -p $pkg/node_modules/fflate $ts6/node_modules/@typescript/old $out/bin
    cp -R . $pkg
    tar -xzf ${fflate} -C $pkg/node_modules/fflate --strip-components=1
    tar -xzf ${typescript6} -C $ts6 --strip-components=1
    tar -xzf ${typescript} -C $ts6/node_modules/@typescript/old --strip-components=1
    makeWrapper ${lib.getExe nodejs} $out/bin/tla-ts \
      --add-flags $pkg/dist/cli.js
    # statechart spawns $JAVA as one executable without a shell, and tla-ts
    # reads no env var for the TLC version. Without a real v1.7.4 jar tla-ts
    # copies TLC nightly ("master"), which pstack's corpus does not match.
    makeWrapper $out/bin/tla-ts $out/bin/tla-ts-174 \
      --add-flags -Dtla-ts.tlc=1.7.4
    runHook postInstall
  '';

  meta = {
    description = "TLA+ model checker (TLC) in TypeScript, with a TLC 1.7.4 wrapper for pstack statechart";
    homepage = "https://www.npmjs.com/package/tla-ts";
    license = lib.licenses.mit;
    mainProgram = "tla-ts";
    platforms = nodejs.meta.platforms;
  };
})
