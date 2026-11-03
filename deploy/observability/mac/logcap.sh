#!/bin/bash
# Caps the logs on OpenSRO's prod host that nothing else rotates (round 859).
# Run hourly by the launch agent com.opensro.logcap (com.opensro.logcap.plist).
#
# - The game server rotates its own logs/opensro.log (-log-file, round 858).
# - launchd holds logs/server.log (the server's stdout/stderr: crash traces only)
#   and observability/alloy.log open in APPEND mode, so a copy then truncate is
#   safe: the writer keeps writing at the new end. A file over MAX_MB is
#   gzipped to <file>.1.gz (older copies shift up, KEEP kept) and emptied.
# - Compressed copies older than PRUNE_DAYS are deleted, including the server's
#   own opensro.log.N.gz beyond its count and the one-off server.log.pre-*.gz.
set -u
MAX_MB=${MAX_MB:-50}
KEEP=${KEEP:-5}
PRUNE_DAYS=${PRUNE_DAYS:-90}
O="$HOME/opensro"

cap() {
  local f=$1 size i
  [ -f "$f" ] || return 0
  size=$(stat -f%z "$f")
  [ "$size" -ge $((MAX_MB * 1024 * 1024)) ] || return 0
  for ((i = KEEP - 1; i >= 1; i--)); do
    [ -f "$f.$i.gz" ] && mv -f "$f.$i.gz" "$f.$((i + 1)).gz"
  done
  gzip -c "$f" > "$f.1.gz.tmp" && mv -f "$f.1.gz.tmp" "$f.1.gz" && : > "$f"
  echo "$(date '+%F %T') capped $f ($size bytes)"
}

cap "$O/logs/server.log"
cap "$O/observability/alloy.log"
cap "$O/observability/logcap.log"

find "$O/logs" "$O/observability" -maxdepth 1 -name '*.gz' -mtime +"$PRUNE_DAYS" -print -delete 2>/dev/null \
  | sed "s/^/$(date '+%F %T') pruned /"

# A plain warning when the disk gets tight (the dashboards alert on it too).
avail=$(df -k "$O" | awk 'NR==2 {print int($4 / 1024 / 1024)}')
[ "$avail" -lt 50 ] && echo "$(date '+%F %T') WARNING only ${avail} GB free on $(df -k "$O" | awk 'NR==2 {print $9}')"
exit 0
