#!/usr/bin/env bash
# Regenerates packages/ghui/package-lock.json and its npmDeps hash in
# default.nix for the ghui version and src in default.nix. Run after a
# version bump: packages/ghui/update-lock.sh, then nix flake check.
# npm resolves version ranges against the registry on the day it runs.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d /tmp/ghui-lock.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
tools() { nix shell "$repo#nodejs" --inputs-from "$repo" nixpkgs#jq -c "$@"; }

src=$(nix build --no-link --print-out-paths "$repo#ghui.src")
cp "$src/package.json" "$tmp/"
cp -R "$src/packages" "$tmp/"
chmod -R u+w "$tmp"

# npm does not read workspace:*; * resolves to the same workspace package.
tools jq '.devDependencies["@ghui/keymap"] = "*"' "$src/package.json" > "$tmp/package.json"
(cd "$tmp" && tools npm install --package-lock-only --ignore-scripts --no-audit --no-fund)
# Put workspace:* back in the root entry, as nixpkgs' ghui lock has it.
tools jq '.packages[""].devDependencies["@ghui/keymap"] = "workspace:*"' \
  "$tmp/package-lock.json" > "$here/package-lock.json"

# The npmDeps hash: build with a fake hash and take the hash Nix reports.
nix_file="$here/default.nix"
marker='; # npmDeps hash'
grep -q "$marker" "$nix_file" || { echo "update-lock.sh: no '$marker' line in $nix_file" >&2; exit 1; }
set_hash() { sed -i.bak "s|hash = \"[^\"]*\"$marker|hash = \"$1\"$marker|" "$nix_file" && rm "$nix_file.bak"; }
set_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
got=$(nix build --no-link "$repo#ghui.npmDeps" 2>&1 | sed -n 's/^ *got: *//p' || true)
[ -n "$got" ] || { echo "update-lock.sh: nix build of ghui.npmDeps reported no hash" >&2; exit 1; }
set_hash "$got"
echo "update-lock.sh: package-lock.json written, npmDeps hash $got"
