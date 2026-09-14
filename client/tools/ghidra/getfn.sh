#!/bin/bash
# getfn.sh <entryAddr> [dir] -- print one decompiled function body from the dump.
ADDR="$1"; DIR="${2:-/var/tmp/decomp_server}"
SHARD=$(awk -v a="$ADDR" -F"\t" "\$1==a {print \$4}" "$DIR/index.txt")
[ -z "$SHARD" ] && { echo "no such function: $ADDR"; exit 1; }
awk -v a="$ADDR" '
  /^===FUNC=== / { p = ($2==a) }
  p { print }
' "$DIR/$SHARD"
