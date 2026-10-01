extends RefCounted
class_name ParseProfile

## Where the asset-reading time of a world load goes, function by function
## (round 667): the measurement the native (Rust) reader was ranked on.
##
## LoadTimings (client/scripts/world/load_timings.gd) times a cell's phases
## from the outside -- `terrain [tiletable ...]`, `objects [models ...]`,
## `npcs [tables]`. This times the readers from the inside: every call of a
## pk2 directory read (the disk read and the Blowfish decrypt apart), a file
## read, a path lookup, and each parser this project reads the world with,
## summed per key and split by thread -- the main thread's time against the
## WorkerThreadPool tasks' (round 565 moved a cell's terrain and objects
## preparation onto those). Keys nest: `pk2.find_file` includes the directory
## reads it triggers; the report says which keys are exclusive.
##
## Off unless SRREVAMP_PARSE_PROFILE=1 -- then each `add` takes one mutex and
## two dictionary writes, measured below a microsecond; off, one static bool.
## World3D prints `report()` with the entry's LoadTimings summary.

static var enabled := OS.get_environment("SRREVAMP_PARSE_PROFILE") == "1"
static var _lock := Mutex.new()
## key -> [main usec, main calls, worker usec, worker calls]
static var _rows := {}
## key -> bytes handled (summed over both threads), for the keys that read.
static var _bytes := {}

## The start of a timed call: 0 when profiling is off, so a call site costs
## nothing more than this and the `add` that ignores it.
static func t0() -> int:
	return Time.get_ticks_usec() if enabled else 0

## Adds one call of `key` that started at `start` (a t0()).
static func add(key: String, start: int, nbytes: int = 0) -> void:
	if not enabled:
		return
	var usec := Time.get_ticks_usec() - start
	var main := OS.get_thread_caller_id() == OS.get_main_thread_id()
	_lock.lock()
	var row: Array = _rows.get(key, [0, 0, 0, 0])
	if main:
		row[0] += usec
		row[1] += 1
	else:
		row[2] += usec
		row[3] += 1
	_rows[key] = row
	if nbytes > 0:
		_bytes[key] = int(_bytes.get(key, 0)) + nbytes
	_lock.unlock()

static func reset() -> void:
	_lock.lock()
	_rows = {}
	_bytes = {}
	_lock.unlock()

## The table, slowest key first by main + worker time: one line per key,
## `PARSEPROF <key>: main N ms (c calls), worker N ms (c calls), B bytes`.
static func report(label: String) -> String:
	if not enabled:
		return ""
	_lock.lock()
	var keys := _rows.keys()
	keys.sort_custom(func(a, b): return int(_rows[a][0]) + int(_rows[a][2]) > int(_rows[b][0]) + int(_rows[b][2]))
	var lines := PackedStringArray(["PARSEPROF %s (native %s): key, main ms (calls), worker ms (calls), bytes" % [label, "on" if NativeAssets.available() else "off"]])
	for k in keys:
		var r: Array = _rows[k]
		lines.append("PARSEPROF %s: main %.1f ms (%d), worker %.1f ms (%d), %d bytes" % [
			k, r[0] / 1000.0, r[1], r[2] / 1000.0, r[3], int(_bytes.get(k, 0))])
	_lock.unlock()
	return "\n".join(lines)
