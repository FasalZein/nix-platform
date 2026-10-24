# Renders env templates (1Password references) into their rendered env files
# through the saved 2password service account. Used by the secrets-render
# login agent in modules/darwin.nix; `secrets-refresh` restarts that agent.
#
# Usage: secrets-render TEMPLATE TARGET [TEMPLATE TARGET ...]
#   TEMPLATE  env template (references only)
#   TARGET    rendered env file; its folder becomes owner-only and is
#             excluded from Time Machine
#
# Each target is replaced atomically with mode 0400. A failed render keeps the
# last good file of that target; the other targets still render. One
# `2password env resolve` call per template and attempt. The log (stdout) holds
# names, counts and errors, never a value: with a service account, 2password
# suppresses op's error details. The last log line is a summary of the run.

if (($# == 0 || $# % 2 != 0)); then
  echo "usage: secrets-render TEMPLATE TARGET [TEMPLATE TARGET ...]" >&2
  exit 2
fi
templates=()
targets=()
while (($#)); do
  templates+=("$1")
  targets+=("$2")
  shift 2
done
# Bounded retries cover a network that is not up yet at login.
attempts=${RENDER_ATTEMPTS:-4}
retry_seconds=${RENDER_RETRY_SECONDS:-30}

log() { printf '%s secrets-render: %s\n' "$(date -u +%FT%TZ)" "$*"; }

umask 077
names_re='^[A-Za-z_][A-Za-z0-9_]*'
scratches=()
trap 'rm -rf "${scratches[@]}"' EXIT

for target in "${targets[@]}"; do
  dir=$(dirname "$target")
  mkdir -p "$dir"
  chmod 700 "$dir"
  # Sticky exclusion (an extended attribute on the folder); needs no sudo.
  if ! tmutil isexcluded "$dir" | grep -q '^\[Excluded\]'; then
    tmutil addexclusion "$dir" || log "warning: Time Machine exclusion failed for $dir"
  fi
done

describe_last_good() {
  if [ -f "$1" ]; then
    echo "last good file kept ($(grep -cE "$names_re=" "$1" || true) variables, $(stat -f '%Sm' -t '%FT%T%z' "$1"))"
  else
    echo "no rendered file yet"
  fi
}

# Renders pair $1 once. Returns non-zero and sets err when it fails.
render_one() {
  local template=${templates[$1]} target=${targets[$1]} expected rendered scratch tmp
  expected=$(grep -cE "$names_re=op://" "$template" || true)
  # 2password writes through a temporary folder of its own that it leaves
  # behind (0.2.0), so it renders inside a scratch folder that is always removed.
  scratch=$(mktemp -d "$(dirname "$target")/.render.XXXXXX")
  scratches+=("$scratch")
  tmp=$scratch/$(basename "$target")
  if ! err=$(2password env resolve "$template" --output "$tmp" 2>&1 >/dev/null); then
    return 1
  fi
  # Every reference must give a non-empty value.
  rendered=$(grep -cE "$names_re=\".+\"$" "$tmp" || true)
  if [ "$rendered" != "$expected" ]; then
    err="only $rendered of $expected variables have a value"
    return 1
  fi
  chmod 400 "$tmp"
  mv -f "$tmp" "$target"
  log "rendered $rendered of $expected variables into $target (attempt $attempt)"
}

pending=("${!targets[@]}")
for ((attempt = 1; attempt <= attempts; attempt++)); do
  failed=()
  for i in "${pending[@]}"; do
    if ! render_one "$i"; then
      log "attempt $attempt of $attempts failed for ${targets[$i]}: $err"
      failed+=("$i")
    fi
  done
  pending=("${failed[@]}")
  ((${#pending[@]} == 0)) && break
  if ((attempt < attempts)); then sleep "$retry_seconds"; fi
done

for i in "${pending[@]}"; do
  log "render failed for ${targets[$i]}; $(describe_last_good "${targets[$i]}")"
done
total=${#targets[@]}
log "done: $((total - ${#pending[@]})) of $total files rendered"
((${#pending[@]} == 0))
