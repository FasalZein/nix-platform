# Node.js from the official release binaries (nodejs.org/dist), for a security
# pin that is newer than the Node of the locked nixpkgs. The hashes are the
# SHASUMS256.txt values of the release, converted to SRI.
# Includes node, npm, npx and corepack, as the release tarball does.
{ lib, stdenv, fetchurl }:

let
  version = "22.23.4";
  # nodejs.org platform name and the hash of node-v<version>-<name>.tar.*.
  dist = {
    aarch64-darwin = { name = "darwin-arm64"; ext = "tar.gz"; hash = "sha256-yeHbx0izPtLRT0JEUZHsrxTFYlnHqaJtAELEnsK2ZCg="; };
    aarch64-linux = { name = "linux-arm64"; ext = "tar.xz"; hash = "sha256-YoeqRrbDddgW5jrmbQJPu/1wQEglqr39+JipcIcdL0s="; };
    x86_64-linux = { name = "linux-x64"; ext = "tar.xz"; hash = "sha256-GAW8015oFVWb0uuX20ONP9sOs6XmqXe3wbrcp2M36c4="; };
  };
  d = dist.${stdenv.hostPlatform.system}
    or (throw "nodejs-bin ${version}: no release binary for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "nodejs";
  inherit version;

  src = fetchurl {
    url = "https://nodejs.org/dist/v${version}/node-v${version}-${d.name}.${d.ext}";
    inherit (d) hash;
  };

  dontConfigure = true;
  dontBuild = true;
  # Stripping would break the code signature of the macOS binary.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -R bin include lib share $out/
  '' + lib.optionalString stdenv.hostPlatform.isLinux ''
    # The Linux binary links glibc, libstdc++ and libgcc_s; point it at the Nix copies.
    # Not autoPatchelfHook: --set-rpath on this non-PIE binary makes patchelf
    # (0.18 and 0.19) add a LOAD segment that overlaps the text, and node
    # segfaults at start. Absolute NEEDED paths keep the binary layout working;
    # the glibc libraries resolve through the Nix dynamic linker's own path.
    patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
      --replace-needed libstdc++.so.6 ${stdenv.cc.cc.lib}/lib/libstdc++.so.6 \
      --replace-needed libgcc_s.so.1 ${stdenv.cc.cc.libgcc}/lib/libgcc_s.so.1 \
      $out/bin/node
  '' + ''
    runHook postInstall
  '';

  # patchShebangs then points npm, npx and corepack ("#!/usr/bin/env node") at this node.
  preFixup = ''
    export HOST_PATH=$out/bin:$HOST_PATH
  '';

  meta = {
    description = "Node.js ${version} (official release binaries)";
    homepage = "https://nodejs.org";
    license = lib.licenses.mit;
    mainProgram = "node";
    platforms = builtins.attrNames dist;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
