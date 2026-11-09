#!/bin/bash
# The multi-process load test (round 869 lane W2, docs/protocol/game_worlds.md
# 12.7, OURS): a front, the open world's host and N instance hosts on one
# machine, on a throwaway PostgreSQL database (never a live one), with the
# synthetic game cmd/loadworld writes; partybot -mode instload drives P
# parties of 4 into instances. Per process it records the CPU seconds used
# during the fight (from /proc), and each world host logs its instance ticks
# every 10 s ("world load" lines).
#
# usage: run.sh DSN DIR N PARTIES [FIGHT]
#   DSN      the throwaway database (its tables are created on first start)
#   DIR      a work dir holding bin/opensro-server, bin/partybot and load/
#            (cmd/loadworld -out DIR/load)
#   N        instance hosts (1..3 on the lane's ports)
#   PARTIES  parties of 4
#   FIGHT    how long they fight (default 120s)
# Ports: 17721 the front, 17722 the open world's relay, 17723 its own client
# listener, 17724.. the instance hosts' relays.
set -u
DSN=$1; DIR=$2; N=$3; P=$4; FIGHT=${5:-120s}
RUN=$DIR/run-n$N-p$P
rm -rf "$RUN"; mkdir -p "$RUN"
L=$DIR/load
PREFIX=ld$N$(printf %03d $P)
GMS=$(for p in $(seq 0 $((P-1))); do for c in a b c d; do printf '%s%03d%s,' "$PREFIX" $p $c; done; done)
export OPENSRO_RELAY_SECRET=load-test-secret OPENSRO_PG_MAX_CONNS=10
export OPENSRO_MONSTER_AI=1 OPENSRO_MONSTER_STRIKE_PUSH=1 OPENSRO_MONSTER_SPAWN_PUSH=1 OPENSRO_MONSTER_BATTLE=1 OPENSRO_MONSTER_AGGRO=1
psql "$DSN" -qc "TRUNCATE world_hosts, world_instances, world_instance_members, world_presence, world_returns" 2>/dev/null
COMMON="-postgres-dsn $DSN -gameworld-dir $L/gw -nest-db-dir $L/nest -monsters-csv $L/monsters.csv -chargen-csv $L/chargen.csv
 -leveldata-csv $L/leveldata.csv -gm-accounts $GMS -trust-client-positions -metrics-addr 127.0.0.1:0 -load-report 10s"
start() { # name args...
  local name=$1; shift
  nohup "$DIR/bin/opensro-server" $COMMON "$@" > "$RUN/$name.log" 2>&1 &
  echo $! > "$RUN/$name.pid"
}
wait_log() { # name text
  for i in $(seq 1 600); do grep -q "$2" "$RUN/$1.log" && return 0; sleep 0.1; done
  echo "$1: no '$2'"; tail -20 "$RUN/$1.log"; return 1
}
start home -role world -world-layers open -host-id home -relay-listen 127.0.0.1:17722 -addr 127.0.0.1:17723
wait_log home "cluster joined" || exit 1
for i in $(seq 1 $N); do
  start w$i -role world -world-layers instances -host-id w$i -relay-listen 127.0.0.1:$((17723+i))
done
for i in $(seq 1 $N); do wait_log w$i "cluster joined" || exit 1; done
start front -role front -host-id front -addr 127.0.0.1:17721
wait_log front "front ready" || exit 1
cpu() { # pid -> utime+stime ticks
  awk '{print $14+$15}' /proc/$1/stat
}
procs="home front $(for i in $(seq 1 $N); do printf 'w%d ' $i; done)"
"$DIR/bin/partybot" -mode instload -addr 127.0.0.1:17721 -prefix $PREFIX -level 40 -parties $P -duration $FIGHT \
  > "$RUN/bots.log" 2>&1 &
BOTS=$!
# The fight's CPU window: from FIGHT START to FIGHT END.
for i in $(seq 1 3000); do grep -q "FIGHT START" "$RUN/bots.log" && break; kill -0 $BOTS 2>/dev/null || break; sleep 0.2; done
T0=$(date +%s.%N)
for p in $procs; do echo "$p $(cpu $(cat $RUN/$p.pid))" ; done > "$RUN/cpu0"
LOAD0=$(cut -d' ' -f1-3 /proc/loadavg)
wait $BOTS
T1=$(date +%s.%N)
for p in $procs; do echo "$p $(cpu $(cat $RUN/$p.pid))" ; done > "$RUN/cpu1"
echo "bots $(awk '{print $14+$15}' /proc/self/stat 2>/dev/null || echo 0)" > /dev/null
LOAD1=$(cut -d' ' -f1-3 /proc/loadavg)
HZ=$(getconf CLK_TCK)
{
  W=$(awk -v a=$T0 -v b=$T1 'BEGIN{printf "%.1f", b-a}')
  echo "N=$N parties=$P fight=$FIGHT window=${W}s loadavg_start=$LOAD0 loadavg_end=$LOAD1"
  join "$RUN/cpu0" "$RUN/cpu1" | awk -v hz=$HZ -v w=$W '{printf "cpu %s %.2f cores (%.1f s)\n", $1, ($3-$2)/hz/w, ($3-$2)/hz}'
  grep SUMMARY "$RUN/bots.log"
  grep -c "^ENTRY " "$RUN/bots.log" | sed 's/^/entries /'
  for i in $(seq 1 $N); do grep "world load" "$RUN/w$i.log" | tail -4 | sed "s/^/w$i /"; done
  grep "world load" "$RUN/home.log" | tail -2 | sed 's/^/home /'
  psql "$DSN" -tAc "SELECT host, count(*) FROM world_instances WHERE state='open' AND world <> 1 GROUP BY host ORDER BY host" | sed 's/^/instances /'
  for p in $procs; do echo "rss $p $(awk '/VmRSS/{print $2}' /proc/$(cat $RUN/$p.pid)/status) kB"; done
} | tee "$RUN/result.txt"
for p in $procs; do kill $(cat $RUN/$p.pid) 2>/dev/null; done
sleep 1
for p in $procs; do kill -9 $(cat $RUN/$p.pid) 2>/dev/null; done
