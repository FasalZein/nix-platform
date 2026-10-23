# 2password CLI (1Password for agents), from the published npm tarball.
# The login agent in modules/darwin.nix renders env templates with it, so it
# must not depend on the mutable bun global install. The tarball ships
# TypeScript sources run by bun and no lockfile; package.json and
# package-lock.json here pin its runtime dependencies to the versions the bun
# global ran when this was packaged (effect 4.0.1), without devDependencies.
# It calls `osascript` (Keychain) and `op` (Homebrew 1password-cli cask) from PATH.
{ lib, buildNpmPackage, fetchurl, makeWrapper, bun }:

buildNpmPackage (finalAttrs: {
  pname = "2password";
  version = "0.2.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/2password/-/2password-${finalAttrs.version}.tgz";
    # npm registry "integrity" field.
    hash = "sha512-sJLouiOWkSVIe4R717WdhEjmFp9EmXWpsb1znF+OlBPW3cUvJ1u02sIgFmVSXfnqKVOMgfiI+xVEug8vzJ/xDw==";
  };
  sourceRoot = "package";

  postPatch = ''
    cp ${./package.json} package.json
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-pWKgNOxXGfztvPJXc33QSFTFi09NNxh9LPEMuyTVhyE=";
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  # Replace the npm bin link (shebang `#!/usr/bin/env bun`) with a wrapper
  # that runs the pinned bun.
  postInstall = ''
    rm $out/bin/2password
    makeWrapper ${lib.getExe bun} $out/bin/2password \
      --add-flags $out/lib/node_modules/2password/bin/2password
  '';

  meta = {
    description = "Find, create, and use 1Password secrets without exposing them";
    homepage = "https://github.com/kitlangton/2password";
    license = lib.licenses.mit;
    mainProgram = "2password";
    platforms = lib.platforms.darwin;
  };
})
