# SuperTokens core (auth service) with the PostgreSQL plugin, run on a Nix JDK.
# SuperTokens publishes no fixed release artifact: api.supertokens.io builds a
# fresh zip on every request (new timestamps, new hash) and its install step
# downloads the dependency jars at run time. So we pin the official Docker image
# by digest and copy its install directory /usr/lib/supertokens, minus the
# bundled Linux JRE. The jars are platform neutral; argon2-jvm ships a
# darwin-aarch64 libargon2 inside its jar.
# Bump: change version and imageDigest (from the image index), set hash to
# lib.fakeHash, build, and copy the hash that nix prints.
{ lib, stdenvNoCC, dockerTools, jq, makeWrapper, temurin-bin-21 }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "supertokens";
  # Core version; the image also carries postgresql plugin 9.4.2 and
  # plugin-interface 8.5.0 (see $out/lib/supertokens/version.yaml).
  version = "11.4.3";

  src = dockerTools.pullImage {
    imageName = "supertokens/supertokens-postgresql";
    # Index digest of :latest on 2026-11-02 (image created 2026-04-08).
    imageDigest = "sha256:d4fdb7468ca16b7feb14e7c6436e0c43a5b8dabb606ec18f88c1084345046ef9";
    hash = "sha256-bMKvVVcuxf3K7a3p9FU8iNTfxRhBQgGQNjaaeY1rvBQ=";
    os = "linux";
    arch = "arm64";
    finalImageName = "supertokens/supertokens-postgresql";
    finalImageTag = finalAttrs.version;
  };

  nativeBuildInputs = [ jq makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  # Jars only: nothing to strip; the one script is patched in installPhase.
  dontFixup = true;

  unpackPhase = ''
    runHook preUnpack
    mkdir image root
    tar -xf $src -C image
    for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
      # grep -q would close the pipe early and fail tar under pipefail.
      if tar -tf "image/$layer" | grep '^usr/lib/supertokens/' >/dev/null; then
        tar -xf "image/$layer" -C root usr/lib/supertokens
      fi
    done
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/bin $out/libexec
    cp -R root/usr/lib/supertokens $out/lib/supertokens
    # The Linux JRE is replaced by Temurin 21; the empty run-time directories
    # are created in the state directory by supertokens-core.sh.
    # ee/ee.jar is under the SuperTokens Enterprise licence, not Apache 2.0. It
    # only unlocks paid features with a licence key; without a key the core
    # reports no features either way, and it starts and signs users in
    # without ee/ (spike 2026-11-02). Dropping it keeps the package Apache 2.0.
    rm -rf $out/lib/supertokens/{jre,ee,.started,logs,webserver-temp}
    grep -qx 'core_version: ${finalAttrs.version}' $out/lib/supertokens/version.yaml
    install -m 755 ${./supertokens-core.sh} $out/libexec/supertokens-core.sh
    patchShebangs $out/libexec
    makeWrapper $out/libexec/supertokens-core.sh $out/bin/supertokens-core \
      --set SUPERTOKENS_HOME $out/lib/supertokens \
      --set JAVA ${lib.getExe' temurin-bin-21 "java"}
    runHook postInstall
  '';

  meta = {
    description = "SuperTokens core with the PostgreSQL plugin, from the official image, on Temurin 21";
    homepage = "https://github.com/supertokens/supertokens-core";
    license = lib.licenses.asl20;
    mainProgram = "supertokens-core";
    platforms = temurin-bin-21.meta.platforms;
  };
})
