#!/bin/bash
# infn.sh <regex> [dir] -- list which decompiled functions contain a pattern.
# The dump marks each function with "===FUNC=== <entry> <name> size=", so we
# track the most recent header and report it whenever the pattern matches.
PAT="$1"; DIR="${2:-/var/tmp/decomp_server}"
awk -v pat="$PAT" '
  /^===FUNC=== / { fn=$2" "$3; next }
  $0 ~ pat { if (!(fn in seen)) { seen[fn]=1; print FILENAME"\t"fn } }
' "$DIR"/funcs_*.c
