extends RefCounted
class_name AnimSoundSeam

## The one place the animation-fired sounds reach the audio core.
##
## The core (Round 1, built in its own lane) owns the effect table and the
## players. Its contract, fixed before either side was written:
##
##   SoundTable.play_key(key: String, pos = null, obj = null) -> void
##       an effectsound key: random pick among its rows, the per-row blank
##       counter, the 600-unit cull and the distance falloff
##   SoundTable.play_file(path: String, pos = null) -> void
##
## The calls go to the core's SoundTable (client/scripts/audio/, round 611),
## which reaches the `Audio` autoload. A test routes them to an
## AnimSoundStub instead (set_sink), which records them.
##
## The seam passes every trigger through. The blank counter belongs to the
## core: an idle's `snd_stand` reaches play_key on every loop, and the row's
## own `blank` decides which of those sound.

## null: the real SoundTable. A test sets an AnimSoundStub.
static var _sink: Object = null

## For tests: route the calls to `target` (an AnimSoundStub); null restores
## the real SoundTable.
static func set_sink(target: Object) -> void:
	_sink = target

static func play_key(key: String, pos = null, obj = null) -> void:
	if _sink != null:
		_sink.play_key(key, pos, obj)
	else:
		SoundTable.play_key(key, pos, obj)

static func play_file(path: String, pos = null) -> void:
	if _sink != null:
		_sink.play_file(path, pos)
	else:
		SoundTable.play_file(path, pos)
