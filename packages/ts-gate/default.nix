# ts-gate: Oxlint with the landmines rules (github.com/interfere-inc/landmines)
# in their "recommended" configuration (correctness and suspicious), for the
# agent harness. The harness hook (~/.pi/agent extensions/ts-gate.ts) runs it
# on the TypeScript files of every commit an agent makes and prints the
# findings on added lines; it never blocks. Usage: ts-gate [oxlint args] FILE...
#
# From the published npm tarballs by exact version and registry hash
# (package-lock.json here), so no package manager runs at run time and the
# host's 7-day minimum release age (~/.bunfig.toml) is neither read nor
# changed. Oxlint is the nixpkgs binary (>= 1.81, the landmines minimum);
# --legacy-peer-deps keeps npm from installing a second oxlint as the peer.
# Owner decision 2026-11-24: landmines 0.3.1, published 2026-11-24T05:01Z,
# inside the 7-day window; it becomes active only at the owner's switch.
{ lib, buildNpmPackage, makeWrapper, oxlint }:

buildNpmPackage {
  pname = "ts-gate";
  # The landmines version; package.json pins it exactly.
  version = "0.3.1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./package.json ./package-lock.json ./landmines.json ];
  };

  npmDepsHash = "sha256-AEiPcXDt8O9sGVmjUwJ90dvN7pEHqkk2L+P6T6V+voE=";
  npmFlags = [ "--legacy-peer-deps" ];
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  # landmines.json: "plugins": [] and correctness "off" turn off the built-in
  # Oxlint rules, so every finding names a landmines rule.
  # -c turns off the project's own Oxlint config, so a project needs no
  # install and its rules do not mix in. The oxlint binary runs the JS plugin
  # without node on PATH (checked with env -i, 2026-11-24).
  postInstall = ''
    pkg=$out/lib/node_modules/ts-gate
    cp landmines.json $pkg/landmines.json
    makeWrapper ${lib.getExe oxlint} $out/bin/ts-gate \
      --add-flags "-c $pkg/landmines.json"
  '';

  meta = {
    description = "Oxlint with the landmines recommended rules, report-only commit gate for agents";
    homepage = "https://github.com/interfere-inc/landmines";
    license = lib.licenses.mit;
    mainProgram = "ts-gate";
    platforms = lib.platforms.darwin;
  };
}
