#!/bin/bash
# efp_dump_diff.sh -- checks the Go and GDScript .efp readers agree, value for
# value, over the player's Particles.pk2 on the render box. Each prints one
# "<md5 of the canonical dump> <path>" line per decoded file (Go:
# `efpcensus -dump`, server/internal/efp/dump.go; GDScript: tools/efp_dump.gd);
# any difference in any field of any node changes a hash. Exit 0 when the two
# lists are identical.
#
#   RENDER_DIR=/opt/srrevamp-client-<lane> GODOT_LOCK=/var/tmp/<lane>/lock \
#     client/tools/efp_dump_diff.sh
#
# Ship the client first (remote_godot.sh check). To find where one file's
# dumps part, compare `efpcensus -dumpone <path>` with
# `efp_dump.gd -- --pk2=... --one=<path>`.
set -euo pipefail
RENDER_HOST="${RENDER_HOST:-root@192.168.5.78}"
PK2="${PK2:-/opt/sro-files/client/Particles.pk2}"
WORK="${WORK:-/var/tmp/efp-dump-diff}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tar czf - -C "$repo_root" server | ssh "$RENDER_HOST" "rm -rf '$WORK' && mkdir -p '$WORK' && tar xzf - -C '$WORK'"
ssh -n "$RENDER_HOST" "cd '$WORK/server' && go run ./cmd/efpcensus -pk2 '$PK2' -dump | sort > '$WORK/go.txt'"
"$repo_root/client/tools/remote_godot.sh" script res://tools/efp_dump.gd -- --pk2="$PK2" \
  | grep -E '^[0-9a-f]{32} ' | sort > "${TMPDIR:-/tmp}/efp_gd.txt"
ssh -n "$RENDER_HOST" "cat '$WORK/go.txt'" > "${TMPDIR:-/tmp}/efp_go.txt"
ssh -n "$RENDER_HOST" "rm -rf '$WORK'"
echo "go: $(wc -l < "${TMPDIR:-/tmp}/efp_go.txt") files, gdscript: $(wc -l < "${TMPDIR:-/tmp}/efp_gd.txt") files"
if diff "${TMPDIR:-/tmp}/efp_go.txt" "${TMPDIR:-/tmp}/efp_gd.txt" > "${TMPDIR:-/tmp}/efp_diff.txt"; then
  echo "IDENTICAL"
else
  echo "DIFFER: $(grep -c '^<' "${TMPDIR:-/tmp}/efp_diff.txt") file(s)"
  head -20 "${TMPDIR:-/tmp}/efp_diff.txt"
  exit 1
fi
