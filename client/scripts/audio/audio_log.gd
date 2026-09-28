extends RefCounted
class_name AudioLog

## One `AUDIO ...` line per fired sound, rate-limited (round 614). The render
## box mixes through Godot's dummy driver, so these lines are what a run
## measures; a fast attack loop fires the same key several times a second and
## would bury the log. OURS: a line is printed when its tag has not been
## printed for WINDOW_MS; the repeats in between are counted and reported on
## the next line of that tag.

const WINDOW_MS := 1000

static var _last_ms: Dictionary = {}
static var _held: Dictionary = {}

## Prints `text` unless `tag` printed within WINDOW_MS. Returns whether it
## printed.
static func line(tag: String, text: String) -> bool:
	var now := Time.get_ticks_msec()
	if _last_ms.has(tag) and now - int(_last_ms[tag]) < WINDOW_MS:
		_held[tag] = int(_held.get(tag, 0)) + 1
		return false
	var held := int(_held.get(tag, 0))
	_held.erase(tag)
	_last_ms[tag] = now
	print(text + (" (+%d more since the last line)" % held if held > 0 else ""))
	return true

## Forgets every tag (tests).
static func reset() -> void:
	_last_ms.clear()
	_held.clear()
