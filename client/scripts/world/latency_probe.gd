extends RefCounted
class_name LatencyProbe

## Round 786 (QA, OURS): how late a monster appears and how long an attack
## takes to register, measured in the client's own clock -- the numbers the
## round's before/after table is made of. On only with OPENSRO_QA_LATENCY=1;
## off, every call returns at its first line.
##
## Two records:
## - A monster. `monster_recv` when a list or a spawn push names an id the
##   client has no body for (the clock and the distance from the player at
##   that moment), `monster_body` when its body is made: one `QA LAT mob`
##   line with the wait and both distances, and why it waited (`template`:
##   its species' model was assembled first; `region`: its region was not
##   loaded; `queue`: the list's per-frame build budget; `none`).
## - An attack. `attack_click` when the player asks (a click, a skill key),
##   `attack_send` when the request goes out (after any walk into reach),
##   `attack_result` when the server's answer is dispatched: one `QA LAT atk`
##   line with click->send (the walk), send->result (the server's round trip
##   as the client sees it: the socket, the server, the frame's read) and the
##   total.
## `summary()` prints the percentiles of both every SUMMARY_EVERY results.

const SUMMARY_EVERY := 20

static var on := OS.get_environment("OPENSRO_QA_LATENCY") == "1"
## The clock at the end of each `QA LAT mob` line (on in a live run; the test
## turns it off for its fixed lines).
static var stamp := true

static var _mob_recv := {} # id -> [msec, dist, how]
static var _mob_wait := {} # id -> why it waited ("template", "region", "queue")
static var _click := {} # target -> msec
static var _sent := {} # target -> msec
static var mob_waits: Array[int] = []
static var mob_dists: Array[float] = []
static var atk_rtts: Array[int] = []
static var atk_totals: Array[int] = []

## The body build's stopwatch (World3D._build_monster_body): `lap_start`,
## a `lap` after each step, `lap_end` prints one `QA LAT build` line.
static var _lap_t := 0
static var _laps: Array = []

static func lap_start() -> void:
	if on:
		_lap_t = Time.get_ticks_usec()
		_laps.clear()

static func lap(what: String) -> void:
	if not on:
		return
	var t := Time.get_ticks_usec()
	_laps.append("%s %d" % [what, t - _lap_t])
	_lap_t = t

static func lap_end(id: int) -> void:
	if not on or _laps.is_empty():
		return
	print("QA LAT build %d us: %s" % [id, ", ".join(_laps)])
	_laps.clear()

static func reset() -> void:
	_mob_recv.clear()
	_mob_wait.clear()
	_click.clear()
	_sent.clear()
	mob_waits.clear()
	mob_dists.clear()
	atk_rtts.clear()
	atk_totals.clear()

## A monster named by a list ("list") or a push ("push") with no body yet.
static func monster_recv(id: int, now_ms: int, dist: float, how: String) -> void:
	if not on or _mob_recv.has(id):
		return
	_mob_recv[id] = [now_ms, dist, how]

## Why a named monster's body was not made at once.
static func monster_waits(id: int, why: String) -> void:
	if not on or not _mob_recv.has(id) or _mob_wait.has(id):
		return
	_mob_wait[id] = why
	if why == "region":
		print("QA LAT wait %d for its region at %d ms (named at %d ms)" % [id, Time.get_ticks_msec(), int(_mob_recv[id][0])])

## The body is made. Returns the line printed ("" when off or never named).
static func monster_body(id: int, now_ms: int, dist: float) -> String:
	if not on or not _mob_recv.has(id):
		return ""
	var r: Array = _mob_recv[id]
	_mob_recv.erase(id)
	var why: String = _mob_wait.get(id, "none")
	_mob_wait.erase(id)
	var wait: int = now_ms - int(r[0])
	mob_waits.append(wait)
	mob_dists.append(dist)
	var line := "QA LAT mob %d via %s wait %d ms (%s) dist at recv %.0f at body %.0f" % [id, r[2], wait, why, float(r[1]), dist]
	if stamp:
		line += " at %d frame %d" % [now_ms, Engine.get_frames_drawn()]
	print(line)
	return line

## A monster gone before its body was made (it left, it died).
static func monster_forget(id: int) -> void:
	_mob_recv.erase(id)
	_mob_wait.erase(id)

static func attack_click(target: int, now_ms: int) -> void:
	if on:
		_click[target] = now_ms

static func attack_send(target: int, now_ms: int) -> void:
	if not on:
		return
	_sent[target] = now_ms
	if not _click.has(target):
		_click[target] = now_ms

## The server's answer about `target`. Returns the line printed ("" when off
## or when nothing was sent for it).
static func attack_result(target: int, now_ms: int, error: String) -> String:
	if not on or not _sent.has(target):
		return ""
	var sent: int = _sent[target]
	var clicked: int = _click.get(target, sent)
	_sent.erase(target)
	_click.erase(target)
	atk_rtts.append(now_ms - sent)
	atk_totals.append(now_ms - clicked)
	var line := "QA LAT atk %d click->send %d ms send->result %d ms total %d ms%s" % [
		target, sent - clicked, now_ms - sent, now_ms - clicked, (" (" + error + ")") if error != "" else ""]
	print(line)
	if atk_rtts.size() % SUMMARY_EVERY == 0:
		summary()
	return line

static func percentile(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var s := values.duplicate()
	s.sort()
	return float(s[mini(s.size() - 1, int(p * s.size()))])

static func summary() -> String:
	if not on:
		return ""
	var line := "QA LAT summary: mobs %d wait p50 %.0f p95 %.0f max %.0f ms, dist p50 %.0f min %.0f; attacks %d send->result p50 %.0f p95 %.0f max %.0f ms, total p50 %.0f p95 %.0f" % [
		mob_waits.size(), percentile(mob_waits, 0.5), percentile(mob_waits, 0.95), percentile(mob_waits, 1.0),
		percentile(mob_dists, 0.5), percentile(mob_dists, 0.0),
		atk_rtts.size(), percentile(atk_rtts, 0.5), percentile(atk_rtts, 0.95), percentile(atk_rtts, 1.0),
		percentile(atk_totals, 0.5), percentile(atk_totals, 0.95)]
	print(line)
	return line
