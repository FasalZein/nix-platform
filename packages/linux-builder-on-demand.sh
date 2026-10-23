# Starts the nix-darwin linux-builder VM on first use and stops it when idle
# (owner decision 2026-10-24). The VM itself stays unchanged.
#
#   wake HOST PORT  ssh ProxyCommand for Host linux-builder. Starts the launchd
#                   job when the guest sshd does not answer, waits for the SSH
#                   banner, then relays stdin/stdout to HOST:PORT.
#   reap            Run by a launchd timer. Stops the job after LB_IDLE_MINUTES
#                   without an established TCP connection to the SSH port.
#
# The LB_* variables have the production values as defaults; the isolated
# test overrides them to drive a fake builder job in the user launchd domain.

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
service="${LB_SERVICE:-system/org.nixos.linux-builder}"
stamp="${LB_STAMP:-/var/lib/linux-builder/last-used}"
port="${LB_PORT:-31022}"
idle_minutes="${LB_IDLE_MINUTES:-30}"
boot_timeout_seconds="${LB_BOOT_TIMEOUT:-180}"
kickstart_every_seconds=10

# QEMU accepts on the forwarded port before the guest sshd runs and then closes
# the connection, so an open port is not enough: wait for "SSH-".
sshd_ready() {
  local banner=""
  exec 3<>"/dev/tcp/$1/$2" || return 1
  IFS= read -r -t 3 -n 4 banner <&3 || true
  exec 3<&- 3>&-
  [ "$banner" = "SSH-" ]
}

wake() {
  local host=$1 p=$2 last_kick=$(( -kickstart_every_seconds ))
  # Gives a fresh VM the full idle period. Fails harmlessly for non-root users.
  touch "$stamp" 2>/dev/null || true
  until sshd_ready "$host" "$p" 2>/dev/null; do
    if (( SECONDS >= boot_timeout_seconds )); then
      echo "linux-builder-on-demand: no sshd on $host:$p after ${boot_timeout_seconds}s" >&2
      exit 1
    fi
    # Repeated kickstart is a no-op while the job runs; it also restarts a VM
    # that the reaper stopped while this call waited.
    if (( SECONDS - last_kick >= kickstart_every_seconds )); then
      last_kick=$SECONDS
      launchctl kickstart "$service" >/dev/null 2>&1 ||
        echo "linux-builder-on-demand: cannot start $service (root only); run: sudo launchctl kickstart $service" >&2
    fi
    sleep 1
  done
  exec nc "$host" "$p"
}

reap() {
  # No pipe into grep -q: with pipefail its early exit would fail the pipe.
  local job
  job=$(launchctl print "$service" 2>/dev/null) || exit 0
  [[ $job == *"state = running"* ]] || exit 0
  if lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED >/dev/null 2>&1; then
    touch "$stamp"
    exit 0
  fi
  if [ ! -e "$stamp" ]; then
    touch "$stamp"
    exit 0
  fi
  local idle_seconds
  idle_seconds=$(( $(date +%s) - $(stat -f %m "$stamp") ))
  if (( idle_seconds >= idle_minutes * 60 )); then
    echo "$(date '+%F %T') idle ${idle_seconds}s: stopping $service"
    # launchd then kills the rest of the job's process group, QEMU included.
    launchctl kill SIGTERM "$service"
  fi
}

case "${1:-}" in
  wake) wake "$2" "$3" ;;
  reap) reap ;;
  *) echo "usage: linux-builder-on-demand wake HOST PORT | reap" >&2; exit 2 ;;
esac
