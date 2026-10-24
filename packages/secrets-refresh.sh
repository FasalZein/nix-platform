# Secrets refresh: restart the secrets-render login agent (modules/darwin.nix),
# wait for it to finish, and print its last log line. No prompt: the agent
# uses the saved service account. Exits non-zero when the render failed.
# After a good render it restarts the agents that read a rendered env file only
# at start (9router), so a changed value reaches them (owner decision 2026-10-24).

label=${SECRETS_RENDER_LABEL:-org.nixos.secrets-render}
log=${SECRETS_RENDER_LOG:-$HOME/Library/Logs/secrets-render.log}
service="gui/$(id -u)/$label"
# The agent retries for up to about 2 minutes when the network is down.
max_wait_seconds=300

launchctl kickstart -k "$service"
state=running
for ((i = 0; i < max_wait_seconds; i++)); do
  sleep 1
  info=$(launchctl print "$service")
  state=$(awk '$1 == "state" { print $3; exit }' <<<"$info")
  [ "$state" = running ] || break
done
if [ "$state" = running ]; then
  echo "secrets-refresh: $label still running after ${max_wait_seconds}s; see $log" >&2
  exit 1
fi
tail -n 1 "$log"
code=$(awk -F' = ' '/last exit code/ { print $2; exit }' <<<"$info")
[ "$code" = 0 ] || exit 1
read -r -a restart_labels <<<"${SECRETS_REFRESH_RESTART-org.nixos.9router}"
for l in "${restart_labels[@]}"; do
  if launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$l"
    echo "secrets-refresh: restarted $l"
  fi
done
