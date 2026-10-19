extends Node
class_name AudioService

## The client's sound, as one autoload node named "Audio" (project.godot;
## round 611). It owns the three buses and the options, the effect table and
## the voices that play it, and the listener. Code anywhere reaches it
## through the contract's static calls -- SoundTable.play_key / play_file /
## set_listener, AudioBank.stream -- or as `Audio` / AudioService.instance().
## The contract is written out in docs/protocol/SOUND_FORMAT.md.
##
## THE LISTENER (OURS -- retail's is not established): distances for the
## 100/300 volume law and the 600-unit cull are measured from the PLAYER
## (World3D passes its CharacterBody3D), and left/right from the CAMERA's
## facing. Retail's DirectSound listener is fed through the global at
## 0x1112fb0+0xc and the cull uses gfxmainframe+0x34c; neither was traced to
## the camera or the player (audio_spec 8, OPEN). The player was chosen so a
## character's own sounds are always inside the 100-unit full-volume radius
## whatever the camera distance. One call moves it: SoundTable.set_listener.
## With no listener set (the front-end screens) a positioned sound plays as a
## 2-D one at full distance volume.
##
## Headless and in the render box's movie runs Godot mixes through its dummy
## driver: nothing is heard, but players report `playing` and advance their
## playback position, and a --write-movie run records the mix into a .wav
## beside its frames -- that, and the `AUDIO ...` log lines, are what a run
## measures.

## Players per loaded effect sound; SoundTable.VOICES_PER_SOUND says why.
const VOICES_PER_SOUND := SoundTable.VOICES_PER_SOUND
## OURS (review follow-up): at most this many effect players of each kind
## (2-D, positioned) exist at once. Past it an idle player of another sound
## is taken over, or a busy one restarted -- so the pools no longer grow by
## four players for every sound ever played.
const MAX_EFFECT_VOICES := 32

var options: AudioOptions
## The zone music and ambient (round 612): MusicDirector, child "Music".
var music: MusicDirector

var _effect_table: Dictionary = {}
var _effect_table_loaded := false
var _character_info: Dictionary = {}
## Round 796: characterInfo code -> Size, "" -> the first row's code.
var _character_sizes: Dictionary = {}
var _character_info_loaded := false
## Normalised path -> Array of voices (AudioStreamPlayer or AudioStreamPlayer3D).
var _voices_2d: Dictionary = {}
var _voices_3d: Dictionary = {}
var _listener: Node3D = null
var _facing: Node3D = null
var _rng := RandomNumberGenerator.new()
## Keys already reported missing, so a missing key logs once.
var _missing_keys: Dictionary = {}

## The running service, or null (a script run outside this project).
static func instance() -> AudioService:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("Audio") as AudioService

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	AudioOptions.ensure_buses()
	options = AudioOptions.load_saved()
	options.apply_to_buses()
	music = MusicDirector.new()
	music.name = "Music"
	add_child(music)
	music.apply_mutes(options)

## Applies new option values: bus volumes and mutes, then saves them.
func set_options(new_options: AudioOptions, persist: bool = true) -> void:
	options = new_options.duplicate_options()
	options.apply_to_buses()
	if persist:
		options.save()
	if music != null:
		music.apply_mutes(options)
	print("AUDIO options: %s" % options.describe())

# --- effects ---------------------------------------------------------------

## The parsed effect table (key -> Array of SoundTable.Row), loaded on first
## use from Media.pk2.
func effect_table() -> Dictionary:
	if not _effect_table_loaded:
		_effect_table_loaded = true
		var bytes := AudioBank.read_table("media", SoundTable.EFFECTSOUND_PATH)
		if not bytes.is_empty():
			_effect_table = SoundTable.parse(bytes)
			var rows := 0
			for k in _effect_table:
				rows += (_effect_table[k] as Array).size()
			print("AUDIO: effect table %d rows under %d keys" % [rows, _effect_table.size()])
	return _effect_table

## Reads the effect table and characterInfo now, if not yet: MusicDirector
## calls it behind the loading screen. Returns "<name> <ms> ms" parts.
func preload_tables() -> Array:
	var parts: Array = []
	if not _effect_table_loaded:
		var t := Time.get_ticks_usec()
		effect_table()
		parts.append("effect table %d ms" % ((Time.get_ticks_usec() - t) / 1000))
	if not _character_info_loaded:
		var t2 := Time.get_ticks_usec()
		sound_object("")
		parts.append("characterInfo %d ms" % ((Time.get_ticks_usec() - t2) / 1000))
	return parts

## Test seam: use this table instead of the archive's.
func set_effect_table(table: Dictionary) -> void:
	_effect_table = table
	_effect_table_loaded = true

## skilleffect.txt characterInfo: characterdata code -> sound object, or "".
func sound_object(refobj_code: String) -> String:
	if not _character_info_loaded:
		_character_info_loaded = true
		var bytes := AudioBank.read_table("media", SoundTable.SKILLEFFECT_PATH)
		if not bytes.is_empty():
			_character_info = SoundTable.parse_character_info(bytes, _character_sizes)
			print("AUDIO: characterInfo %d sound objects" % _character_info.size())
	return str(_character_info.get(refobj_code, ""))

## Round 796: skilleffect.txt characterInfo's Size (column 3) for a
## characterdata code, looked up as the client does (READ FUN_00a95d30): the
## code's row, else its OrgCodeName's (`org`, the ref's +0x5c), else the
## file's first row's (the default record). 0 with no table.
func character_size(refobj_code: String, org_code: String = "") -> float:
	sound_object("")
	if _character_sizes.has(refobj_code):
		return float(_character_sizes[refobj_code])
	if org_code != "" and _character_sizes.has(org_code):
		return float(_character_sizes[org_code])
	var first := String(_character_sizes.get("", ""))
	return float(_character_sizes.get(first, 0.0)) if first != "" else 0.0

## Test seam: the sizes character_size reads.
func set_character_sizes(sizes: Dictionary) -> void:
	sound_object("")
	_character_sizes = sizes

func set_listener(node: Node3D, facing: Node3D = null) -> void:
	_listener = node
	_facing = facing

## SoundTable.play_key's body (FUN_00a6f7f0's order, READ): cull, look up,
## pick, blank counter, volume, play.
func play_key(key: String, pos = null, obj = null) -> void:
	if options.effect_muted:
		return
	var where = _position_of(pos, obj)
	if where != null and _listener_valid():
		if SoundTable.culled((where as Vector3).distance_squared_to(_listener.global_position)):
			return
	var rows: Array = effect_table().get(key, [])
	if rows.is_empty():
		if not _missing_keys.has(key):
			_missing_keys[key] = true
			print("AUDIO: no effect row for %s -- silent" % key)
		return
	var row := SoundTable.pick(rows, _rng.randi())
	if row == null:
		return
	_play(row.path, row.volume, where)

## SoundTable.play_file's body: a path at row volume 1.0.
func play_file(path: String, pos = null) -> void:
	if options.effect_muted:
		return
	var where = _position_of(pos, null)
	if where != null and _listener_valid():
		if SoundTable.culled((where as Vector3).distance_squared_to(_listener.global_position)):
			return
	_play(AudioBank.normalise(path), 1.0, where)

## The voice volume, in dB relative to the Effect bus, for a sound of row
## volume `row_volume` at world position `where` (null = 2-D); or NAN when
## the law says it is not played.
func voice_db(row_volume: float, where) -> float:
	var dist_mb := float(SoundTable.CEIL_MB)
	if where != null and _listener_valid():
		dist_mb = SoundTable.distance_mb((where as Vector3).distance_to(_listener.global_position))
	var vol := SoundTable.volume_mb(dist_mb, AudioOptions.slider_mb(options.effect), row_volume)
	if not SoundTable.audible(vol):
		return NAN
	return float(vol) / 100.0 - AudioOptions.slider_db(options.effect)

func _play(path: String, row_volume: float, where) -> void:
	if not is_inside_tree():
		return # a player outside the tree refuses to play
	var db := voice_db(row_volume, where)
	if is_nan(db):
		return
	var audio := AudioBank.stream(path)
	if audio == null:
		return
	var camera := _camera()
	if where != null and _listener_valid() and camera != null:
		var voice := _voice(_voices_3d, path, true) as AudioStreamPlayer3D
		voice.stream = audio
		voice.volume_db = db
		voice.global_position = _pan_point(where as Vector3, camera)
		voice.play()
	else:
		var voice2 := _voice(_voices_2d, path, false) as AudioStreamPlayer
		voice2.stream = audio
		voice2.volume_db = db
		voice2.play()

## Where the sound is put for Godot's panner: on the unit circle around the
## camera, at sin = pan / 10000 to the right. That feeds Godot retail's pan
## NUMBER only. What Godot does with it is its own: its 3-D panner is not
## DirectSound's dB pan law, and it scales the pan by the project setting
## audio/general/3d_panning_strength (default 0.5, left at the default here)
## times the player's panning_strength (1.0) -- so a source retail puts fully
## to one side is not fully one-sided here. Ours, not a match.
func _pan_point(where: Vector3, camera: Camera3D) -> Vector3:
	var origin := _listener.global_position
	var right := _flat(_facing.global_transform.basis.x if _facing != null else camera.global_transform.basis.x)
	var lateral := (where - origin).dot(right) if right != Vector3.ZERO else 0.0
	var s := float(SoundTable.pan_units(lateral)) / float(SoundTable.PAN_MAX)
	var local := Vector3(s, 0.0, -sqrt(maxf(0.0, 1.0 - s * s)))
	return camera.global_transform * local

static func _flat(v: Vector3) -> Vector3:
	var f := Vector3(v.x, 0.0, v.z)
	return f.normalized() if f.length_squared() > 0.000001 else Vector3.ZERO

## The first idle voice of this sound, a new one while under the cap, or a
## random busy one to restart (FUN_00c1db70, READ; the cap is ours).
func _voice(pool: Dictionary, path: String, positioned: bool) -> Node:
	var voices: Array = pool.get(path, [])
	for v in voices:
		if not (v as Node).get("playing"):
			return v
	if voices.size() < VOICES_PER_SOUND and _voice_count(pool) >= MAX_EFFECT_VOICES:
		var spare := _take_idle_voice(pool)
		if spare != null:
			voices.append(spare)
			pool[path] = voices
			return spare
		if voices.is_empty():
			return _steal_busy_voice(pool, path)
		return voices[_rng.randi() % voices.size()]
	if voices.size() < VOICES_PER_SOUND:
		var voice: Node
		if positioned:
			var p3 := AudioStreamPlayer3D.new()
			p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
			p3.max_distance = 0.0
			p3.attenuation_filter_db = 0.0
			p3.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
			p3.bus = AudioOptions.BUS_EFFECT
			voice = p3
		else:
			var p2 := AudioStreamPlayer.new()
			p2.bus = AudioOptions.BUS_EFFECT
			voice = p2
		voice.name = "Voice%d" % get_child_count()
		add_child(voice)
		voices.append(voice)
		pool[path] = voices
		return voice
	return voices[_rng.randi() % voices.size()]

func _voice_count(pool: Dictionary) -> int:
	var n := 0
	for k in pool:
		n += (pool[k] as Array).size()
	return n

## An idle player of another sound, removed from that sound's list.
func _take_idle_voice(pool: Dictionary) -> Node:
	for k in pool:
		var list: Array = pool[k]
		for v in list:
			if not (v as Node).get("playing"):
				list.erase(v)
				return v
	return null

## Every player busy and this sound has none: restart another sound's.
func _steal_busy_voice(pool: Dictionary, path: String) -> Node:
	var keys := pool.keys().filter(func(k): return not (pool[k] as Array).is_empty())
	var from: Array = pool[keys[_rng.randi() % keys.size()]]
	var v: Node = from.pop_back()
	pool[path] = [v]
	return v

func _position_of(pos, obj):
	if pos is Vector3:
		return pos
	if obj is Node3D and is_instance_valid(obj) and (obj as Node3D).is_inside_tree():
		return (obj as Node3D).global_position
	return null

func _listener_valid() -> bool:
	return _listener != null and is_instance_valid(_listener) and _listener.is_inside_tree()

func _camera() -> Camera3D:
	var viewport := get_viewport()
	return viewport.get_camera_3d() if viewport != null else null

## How many effect voices are sounding (for QA lines and tests).
func effect_voices_playing() -> int:
	var n := 0
	for pool in [_voices_2d, _voices_3d]:
		for path in pool:
			for v in pool[path]:
				if (v as Node).get("playing"):
					n += 1
	return n
