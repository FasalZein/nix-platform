# Truncates each log file in place when it is larger than a byte limit; keeps
# no old copy. In place, so a process that writes to it through an open
# launchd StandardOutPath handle keeps working: launchd opens that file with
# O_APPEND (lsof flag AP, checked 2026-11-02), so the next write lands at the
# new end, with no sparse gap. Usage: log-size-cap <max-bytes> <file>...
{ writeShellApplication, coreutils }:

writeShellApplication {
  name = "log-size-cap";
  runtimeInputs = [ coreutils ];
  text = ''
    if [ $# -lt 2 ]; then
      echo "usage: log-size-cap <max-bytes> <file>..." >&2
      exit 64
    fi
    max=$1
    shift
    for file in "$@"; do
      [ -f "$file" ] || continue
      size=$(stat -c %s "$file")
      if [ "$size" -gt "$max" ]; then
        truncate -s 0 "$file"
        # One line per truncation, into the file itself, so a reader sees the gap.
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) log-size-cap: truncated $file at $size bytes (limit $max)" >> "$file"
      fi
    done
  '';
}
