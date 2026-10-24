# Waits a bounded time for a rendered env file, exports its NAME="value"
# lines, then runs the command. Used by the 9router launchd agent in
# modules/darwin.nix. The parser is secrets/load-shell-secrets.zsh (inserted by
# env-file-exec.nix), so values keep $, backticks and quotes literally, and a
# name that is already set keeps its value. The log (stdout) holds the file
# path and wait time, never a value.
#
# Usage: env-file-exec ENV_FILE MAX_WAIT_SECONDS COMMAND [ARGS...]

log() { print -r -- "$(date -u +%FT%TZ) env-file-exec: $*"; }

if (( $# < 3 )) || [[ $2 != <-> ]]; then
  print -u2 "usage: env-file-exec ENV_FILE MAX_WAIT_SECONDS COMMAND [ARGS...]"
  exit 2
fi
env_file=$1 max_wait=$2
shift 2

integer waited=0
if [[ ! -r $env_file ]]; then
  log "waiting up to ${max_wait}s for $env_file"
  while [[ ! -r $env_file ]] && (( waited < max_wait )); do
    sleep 1
    (( waited++ ))
  done
fi
if [[ ! -r $env_file ]]; then
  log "error: $env_file missing after ${max_wait}s; not starting $1"
  exit 1
fi
log "loading $env_file (waited ${waited}s); starting $1"
@loader@
exec "$@"
