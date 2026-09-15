#!/bin/bash
# Run a full attribute-then-dump pass over both binaries, the two lanes in
# parallel.
#
# The lanes are independent: separate Ghidra projects, separate locks, separate
# output directories. Only the steps WITHIN a lane are ordered, because each
# reads what the last one wrote -- propagate changes the program, the report
# measures it, the dump renders it to C. Running the server lane and the client
# lane one after the other, as an earlier version of this did, pays twice for
# nothing.
#
# What must never be concurrent, and why:
#   - two writers on one project : the second cannot take <Project>.lock and
#     refuses to open it. Loud, immediate, harmless.
#   - a reader while a writer runs: NOT an error, and that is the danger. You
#     read the program mid-mutation and get numbers that look fine and are not.
#   - two dumps to one output dir: the shards interleave and the DONE marker
#     lies, corrupting the artifact every later grep depends on.
#
# Usage: re_pass.sh [propagate]    ("propagate" also runs PropagateModules)
set -u
G=/opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless
PROP="${1:-}"

lane() {
  local name="$1" proj="$2" prog="$3" out="$4" shards="$5"
  local base="/home/ghidra/$proj -process $prog -noanalysis -scriptPath /var/tmp"
  {
    if [ "$PROP" = "propagate" ]; then
      echo "### $name propagate"
      $G $base -postScript PropagateModules.java apply
    fi
    echo "### $name report"
    $G $base -postScript SymbolReport.java 0
    echo "### $name dump"
    $G $base -postScript DecompAll.java "$out" "$shards"
    echo "### $name lane done"
  } > "/var/tmp/re_pass_$name.log" 2>&1
}

lane server "re_server SR_GameServer_re" SR_GameServer.exe /var/tmp/decomp_server 16 &
SPID=$!
lane client "re_client sro_client_re"    sro_client.exe    /var/tmp/decomp_client 20 &
CPID=$!

# Wait on both, and report each lane's exit status rather than the last one's.
wait $SPID; SRC=$?
wait $CPID; CRC=$?
echo "===RE_PASS_DONE=== server=$SRC client=$CRC"
[ $SRC -eq 0 ] && [ $CRC -eq 0 ]
