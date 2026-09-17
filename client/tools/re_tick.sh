#!/bin/bash
# re_tick.sh -- the RE box's own 15-minute heartbeat.
#
# The question it answers each tick is "is work already in flight?". If a job is
# running it gets out of the way; if nothing is running it advances the pipeline
# by one step and leaves the result where the next Claude session can read it.
#
# It deliberately does NOT try to prompt Claude -- a cron on this box cannot
# inject a prompt into a session. What it can do is keep the *evidence* fresh
# and current so a session never opens cold: the dumps stay in sync with the
# binaries, the standing probes re-run, and STATUS says what changed. The
# in-session loop reads STATUS and does the thinking.
#
# Install:  crontab -l | { cat; echo "*/15 * * * * /opt/srrevamp-re/re_tick.sh"; } | crontab -
set -u

ROOT=/opt/srrevamp-re
LOCK=$ROOT/lock
LOG=$ROOT/tick.log
STATUS=$ROOT/STATUS
GHIDRA=/opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless
SERVER_BIN=/var/tmp/SR_GameServer.exe
CLIENT_BIN=/mnt/silkroad/pserver/client/sro_client.exe

mkdir -p "$ROOT"
say() { echo "$(date -Is) $*" >>"$LOG"; }

# --- is work already in flight? -------------------------------------------
# flock rather than a pidfile: a killed job releases it automatically, so the
# loop cannot wedge itself the way a stale pidfile would.
exec 9>"$LOCK"
if ! flock -n 9; then
  say "busy - a job is already running, leaving it alone"
  exit 0
fi

# Never let a tick run while a render holds the GPU; renders are the one thing
# that must not be disturbed. Match on a pattern this script does not contain,
# or pgrep finds itself (that trap has cost this project time twice).
if pgrep -f "[G]odot_v4.2.2" >/dev/null 2>&1; then
  say "a render is running - standing down this tick"
  exit 0
fi

started=$(date -Is)

# --- step 1: are the dumps still current? ---------------------------------
# A dump is stale if its binary is newer than the DONE marker. Re-dumping is
# ~5 minutes and only happens when the binary actually changed.
# The binary is a fixed artifact and never changes, so "is the binary newer
# than the dump" could only ever answer no -- which is why this reported
# rebuilt_dumps=0 for every tick of a session that applied a hundred names.
# What DOES change is the Ghidra project: ApplyRecoveredNames.java writes names
# into it and nowhere else, so the project's newest file is the only signal
# that a dump has fallen behind. Checked as of 2026-09-17 -- the same defect as
# "the metric that could not move", from the other end.
projstamp() { find "$1" -type f -printf "%T@\n" 2>/dev/null | sort -rn | head -1 | cut -d. -f1; }

redump() { # <name> <project> <program> <binary> <outdir>
  local name=$1 proj=$2 prog=$3 bin=$4 out=$5
  local projdir=/home/ghidra/$proj stamp=$out/PROJSTAMP cur prev
  cur=$(projstamp "$projdir"); cur=${cur:-0}
  prev=$(cat "$stamp" 2>/dev/null); prev=${prev:-0}
  if [ ! -f "$out/DONE" ] || [ "$bin" -nt "$out/DONE" ] || [ "$cur" -gt "$prev" ]; then
    say "$name dump stale (binary or project changed) - rebuilding"
    rm -rf "$out"
    su ghidra -s /bin/bash -c \
      "$GHIDRA /home/ghidra/$proj $prog -readOnly -noanalysis -process $(basename "$bin") \
       -scriptPath /var/tmp -postScript DecompAll.java $out 30 2000" >>"$LOG" 2>&1
    say "$name dump rebuilt: $(cat "$out/DONE" 2>/dev/null)"
    # Record the stamp taken BEFORE the run, written after it.
    #
    # Both halves matter and an earlier version got the second one wrong. It
    # re-measured here, which does stop analyzeHeadless's own -readOnly touch
    # from triggering a rebuild every tick -- but it also SWALLOWS any rename
    # applied while the dump was building. The post-run stamp includes that
    # change, so the next tick compares equal and skips, and the dump stays
    # stale with nothing reporting it. That happened on 2026-09-17: 138 owner
    # corrections landed during a build and the next tick saw nothing to do.
    #
    # Writing the pre-run value keeps the touch out (it is not in $cur) and
    # lets a real mid-run change win next tick (its mtime is newer than $cur).
    echo "$cur" >"$stamp"
    return 0
  fi
  return 1
}
redump server re_server SR_GameServer_re "$SERVER_BIN" /var/tmp/decomp_server && rebuilt=1
redump client re_client sro_client_re "$CLIENT_BIN" /var/tmp/decomp_client && rebuilt=1

# --- step 2: re-run the standing probes -----------------------------------
# Cheap greps over the dumps whose answers the open ledger items turn on. They
# cost under a second and mean a session opens with current evidence instead of
# re-deriving it.
PROBES=$ROOT/probes.txt
{
  echo "# standing probes, refreshed $(date -Is)"
  for d in /var/tmp/decomp_server /var/tmp/decomp_client; do
    [ -f "$d/DONE" ] || continue
    echo "== $d: $(cat "$d/DONE")"
  done
  echo
  echo "== exp-gain virtual slot 0x170 call sites (monster exp, open item 1)"
  /var/tmp/infn.sh '\+ 0x170\)\)\(' /var/tmp/decomp_server 2>/dev/null | head -20
  echo
  echo "== skill-point adder slot 0x174 call sites (negative delta = a spender)"
  /var/tmp/infn.sh '\+ 0x174\)\)\(' /var/tmp/decomp_server 2>/dev/null | head -20
  echo
  echo "== ParamKeeper stat-hub callers (HP/MP base, open item 2)"
  /var/tmp/infn.sh 'FUN_004b3510\(0,' /var/tmp/decomp_server 2>/dev/null | head -20
} >"$PROBES" 2>&1

# --- step 3: say what happened --------------------------------------------
{
  echo "last_tick=$started"
  echo "finished=$(date -Is)"
  echo "rebuilt_dumps=${rebuilt:-0}"
  echo "server_dump=$(cat /var/tmp/decomp_server/DONE 2>/dev/null || echo MISSING)"
  echo "client_dump=$(cat /var/tmp/decomp_client/DONE 2>/dev/null || echo MISSING)"
  echo "probes=$PROBES"
  echo "disk_free=$(df -h / | awk 'NR==2 {print $4}')"
} >"$STATUS"

say "tick done (rebuilt=${rebuilt:-0}, disk $(df -h / | awk 'NR==2 {print $4}') free)"
