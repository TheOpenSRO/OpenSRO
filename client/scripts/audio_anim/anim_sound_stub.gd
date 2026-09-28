extends RefCounted
class_name AnimSoundStub

## A test double for the audio core behind AnimSoundSeam, with the
## contract's two calls. It records them and plays nothing; the tests route
## the seam to it (AnimSoundSeam.set_sink) so they can assert the keys and
## times fired. The game itself uses the real SoundTable.
##
## For a test it can also be given synthetic effect rows, and then applies
## the two pick rules the core owns, as READ from the client's play-by-key
## (FUN_00a6f7f0, docs: the audio spec's section 5):
## - several rows under one key: one is chosen with `rand() % n`;
## - each row's `blank` is a skip counter: every trigger decrements the
##   chosen row's counter, the row sounds when it goes negative, and the
##   counter is then reset to `blank` -- so it sounds on the first trigger
##   and then once every blank + 1.
## `sounded` lists the keys that would have made a sound. The real core's
## own test (sound_table_test.gd) covers the same rules against its code.

## Every call: [kind ("key" or "file"), key or path, pos, obj].
var calls: Array = []
## key -> Array of {"file": String, "blank": int}; empty unless a test sets it.
var rows: Dictionary = {}
## The keys (or "file:<path>") that sounded under `rows`, in order.
var sounded: Array[String] = []
var _counters: Dictionary = {}
var _rng := RandomNumberGenerator.new()

func _init(seed_value: int = 1) -> void:
	_rng.seed = seed_value

func play_key(key: String, pos = null, obj = null) -> void:
	calls.append(["key", key, pos, obj])
	var list: Array = rows.get(key, [])
	if list.is_empty():
		return
	var index := _rng.randi() % list.size()
	var counter_key := "%s#%d" % [key, index]
	var counter: int = int(_counters.get(counter_key, 0)) - 1
	if counter < 0:
		counter = int((list[index] as Dictionary).get("blank", 0))
		sounded.append(key)
	_counters[counter_key] = counter

func play_file(path: String, pos = null) -> void:
	calls.append(["file", path, pos, null])
	sounded.append("file:" + path)

## The keys play_key was called with, in order.
func keys() -> Array:
	var out: Array = []
	for c in calls:
		if c[0] == "key":
			out.append(String(c[1]))
	return out
