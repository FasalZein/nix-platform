# Renders one env template (1Password references) into its rendered env file
# through the saved 2password service account. Used by the secrets-render
# login agent in modules/darwin.nix; `secrets-refresh` restarts that agent.
#
# RENDER_TEMPLATE  env template (references only)
# RENDER_TARGET    rendered env file; its folder becomes owner-only and is
#                  excluded from Time Machine
#
# The file is replaced atomically with mode 0400. A failed render keeps the
# last good file. The log (stdout) holds names, counts and errors, never a value:
# with a service account, 2password suppresses op's error details.

template=${RENDER_TEMPLATE:?}
target=${RENDER_TARGET:?}
# Bounded retries cover a network that is not up yet at login.
attempts=${RENDER_ATTEMPTS:-4}
retry_seconds=${RENDER_RETRY_SECONDS:-30}

log() { printf '%s secrets-render: %s\n' "$(date -u +%FT%TZ)" "$*"; }

umask 077
dir=$(dirname "$target")
mkdir -p "$dir"
chmod 700 "$dir"
# Sticky exclusion (an extended attribute on the folder); needs no sudo.
if ! tmutil isexcluded "$dir" | grep -q '^\[Excluded\]'; then
  tmutil addexclusion "$dir" || log "warning: Time Machine exclusion failed for $dir"
fi

names_re='^[A-Za-z_][A-Za-z0-9_]*'
expected=$(grep -cE "$names_re=op://" "$template" || true)
# 2password writes through a temporary folder of its own that it leaves
# behind (0.2.0), so it renders inside a scratch folder that is always removed.
scratch=$(mktemp -d "$dir/.render.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
tmp=$scratch/$(basename "$target")

describe_last_good() {
  if [ -f "$target" ]; then
    echo "last good file kept ($(grep -cE "$names_re=" "$target" || true) variables, $(stat -f '%Sm' -t '%FT%T%z' "$target"))"
  else
    echo "no rendered file yet"
  fi
}

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if err=$(2password env resolve "$template" --output "$tmp" 2>&1 >/dev/null); then
    # Every reference must give a non-empty value.
    rendered=$(grep -cE "$names_re=\".+\"$" "$tmp" || true)
    if [ "$rendered" = "$expected" ]; then
      chmod 400 "$tmp"
      mv -f "$tmp" "$target"
      log "rendered $rendered of $expected variables into $target (attempt $attempt)"
      exit 0
    fi
    err="only $rendered of $expected variables have a value"
  fi
  log "attempt $attempt of $attempts failed: $err"
  if ((attempt < attempts)); then sleep "$retry_seconds"; fi
done
log "render failed; $(describe_last_good)"
exit 1
