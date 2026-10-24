# 9router AI routing gateway, from the published npm CLI tarball.
# The tarball ships a prebuilt Next.js standalone server in app/ with its
# node_modules and no native addons. We run app/custom-server.js directly, as
# the decolua/9router Docker image does, and skip cli.js: the CLI installs
# sql.js and better-sqlite3 into DATA_DIR/runtime at start. On Node >= 24 the
# app skips better-sqlite3 and uses the built-in node:sqlite driver.
{ lib, stdenvNoCC, fetchurl, makeWrapper, nodejs }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "9router";
  # Latest npm release on 2026-10-24 (was 0.5.75, the Docker image version).
  version = "0.5.109";

  src = fetchurl {
    url = "https://registry.npmjs.org/9router/-/9router-${finalAttrs.version}.tgz";
    # npm registry "integrity" field.
    hash = "sha512-MKI/tfQSpMhToVyVkXanHddxdfD1YQGYR4+jCxjGrMxz1xNrbR6WuNmY2+jpV745JOvGz9wlDel+APodwaEyfw==";
  };

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  # Prebuilt JavaScript only: nothing to strip or patch. The ELF/RPATH audit
  # over the ~3,000 files also segfaulted in its find | while pipeline.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/9router $out/bin
    cp -R app $out/lib/9router/app
    # Reads PORT, HOSTNAME, DATA_DIR and the secrets from the environment.
    makeWrapper ${lib.getExe nodejs} $out/bin/9router-server \
      --add-flags $out/lib/9router/app/custom-server.js \
      --set-default NODE_ENV production \
      --set NEXT_TELEMETRY_DISABLED 1
    runHook postInstall
  '';

  meta = {
    description = "AI routing gateway with an OpenAI-compatible API (Next.js standalone server)";
    homepage = "https://www.npmjs.com/package/9router";
    license = lib.licenses.mit;
    mainProgram = "9router-server";
    platforms = nodejs.meta.platforms;
  };
})
