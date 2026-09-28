extends SceneTree

## The "Audio" autoload's music half (MusicDirector) drives real players
## under Godot's headless (dummy) driver: zone -> track through a synthetic
## region table and env table, same track keeps, unknown keeps, fade then
## start, beds loop, loading silences. Synthetic data only. Run:
## `godot4 --headless --path client --script res://scripts/audio/music_director_test.gd`

var _failures := 0
var _ran := false

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Players refuse to play before the autoload is in the tree: run on frame 1.
func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false

func _wav(seconds: float) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 22050
	var pcm := PackedByteArray()
	pcm.resize(int(22050 * seconds) * 2)
	w.data = pcm
	return w

func _zone(et: GDScript, name: String, bgm: String, bed: String):
	var z = et.Zone.new()
	z.name = name
	z.bgm = bgm
	var e = et.Entry.new()
	e.file = bed
	z.day.append(e)
	var shot = et.Entry.new()
	shot.file = "shot.wav"
	shot.a = 4
	shot.b = 8
	z.day.append(shot)
	return z

func _line(fields: Array) -> PackedByteArray:
	var out := "\t".join(fields).to_ascii_buffer()
	out.append_array("\r\n".to_ascii_buffer())
	return out

func _run() -> void:
	var svc = root.get_node_or_null("Audio")
	var music = svc.get("music") if svc != null else null
	_check(music != null and music.has_method("set_area"), "the 'Audio' autoload has a music director (Audio.music)")
	if music == null or not music.has_method("set_area"):
		_finish()
		return
	var et: GDScript = load("res://scripts/audio/env_sound_table.gd")
	var bank: GDScript = load("res://scripts/audio/audio_bank.gd")
	for p in ["town.ogg", "field.ogg", "prim\\snd\\env\\bed.wav", "prim\\snd\\env\\shot.wav"]:
		bank.inject_for_test(p, _wav(0.5))
	music.set_env_table({
		"TownZone": _zone(et, "TownZone", "Town.ogg", "bed.wav"),
		"FortZone": _zone(et, "FortZone", "Town.ogg", "bed.wav"),
		"FieldZone": _zone(et, "FieldZone", "Field.ogg", "bed.wav"),
	})
	var ri := PackedByteArray()
	ri.append_array(_line(["#TOWN", "TownZone"]))
	ri.append_array(_line(["10", "20", "ALL"]))
	ri.append_array(_line(["#FIELD", "FortZone", "group"]))
	ri.append_array(_line(["10", "20", "RECT", "0", "0", "100", "100"]))
	ri.append_array(_line(["#FIELD", "Nowhere"]))
	ri.append_array(_line(["11", "20", "ALL"]))
	ri.append_array(_line(["#FIELD", "FieldZone"]))
	ri.append_array(_line(["12", "20", "ALL"]))
	music.set_region_table(RegioninfoReader.parse(ri))
	var player: AudioStreamPlayer = music.bgm_player()

	music.enter_loading("test")
	music.set_area_at(20, 10, 500.0, 500.0)
	var town_stream = player.stream
	_check(music.area == "TownZone" and player.playing and town_stream != null, "a region's ALL zone starts its track at once")
	_check(town_stream is AudioStreamWAV and town_stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "the track loops")
	_check(music.beds_playing() == 1, "the zone's 0~0 bed loops on the Env bus")
	music.set_area_at(20, 10, 50.0, 50.0)
	_check(music.area == "FortZone" and player.stream == town_stream and player.playing, "a RECT zone sharing the track: the same stream keeps playing")
	music.set_area_at(20, 11, 50.0, 50.0)
	_check(music.area == "Nowhere" and player.stream == town_stream and player.playing, "a zone with no sound record: the music keeps playing")
	_check(music.beds_playing() == 0, "and its ambient stopped")
	music.set_area_at(20, 12, 50.0, 50.0)
	_check(player.stream == town_stream, "a new track does not cut in at once")
	music._process(1.25)
	_check(player.stream == town_stream and player.volume_db < -1.0, "halfway through the fade the old track is quieter (%.1f dB)" % player.volume_db)
	music._process(1.25)
	_check(player.stream != town_stream and player.playing and player.volume_db == 0.0, "after 2.5 s the new track hard-starts at full volume")
	for i in range(3):
		music._process(2.0)
	_check(music.ambient.shots.size() == 1 and music.ambient.shots[0].played, "the one-shot played on the 2 s tick (a = 4)")
	music.enter_loading("test")
	_check(not player.playing and music.beds_playing() == 0 and music.area == "", "loading: music and ambient stop, the area clears")
	music.play_intro() # no Media.pk2 in this run: no IntroBGM, nothing plays
	music.set_env_table({})
	bank.clear()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
