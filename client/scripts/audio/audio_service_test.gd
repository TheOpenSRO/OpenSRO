extends SceneTree

## The running "Audio" autoload plays an effect key the way the law says:
## real AudioStreamPlayer(3D) nodes under Godot's headless (dummy) audio
## driver, a synthetic table and a synthetic WAV -- no game data. Run:
## `godot4 --headless --path client --script res://scripts/audio/audio_service_test.gd`
##
## What is measurable without ears: which voices exist, whether they report
## `playing`, their volume_db, and where the panner is told they are.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

var _ran := false

## The autoload is not inside the tree yet during _initialize (a player
## there refuses to play), so the checks run on the first frame.
func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false

func _run() -> void:
	var svc = root.get_node_or_null("Audio")
	_check(svc != null and svc.has_method("play_key"), "an 'Audio' autoload with play_key runs (project.godot)")
	if svc == null or not svc.has_method("play_key"):
		_finish()
		return
	var st: GDScript = load("res://scripts/audio/sound_table.gd")
	var ao: GDScript = load("res://scripts/audio/audio_options.gd")
	var bank: GDScript = load("res://scripts/audio/audio_bank.gd")

	var saved_options = svc.options
	var o = ao.new()
	o.effect = 50
	svc.set_options(o, false)

	# One second of silent 16-bit mono, served from the cache under a path.
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var pcm := PackedByteArray()
	pcm.resize(44100)
	wav.data = pcm
	bank.inject_for_test("prim\\snd\\test\\beep.wav", wav)
	var table := {}
	for spec in [["TESTOBJ:snd_a:-:-:-:-", 0, 0.8], ["TESTOBJ:snd_b:-:-:-:-", 2, 0.8]]:
		var row = st.Row.new()
		row.blank = spec[1]
		row.volume = spec[2]
		row.path = "prim\\snd\\test\\beep.wav"
		table[spec[0]] = [row]
	svc.set_effect_table(table)

	# Listener: a node at the origin; the camera at the origin facing -Z.
	var listener := Node3D.new()
	root.add_child(listener)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	st.set_listener(listener, camera)

	# 2-D: no position -> an AudioStreamPlayer at the near volume.
	var before: int = svc.get_child_count()
	st.play_key("TESTOBJ:snd_a:-:-:-:-")
	var v2 = _newest(svc, before)
	_check(v2 is AudioStreamPlayer, "a key with no position plays on a 2-D AudioStreamPlayer")
	_check(v2 != null and v2.playing, "and it reports playing under the headless driver")
	_check(v2 != null and v2.bus == "Effect", "on the Effect bus")
	# -3000 + 3000 * 2/3 * 0.8 = -1400 mB = -14 dB absolute; the bus holds -10.
	_check(v2 != null and is_equal_approx(v2.volume_db, -4.0), "voice -4 dB + bus -10 dB = the law's -14 dB (got %s)" % (str(v2.volume_db) if v2 != null else "none"))

	# Positioned at 250 units: -2600 mB absolute -> voice -16 dB.
	before = svc.get_child_count()
	st.play_key("TESTOBJ:snd_a:-:-:-:-", Vector3(0, 0, -250))
	var v3 = _newest(svc, before)
	_check(v3 is AudioStreamPlayer3D and v3.playing, "a positioned key plays on an AudioStreamPlayer3D")
	_check(v3 != null and is_equal_approx(v3.volume_db, -16.0), "at 250 units: voice -16 dB (law -26 dB) (got %s)" % (str(v3.volume_db) if v3 != null else "none"))
	_check(v3 != null and v3.attenuation_model == AudioStreamPlayer3D.ATTENUATION_DISABLED, "Godot's own distance attenuation is off")
	# Straight ahead: the panner hears it dead ahead of the camera.
	_check(v3 != null and v3.global_position.distance_to(Vector3(0, 0, -1)) < 0.001, "straight ahead pans centre (placed at %s)" % (str(v3.global_position) if v3 != null else "none"))

	# 150 units to the right, 50 ahead: pan 5000 -> sin 0.5.
	st.play_key("TESTOBJ:snd_a:-:-:-:-", Vector3(150, 0, -50))
	var right = _playing_3d_at(svc, Vector3(0.5, 0, -sqrt(0.75)))
	_check(right, "150 units to the right is placed at sine 0.5 to the camera's right (retail pan 5000)")

	# Past 300 units: silent. Past 600: culled before the pick, so the
	# blank counter is not spent.
	var playing_before: int = svc.effect_voices_playing()
	st.play_key("TESTOBJ:snd_a:-:-:-:-", Vector3(0, 0, -350))
	_check(svc.effect_voices_playing() == playing_before, "at 350 units nothing more plays")
	st.play_key("TESTOBJ:snd_b:-:-:-:-", Vector3(0, 0, -700))
	playing_before = svc.effect_voices_playing()
	st.play_key("TESTOBJ:snd_b:-:-:-:-", Vector3(0, 0, -10))
	_check(svc.effect_voices_playing() == playing_before + 1,
		"a blank-2 row culled at 700 units still plays on its next (near) trigger: the cull spends no counter")
	playing_before = svc.effect_voices_playing()
	st.play_key("TESTOBJ:snd_b:-:-:-:-", Vector3(0, 0, -10))
	_check(svc.effect_voices_playing() == playing_before, "and its next trigger is skipped by the blank counter")

	# Voice cap: one sound never holds more than VOICES_PER_SOUND players.
	for i in range(10):
		st.play_key("TESTOBJ:snd_a:-:-:-:-")
	var voices_2d := 0
	for c in svc.get_children():
		if c is AudioStreamPlayer and c.stream == wav:
			voices_2d += 1
	_check(voices_2d == st.VOICES_PER_SOUND, "ten plays of one sound use %d 2-D voices (got %d)" % [st.VOICES_PER_SOUND, voices_2d])

	# A missing key, and the mute.
	playing_before = svc.effect_voices_playing()
	st.play_key("TESTOBJ:snd_missing:-:-:-:-")
	_check(svc.effect_voices_playing() == playing_before, "a key not in the table is silent")
	for c in svc.get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer3D:
			c.stop()
	var muted = ao.new()
	muted.effect_muted = true
	svc.set_options(muted, false)
	st.play_key("TESTOBJ:snd_a:-:-:-:-")
	st.play_file("prim\\snd\\test\\beep.wav")
	_check(svc.effect_voices_playing() == 0, "Effect muted: nothing plays")
	svc.set_options(o, false)
	st.play_file("prim\\snd\\test\\beep.wav")
	_check(svc.effect_voices_playing() == 1, "play_file plays a plain path")

	# Leave the autoload as it was.
	st.set_listener(null)
	for c in svc.get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer3D:
			c.stop()
	svc.set_options(saved_options, false)
	listener.queue_free()
	camera.queue_free()
	bank.clear()
	_finish()

## The child added since the count `before`, or null.
func _newest(svc: Node, before: int) -> Node:
	if svc.get_child_count() <= before:
		return null
	return svc.get_child(svc.get_child_count() - 1)

func _playing_3d_at(svc: Node, where: Vector3) -> bool:
	for c in svc.get_children():
		if c is AudioStreamPlayer3D and c.playing and c.global_position.distance_to(where) < 0.001:
			return true
	return false

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
