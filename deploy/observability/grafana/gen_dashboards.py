#!/usr/bin/env python3
"""Writes the OpenSRO Grafana dashboards (round 858) into dashboards/.

    python3 deploy/observability/grafana/gen_dashboards.py

The JSON files are what Grafana provisions; this script is their source, so
a change to a panel is made here and the files regenerated. Datasource uids
are the provisioned ones: Prometheus "prometheus", Loki "loki".
"""
import json
import os

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")

SEL = 'job="opensro-server", instance=~"$instance"'


class Board:
    def __init__(self):
        self.panels = []
        self.y = 0
        self.x = 0
        self.row_h = 0
        self.next_id = 1

    def _place(self, w, h):
        if self.x + w > 24:
            self.y += self.row_h
            self.x, self.row_h = 0, 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        return pos

    def row(self, title, collapsed=False):
        if self.x:
            self.y += self.row_h
            self.x, self.row_h = 0, 0
        self.panels.append({"type": "row", "title": title, "collapsed": collapsed, "id": self.next_id,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.next_id += 1
        self.y += 1

    def add(self, panel, w, h):
        panel["id"] = self.next_id
        self.next_id += 1
        panel["gridPos"] = self._place(w, h)
        self.panels.append(panel)


def target(expr, legend="", ref="A", instant=False, fmt=None, ds=PROM):
    t = {"datasource": ds, "expr": expr, "refId": ref, "legendFormat": legend or "__auto"}
    if instant:
        t["instant"], t["range"] = True, False
    if fmt:
        t["format"] = fmt
    return t


def stat(title, expr, unit="short", desc="", thresholds=None, color_mode="value", decimals=None, legend=""):
    p = {"type": "stat", "title": title, "description": desc, "datasource": PROM,
         "targets": [target(expr, legend)],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": color_mode, "graphMode": "area", "textMode": "auto", "justifyMode": "auto"},
         "fieldConfig": {"defaults": {"unit": unit, "thresholds": thresholds or
                                      {"mode": "absolute", "steps": [{"color": "text", "value": None}]},
                                      "color": {"mode": "thresholds"}}, "overrides": []}}
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    return p


def bad_above(v, warn_color="orange", ok="green"):
    return {"mode": "absolute", "steps": [{"color": ok, "value": None}, {"color": warn_color, "value": v}]}


def ts(title, targets, unit="short", desc="", stack=False, min0=True, legend_calcs=("mean", "max", "lastNotNull"),
       fill=10, draw="line"):
    if isinstance(targets, dict):
        targets = [targets]
    for i, t in enumerate(targets):
        t["refId"] = chr(ord("A") + i)
    d = {"unit": unit, "custom": {"drawStyle": draw, "lineWidth": 2, "fillOpacity": fill, "showPoints": "never",
                                  "spanNulls": True, "axisSoftMin": 0 if min0 else None,
                                  "stacking": {"mode": "normal" if stack else "none", "group": "A"}},
         "color": {"mode": "palette-classic"}}
    return {"type": "timeseries", "title": title, "description": desc, "datasource": targets[0]["datasource"],
            "targets": targets,
            "fieldConfig": {"defaults": d, "overrides": []},
            "options": {"tooltip": {"mode": "multi", "sort": "desc"},
                        "legend": {"displayMode": "table", "placement": "bottom", "calcs": list(legend_calcs)}}}


def bar_gauge(title, expr, legend, unit="short", desc=""):
    return {"type": "bargauge", "title": title, "description": desc, "datasource": PROM,
            "targets": [target(expr, legend, instant=True)],
            "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": True,
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "continuous-BlYlRd"},
                                         "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}},
                            "overrides": []}}


def dashboard(uid, title, board, templating, desc, tags, refresh="30s", time_from="now-6h", links=None):
    return {"uid": uid, "title": title, "description": desc, "tags": tags, "timezone": "browser",
            "editable": True, "graphTooltip": 1, "refresh": refresh, "schemaVersion": 41, "version": 1,
            "time": {"from": time_from, "to": "now"}, "templating": {"list": templating},
            "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
                                      "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
                                      "name": "Annotations & Alerts", "type": "dashboard"},
                                     {"datasource": PROM, "enable": True, "iconColor": "purple",
                                      "name": "Server restarts", "expr":
                                      'changes(opensro_start_time_seconds{%s}[2m]) > 0' % SEL,
                                      "step": "60s", "titleFormat": "server restarted", "textFormat": ""}]},
            "links": links or [], "panels": board.panels}


def server_dashboard():
    b = Board()
    rate = "$__rate_interval"
    b.row("Health")
    b.add(stat("Up", 'max(time() - timestamp(opensro_build_info{%s})) < bool 60' % SEL, "none",
               "1 when a sample arrived from the server in the last minute.",
               {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]},
               color_mode="background"), 3, 4)
    b.add(stat("Version", 'opensro_build_info{%s}' % SEL, "none", "The running build (opensro_build_info).",
               legend="{{version}} {{commit}}") | {"options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                                                               "textMode": "name", "colorMode": "none", "graphMode": "none"}}, 4, 4)
    b.add(stat("Uptime", 'time() - max(opensro_start_time_seconds{%s})' % SEL, "s"), 3, 4)
    b.add(stat("Players online", 'sum(opensro_players_online{%s})' % SEL), 3, 4)
    b.add(stat("Connections", 'sum(opensro_gateway_connections_active{%s})' % SEL), 3, 4)
    b.add(stat("Errors / min", 'sum(rate(opensro_log_messages_total{%s, level="ERROR"}[5m])) * 60' % SEL, "short",
               "ERROR log lines a minute.", bad_above(1, "red"), color_mode="background", decimals=1), 2, 4)
    b.add(stat("Panics (1h)", 'sum(increase(opensro_panics_recovered_total{%s}[1h]))' % SEL, "short",
               "Panics recovered in the last hour (a handler, a disconnect hook, the COS tick).", bad_above(1, "red"),
               color_mode="background", decimals=0), 2, 4)
    b.add(stat("DB errors / min", 'sum(rate(opensro_db_errors_total{%s}[5m])) * 60' % SEL, "short", "",
               bad_above(1, "red"), color_mode="background", decimals=1), 2, 4)
    b.add(stat("Worst loop p99", 'max(histogram_quantile(0.99, sum by (loop, le) (rate(opensro_loop_tick_seconds_bucket{%s}[5m]))))' % SEL,
               "s", "The slowest loop's p99 tick over 5 minutes.", bad_above(0.1), decimals=3), 3, 4)
    b.add(stat("Overruns / min", 'sum(rate(opensro_loop_overruns_total{%s}[5m])) * 60' % SEL, "short",
               "Ticks longer than their loop's period.", bad_above(5), decimals=1), 3, 4)
    b.add(stat("Stalest loop", 'max(time() - opensro_loop_last_tick_timestamp_seconds{%s, loop!="mover"})' % SEL, "s",
               "Seconds since the least recently ticked loop (mover excluded: it sleeps while nobody moves). Above 30 s the server is stuck.",
               bad_above(5, "red"), color_mode="background", decimals=1), 3, 4)
    b.add(stat("Goroutines", 'max(go_goroutines{%s})' % SEL), 3, 4)
    b.add(stat("Heap in use", 'max(go_memstats_heap_inuse_bytes{%s})' % SEL, "bytes"), 3, 4)
    b.add(stat("CPU", 'sum(rate(process_cpu_seconds_total{%s}[5m]))' % SEL, "percentunit", "Cores used (1 = 100% of one core).",
               decimals=2), 3, 4)
    b.add(stat("Sched latency p99", 'histogram_quantile(0.99, sum by (le) (rate(go_sched_latencies_seconds_bucket{%s}[5m])))' % SEL,
               "s", "How long a runnable goroutine waited for a thread: high means CPU-starved.", bad_above(0.02)), 3, 4)
    b.add(stat("Mover lock hold", 'max(opensro_world_mover_lock_hold_seconds{%s})' % SEL, "s",
               "How long the last mover pass held the world hub's write lock.", bad_above(0.01)), 3, 4)
    b.add(stat("Monsters", 'sum(opensro_world_entities{%s, kind="monster"})' % SEL), 3, 4)

    b.row("Players and sessions")
    b.add(ts("Players online by zone", target('sum by (zone) (opensro_players_online_by_zone{%s})' % SEL, "{{zone}}"),
             stack=True, desc="The zone is the named town whose area the player stands in (nearest town centre in the one world frame), a dungeon, or other."), 12, 8)
    b.add(ts("Sessions by state", target('sum by (state) (opensro_sessions{%s})' % SEL, "{{state}}")), 12, 8)
    b.add(ts("Logins by result", target('sum by (result) (rate(opensro_logins_total{%s}[%s])) * 60' % (SEL, rate), "{{result}}"),
             "short", "Login decisions a minute (both wires)."), 8, 8)
    b.add(ts("Disconnects by reason", target('sum by (reason) (rate(opensro_gateway_disconnects_total{%s}[%s])) * 60' % (SEL, rate), "{{reason}}"),
             "short", "Sessions ended a minute."), 8, 8)
    b.add(ts("World entries, lobby ops", [
        target('sum(rate(opensro_world_entries_total{%s}[%s])) * 60' % (SEL, rate), "world entries"),
        target('sum by (op) (rate(opensro_character_ops_total{%s}[%s])) * 60' % (SEL, rate), "character {{op}}")],
        "short", "A minute."), 8, 8)

    b.row("Gateway")
    b.add(ts("Packets / s", target('sum by (dir) (rate(opensro_gateway_packets_total{%s}[%s]))' % (SEL, rate), "{{dir}}"), "pps"), 8, 8)
    b.add(ts("Bandwidth", target('sum by (dir) (rate(opensro_gateway_bytes_total{%s}[%s]))' % (SEL, rate), "{{dir}}"), "Bps"), 8, 8)
    b.add(ts("Requests / s by group", target('sum by (group) (rate(opensro_gateway_packets_total{%s, dir="in"}[%s]))' % (SEL, rate), "{{group}}"),
             "reqps", stack=True), 8, 8)
    b.add(ts("Handler p99 by group", target(
        'histogram_quantile(0.99, sum by (group, le) (rate(opensro_gateway_handler_seconds_bucket{%s}[%s])))' % (SEL, rate), "{{group}}"),
        "s", "The handler chain's time over one inbound packet."), 12, 8)
    b.add(ts("Handler errors and panics / min", target(
        'sum by (group, kind) (rate(opensro_gateway_handler_errors_total{%s}[%s])) * 60' % (SEL, rate), "{{group}} {{kind}}"),
        "short", "Each one closed the player's session."), 12, 8)
    b.add(bar_gauge("Top inbound opcodes (rate over the range)",
                    'topk(15, sum by (opcode, group) (rate(opensro_gateway_packets_total{%s, dir="in"}[$__range])))' % SEL,
                    "{{opcode}} ({{group}})", "reqps"), 8, 10)
    b.add(bar_gauge("Top outbound opcodes (rate over the range)",
                    'topk(15, sum by (opcode, group) (rate(opensro_gateway_packets_total{%s, dir="out"}[$__range])))' % SEL,
                    "{{opcode}} ({{group}})", "pps"), 8, 10)
    b.add(ts("Broadcast fan-out and send stalls", [
        target('sum(rate(opensro_world_broadcast_deliveries_total{%s}[%s])) / sum(rate(opensro_world_broadcasts_total{%s}[%s]))' % (SEL, rate, SEL, rate), "recipients per broadcast"),
        target('sum by (reason) (increase(opensro_gateway_send_stalls_total{%s}[%s]))' % (SEL, rate), "stalled: {{reason}}")],
        "short", "Shared frames' mean recipients; sessions given up for not reading."), 8, 10)

    b.row("Game loops")
    b.add(ts("Tick p99 by loop", target(
        'histogram_quantile(0.99, sum by (loop, le) (rate(opensro_loop_tick_seconds_bucket{%s}[%s])))' % (SEL, rate), "{{loop}}"), "s"), 8, 8)
    b.add(ts("Tick p50 by loop", target(
        'histogram_quantile(0.5, sum by (loop, le) (rate(opensro_loop_tick_seconds_bucket{%s}[%s])))' % (SEL, rate), "{{loop}}"), "s"), 8, 8)
    b.add(ts("Overruns / min by loop", target(
        'sum by (loop) (rate(opensro_loop_overruns_total{%s}[%s])) * 60' % (SEL, rate), "{{loop}}"), "short",
        "Ticks longer than the loop's own period."), 8, 8)
    b.add(ts("Seconds since last tick", target(
        'time() - opensro_loop_last_tick_timestamp_seconds{%s}' % SEL, "{{loop}}"), "s",
        "A line that climbs is a loop that stopped (mover sleeps while nobody moves)."), 12, 8)
    b.add(ts("Mover lock hold and scheduler latency", [
        target('max(opensro_world_mover_lock_hold_seconds{%s})' % SEL, "mover pass lock hold"),
        target('histogram_quantile(0.99, sum by (le) (rate(go_sched_latencies_seconds_bucket{%s}[%s])))' % (SEL, rate), "scheduler latency p99")],
        "s"), 12, 8)

    b.row("World")
    b.add(ts("Entities by kind", target('sum by (kind) (opensro_world_entities{%s})' % SEL, "{{kind}}"), "short"), 8, 8)
    b.add(ts("Movement / min", [
        target('sum by (kind) (rate(opensro_move_legs_total{%s}[%s])) * 60' % (SEL, rate), "leg {{kind}}"),
        target('sum by (reason) (rate(opensro_move_leg_ends_total{%s}[%s])) * 60' % (SEL, rate), "ended: {{reason}}"),
        target('sum(rate(opensro_move_corrections_total{%s}[%s])) * 60' % (SEL, rate), "corrections")], "short"), 8, 8)
    b.add(ts("Position claims / min", target('sum by (result) (rate(opensro_move_claims_total{%s}[%s])) * 60' % (SEL, rate), "{{result}}"),
             "short", "refused_wall: a stop past a wall the server's walk found (round 857)."), 8, 8)
    b.add(ts("Warps / min by kind", target('sum by (kind) (rate(opensro_teleports_total{%s}[%s])) * 60' % (SEL, rate), "{{kind}}"), "short"), 8, 8)
    b.add(ts("Zone changes refused / min", target('sum by (reason) (rate(opensro_zone_change_refused_total{%s}[%s])) * 60' % (SEL, rate), "{{reason}}"),
             "short", "not_gm: OpChangeZone from a player account (round 854)."), 8, 8)
    b.add(ts("GM commands / min", target('sum by (verb, result) (rate(opensro_gm_commands_total{%s}[%s])) * 60' % (SEL, rate), "{{verb}} {{result}}"),
             "short"), 8, 8)

    b.row("Combat")
    b.add(ts("Skill casts and blows / s", [
        target('sum(rate(opensro_skill_casts_total{%s}[%s]))' % (SEL, rate), "skill casts"),
        target('sum by (target, source) (rate(opensro_combat_damage_events_total{%s}[%s]))' % (SEL, rate), "blows on {{target}} ({{source}})")],
        "short"), 8, 8)
    b.add(ts("Damage / s", target('sum by (target, source) (rate(opensro_combat_damage_total{%s}[%s]))' % (SEL, rate), "{{target}} ({{source}})"),
             "short", "Hit points taken."), 8, 8)
    b.add(ts("Monsters and deaths / min", [
        target('sum(rate(opensro_monsters_spawned_total{%s}[%s])) * 60' % (SEL, rate), "monsters spawned"),
        target('sum(rate(opensro_monsters_killed_total{%s}[%s])) * 60' % (SEL, rate), "monsters killed"),
        target('sum(rate(opensro_monsters_removed_total{%s}[%s])) * 60' % (SEL, rate), "monsters removed"),
        target('sum(rate(opensro_player_deaths_total{%s}[%s])) * 60' % (SEL, rate), "player deaths"),
        target('sum(rate(opensro_player_revives_total{%s}[%s])) * 60' % (SEL, rate), "player revives")], "short"), 8, 8)

    b.row("Economy")
    b.add(ts("Gold flow / min", target('sum by (dir) (rate(opensro_gold_total{%s}[%s])) * 60' % (SEL, rate), "{{dir}}"),
             "short", "Gold credited to and debited from characters' purses, all characters."), 8, 8)
    b.add(ts("Ground items / min", [
        target('sum by (kind) (rate(opensro_items_dropped_total{%s}[%s])) * 60' % (SEL, rate), "dropped {{kind}}"),
        target('sum by (by, kind) (rate(opensro_items_picked_total{%s}[%s])) * 60' % (SEL, rate), "picked {{kind}} by {{by}}"),
        target('sum(rate(opensro_items_expired_total{%s}[%s])) * 60' % (SEL, rate), "expired")], "short"), 8, 8)
    b.add(ts("Mall, silk, gacha (per hour)", [
        target('sum by (result) (increase(opensro_mall_purchases_total{%s}[1h]))' % SEL, "mall {{result}}"),
        target('sum(increase(opensro_silk_spent_total{%s}[1h]))' % SEL, "silk spent"),
        target('sum(increase(opensro_gacha_draws_total{%s}[1h]))' % SEL, "gacha draws")], "short"), 8, 8)
    b.add(ts("Stalls and exchanges (per hour)", [
        target('sum by (event) (increase(opensro_stall_events_total{%s}[1h]))' % SEL, "stall {{event}}"),
        target('sum by (result) (increase(opensro_exchanges_total{%s}[1h]))' % SEL, "exchange {{result}}"),
        target('sum(opensro_world_entities{%s, kind="stall"})' % SEL, "stalls standing")], "short"), 12, 8)
    b.add(ts("Guild and social requests / min", target(
        'sum by (group) (rate(opensro_gateway_packets_total{%s, dir="in", group=~"guild|social|economy"}[%s])) * 60' % (SEL, rate), "{{group}}"),
        "short", "Inbound requests of the guild (guild, union, war, storage), social (chat, party, friends) and economy groups."), 12, 8)

    b.row("Database")
    b.add(ts("Statements / s by pool and op", target('sum by (pool, op) (rate(opensro_db_queries_total{%s}[%s]))' % (SEL, rate), "{{pool}} {{op}}"),
             "short"), 8, 8)
    b.add(ts("Statement p99 by pool", target(
        'histogram_quantile(0.99, sum by (pool, le) (rate(opensro_db_query_seconds_bucket{%s}[%s])))' % (SEL, rate), "{{pool}} p99"), "s"), 8, 8)
    b.add(ts("Errors / min by table", target('sum by (pool, op, table) (rate(opensro_db_errors_total{%s}[%s])) * 60' % (SEL, rate), "{{pool}} {{op}} {{table}}"),
             "short"), 8, 8)
    b.add(ts("Pool connections", [
        target('sum by (db_name) (go_sql_in_use_connections{%s})' % SEL, "{{db_name}} in use"),
        target('sum by (db_name) (go_sql_idle_connections{%s})' % SEL, "{{db_name}} idle"),
        target('sum by (db_name) (go_sql_max_open_connections{%s})' % SEL, "{{db_name}} max")], "short"), 8, 8)
    b.add(ts("Pool waits", [
        target('sum by (db_name) (rate(go_sql_wait_count_total{%s}[%s]))' % (SEL, rate), "{{db_name}} waits/s"),
        target('sum by (db_name) (rate(go_sql_wait_duration_seconds_total{%s}[%s]))' % (SEL, rate), "{{db_name}} wait s/s")],
        "short", "A query waiting for a free connection: the pool is too small or something holds connections."), 8, 8)
    b.add(bar_gauge("Busiest tables (statements / s over the range)",
                    'topk(12, sum by (table) (rate(opensro_db_queries_total{%s}[$__range])))' % SEL, "{{table}}", "short"), 8, 8)
    b.add(ts("Transactions / s", target('sum by (pool, result) (rate(opensro_db_transactions_total{%s}[%s]))' % (SEL, rate), "{{pool}} {{result}}"),
             "short"), 8, 8)

    b.row("Go runtime")
    b.add(ts("Memory", [
        target('max(go_memstats_heap_inuse_bytes{%s})' % SEL, "heap in use"),
        target('max(go_memstats_heap_alloc_bytes{%s})' % SEL, "heap alloc"),
        target('max(process_resident_memory_bytes{%s})' % SEL, "resident")], "bytes"), 8, 8)
    b.add(ts("Goroutines and threads", [
        target('max(go_goroutines{%s})' % SEL, "goroutines"),
        target('max(go_threads{%s})' % SEL, "threads"),
        target('max(process_open_fds{%s})' % SEL, "open fds")], "short"), 8, 8)
    b.add(ts("GC", [
        target('sum(rate(go_gc_duration_seconds_count{%s}[%s]))' % (SEL, rate), "GC cycles / s"),
        target('max(go_gc_duration_seconds{%s, quantile="1"})' % SEL, "longest pause (s)")], "short"), 8, 8)
    b.add(ts("CPU (cores)", target('sum(rate(process_cpu_seconds_total{%s}[%s]))' % (SEL, rate), "cpu"), "short"), 12, 8)
    b.add(ts("Log lines / min by level", target('sum by (level) (rate(opensro_log_messages_total{%s}[%s])) * 60' % (SEL, rate), "{{level}}"),
             "short"), 12, 8)

    templating = [{"name": "instance", "label": "Instance", "type": "query", "datasource": PROM,
                   "query": {"query": 'label_values(opensro_build_info{job="opensro-server"}, instance)', "refId": "inst"},
                   "definition": 'label_values(opensro_build_info{job="opensro-server"}, instance)',
                   "refresh": 2, "includeAll": True, "allValue": ".*", "multi": False,
                   "current": {"text": "All", "value": "$__all"}}]
    return dashboard("opensro-server", "OpenSRO server", b, templating,
                     "The game server's health, players, gateway, loops, world, combat, economy, database and Go runtime (round 858).",
                     ["opensro"], links=[{"title": "OpenSRO logs", "type": "link", "url": "/d/opensro-logs/opensro-logs", "targetBlank": False}])


def logs_dashboard():
    b = Board()
    # The parsed stream every panel starts from: the selector (a textbox, so
    # the labels Alloy sets can change without editing panels), logfmt, and
    # the filters.
    base = '${selector:raw} | logfmt | __error__=""'
    filt = ('%s | character=~"${character:raw}" | account=~"${account:raw}" | zone=~"${zone:raw}" | level=~"${level:regex}"' % base)
    lines = filt + ' |~ "(?i)${search:raw}"'

    def lts(title, expr, legend, desc="", stack=True, draw="bars"):
        p = ts(title, target(expr, legend, ds=LOKI), "short", desc, stack=stack, draw=draw, fill=80)
        return p

    def logs(title, expr, desc=""):
        return {"type": "logs", "title": title, "description": desc, "datasource": LOKI,
                "targets": [{"datasource": LOKI, "expr": expr, "refId": "A", "queryType": "range"}],
                "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                            "enableLogDetails": True, "dedupStrategy": "none", "prettifyLogMessage": False}}

    b.row("Volume and errors")
    b.add(lts("Log lines by level", 'sum by (level) (count_over_time(%s [$__auto]))' % filt, "{{level}}"), 12, 8)
    b.add(lts("Errors and warnings by message", 'topk(10, sum by (msg) (count_over_time(%s | level=~"ERROR|WARN" [$__auto])))' % base,
              "{{msg}}", "The ten loudest ERROR/WARN messages (filters ignored)."), 12, 8)
    b.add({"type": "table", "title": "Top ERROR/WARN messages over the range", "datasource": LOKI,
           "targets": [{"datasource": LOKI, "refId": "A", "queryType": "instant",
                        "expr": 'topk(25, sum by (level, msg) (count_over_time(%s | level=~"ERROR|WARN" [$__range])))' % base}],
           "transformations": [{"id": "reduce", "options": {"reducers": ["lastNotNull"], "labelsToFields": True}},
                               {"id": "organize", "options": {"excludeByName": {"Field": True}, "renameByName": {"Last *": "count", "Last": "count"}}}],
           "options": {"showHeader": True, "sortBy": [{"displayName": "count", "desc": True}]},
           "fieldConfig": {"defaults": {}, "overrides": []}}, 24, 8)

    b.row("Live log")
    b.add(logs("Server log (filtered)", lines,
               "Filter with the variables above: character, account, zone, level, and a free-text search (case-insensitive regex)."), 24, 16)

    b.row("Logins, warps, GM")
    b.add(lts("Logins by result", 'sum by (result) (count_over_time(%s | msg="login" [$__auto]))' % base, "{{result}}"), 8, 8)
    b.add(lts("Warps by kind", 'sum by (kind) (count_over_time(%s | msg="warp" [$__auto]))' % base, "{{kind}}"), 8, 8)
    b.add(lts("GM commands by verb", 'sum by (verb) (count_over_time(%s | msg="gm command" [$__auto]))' % base, "{{verb}}"), 8, 8)
    b.add(logs("Logins, world entries and exits", '%s | msg=~"login|entered world|left world|lobby: .*" | account=~"${account:raw}" | character=~"${character:raw}"' % base), 12, 10)
    b.add(logs("Warps and teleports", '%s | msg=~"warp|teleport|teleport refused|walk-in teleport.*|scroll warp|zone change refused.*" | account=~"${account:raw}" | character=~"${character:raw}"' % base), 12, 10)
    b.add(logs("GM commands", '%s | msg=~"gm command.*" | account=~"${account:raw}" | character=~"${character:raw}"' % base), 12, 10)
    b.add(logs("Economy (mall, stalls, exchanges, gacha)", '%s | msg=~"mall: .*|stall: .*|exchange: .*|gacha.*"' % base), 12, 10)

    def textbox(name, label, default, desc):
        return {"name": name, "label": label, "type": "textbox", "query": default, "description": desc,
                "current": {"text": default, "value": default}, "options": [{"selected": True, "text": default, "value": default}]}

    templating = [
        textbox("selector", "Stream", '{job="opensro-server"}', "The Loki stream selector Alloy's labels match."),
        textbox("character", "Character", ".*", "A regex on the character= key (the name)."),
        textbox("account", "Account", ".*", "A regex on the account= key."),
        textbox("zone", "Zone", ".*", "A regex on the zone= key."),
        {"name": "level", "label": "Level", "type": "custom", "query": "DEBUG,INFO,WARN,ERROR", "multi": True, "includeAll": True,
         "allValue": ".*", "current": {"text": ["All"], "value": ["$__all"]},
         "options": []},
        textbox("search", "Search", "", "A case-insensitive regex over the whole line."),
    ]
    return dashboard("opensro-logs", "OpenSRO logs", b, templating,
                     "The game server's log in Loki (round 858): error and warning rates by message, the live log filtered by character, account and zone, logins, warps and GM commands.",
                     ["opensro"], time_from="now-3h",
                     links=[{"title": "OpenSRO server", "type": "link", "url": "/d/opensro-server/opensro-server", "targetBlank": False}])


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, d in (("opensro-server.json", server_dashboard()), ("opensro-logs.json", logs_dashboard())):
        with open(os.path.join(OUT, name), "w") as f:
            json.dump(d, f, indent=2)
            f.write("\n")
        print("wrote", os.path.join(OUT, name), len(d["panels"]), "panels")


if __name__ == "__main__":
    main()
