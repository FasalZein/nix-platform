# tla-ts, a TypeScript port of TLC, as the TLC engine for pstack's statechart
# skill (FasalZein/nix-platform#29). From the published npm tarballs by exact
# version and registry hash, so no package manager runs and the host's 7-day
# minimum release age (~/.bunfig.toml minimumReleaseAge) is neither read nor
# changed.
# Owner decision 2026-11-10: "bypass the minimum release for tla-ts". tla-ts
# 0.0.9 was published 2026-11-08T05:22Z, inside the 7-day window. The bypass
# covers tla-ts 0.0.9 and its one dependency, fflate, only. fflate 0.8.3 was
# published 2026-05-16 and is outside the window anyway.
# Evidence: in 1.7.4 mode tla-ts 0.0.9 matched Java TLC 1.7.4 byte for byte on
# pstack's corpus.test.ts (47/47); without the pin it failed 6/47
# (~/.pi/artifacts/pi-pstack/tla-ts-check-20261109.md). tla-ts is v0.0.x:
# re-run corpus.test.ts on every version bump.
{ lib, stdenvNoCC, fetchurl, makeWrapper, nodejs }:

let
  # tla-ts 0.0.9 depends on fflate ^0.8.3; 0.8.3 is the newest 0.8.x.
  fflate = fetchurl {
    url = "https://registry.npmjs.org/fflate/-/fflate-0.8.3.tgz";
    # npm registry "integrity" field.
    hash = "sha512-tbZNuJrLwGUp3zshBtdy4W+ORxZuIh8a5ilyIEQDC5rY1f3U20JMry0Ll3WBzU58EZKsEuJFXhb5gwv8CsPvgA==";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "tla-ts";
  # Exact pin, no range.
  version = "0.0.9";

  src = fetchurl {
    url = "https://registry.npmjs.org/tla-ts/-/tla-ts-${finalAttrs.version}.tgz";
    # npm registry "integrity" field.
    hash = "sha512-x58wRtZt4CyOjC13Vz04efVuYZmvqhSZCakUEdA0HlR8WcTUwhQblHZXksUK8sWI5lWliTt6S6xzumOPjFDk7Q==";
  };

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  # Prebuilt JavaScript only: nothing to strip or patch.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    pkg=$out/lib/node_modules/tla-ts
    mkdir -p $pkg/node_modules/fflate $out/bin
    cp -R . $pkg
    tar -xzf ${fflate} -C $pkg/node_modules/fflate --strip-components=1
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
