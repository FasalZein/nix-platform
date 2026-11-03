# Appends one memory sample line to a log file; run every 30 s by the
# memory-sampler launchd agent in modules/darwin.nix. Line format:
#   <local time> free=<memory_pressure free %> swap_used=<MB> top_rss=<name>[<pid>]=<MB>,... (10 processes)
# Size cap: before it writes, the script renames a log larger than max-bytes
# to <log>.1 (one old copy, replaced each time), so a reader always has at
# least max-bytes of history. Rename instead of the in-place truncate of
# log-size-cap: no process holds this file open between runs, and a truncate
# would empty the history at the moment it may be needed.
# memory_pressure, sysctl and ps are macOS system tools, found on PATH.
# Usage: memory-sampler <log-file> <max-bytes>
{ writeShellApplication, coreutils, gawk }:

writeShellApplication {
  name = "memory-sampler";
  runtimeInputs = [ coreutils gawk ];
  text = ''
    if [ $# -ne 2 ]; then
      echo "usage: memory-sampler <log-file> <max-bytes>" >&2
      exit 64
    fi
    log=$1
    max=$2
    if [ -f "$log" ] && [ "$(stat -c %s "$log")" -gt "$max" ]; then
      mv -f "$log" "$log.1"
    fi
    # "System-wide memory free percentage: 77%" -> 77%
    free=$(memory_pressure -Q | awk -F': ' '/free percentage/ { print $2 }')
    # "total = 4096.00M  used = 2615.06M  free = ..." -> 2615.06M
    swap=$(sysctl -n vm.swapusage | awk '{ for (i = 1; i < NF; i++) if ($i == "used") print $(i + 2) }')
    # RSS in KiB; comm is the full path, possibly with spaces; keep its base name.
    # awk takes the first 10 lines but reads all input: `head` would close the
    # pipe early, and the SIGPIPE of sort fails the script under pipefail.
    top=$(ps -Ao rss=,pid=,comm= | sort -rn | awk 'NR <= 10 {
      rss = $1; pid = $2
      $1 = ""; $2 = ""; sub(/^ +/, "")
      n = split($0, part, "/")
      printf "%s%s[%s]=%dM", (NR > 1 ? "," : ""), part[n], pid, rss / 1024
    }')
    echo "$(date +%Y-%m-%dT%H:%M:%S%z) free=$free swap_used=$swap top_rss=$top" >> "$log"
  '';
}
