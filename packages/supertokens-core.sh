#!/bin/sh
# Run SuperTokens core in the foreground (for launchd), from a read-only store
# install. Usage: supertokens-core <config.yaml> [core option=value ...]
# The core writes .started/, logs/ and webserver-temp/ into its install
# directory, so we build a writable install directory in the state directory:
# symlinks to the store for the jars, real directories for the rest.
# The command line matches the "supertokens start" CLI (cli StartHandler),
# without ee/ (see supertokens.nix).
# Set by the Nix wrapper: SUPERTOKENS_HOME (store install), JAVA.
set -eu

if [ $# -lt 1 ]; then
  echo "usage: supertokens-core <config.yaml> [option=value ...]" >&2
  exit 64
fi
config=$1
shift
case $config in /*) ;; *) config=$PWD/$config ;; esac
[ -r "$config" ] || { echo "supertokens-core: cannot read $config" >&2; exit 66; }

state=${SUPERTOKENS_STATE_DIR:-$HOME/.local/state/nix-platform/supertokens}
install=$state/install
mkdir -p "$install/.started" "$install/logs" "$install/webserver-temp" "$state/tmp"
for entry in cli core plugin plugin-interface version.yaml; do
  ln -sfn "$SUPERTOKENS_HOME/$entry" "$install/$entry"
done

# JNA unpacks libargon2 and its dispatch library before it loads them. On
# macOS it ignores java.io.tmpdir and uses ~/Library/Caches/JNA unless
# jna.tmpdir is set.
exec "$JAVA" \
  -Djava.security.egd=file:/dev/urandom \
  -Djava.io.tmpdir="$state/tmp" \
  -Djna.tmpdir="$state/tmp" \
  -classpath "$install/core/*:$install/plugin-interface/*" \
  io.supertokens.Main "$install/" \
  configFile="$config" \
  tempDirLocation="$install/webserver-temp/" \
  "$@"
