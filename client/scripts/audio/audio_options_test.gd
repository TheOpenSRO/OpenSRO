extends SceneTree

## AudioOptions: the slider -> dB mapping, the defaults, the saved form, and
## the buses they drive. Headless, no game data:
## `godot4 --headless --path client --script res://scripts/audio/audio_options_test.gd`
##
## Loaded by path, so a checkout without the script prints FAIL lines. It
## never touches the real user://settings.cfg: the saved form is checked on
## a ConfigFile in memory.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var ao: GDScript = load("res://scripts/audio/audio_options.gd")
	_check(ao != null, "scripts/audio/audio_options.gd exists (AudioOptions)")
	if ao == null:
		_finish()
		return

	# The mapping (READ): 20*v - 2000 hundredths of a dB, i.e. v/5 - 20 dB.
	_check(ao.slider_mb(0) == -2000 and ao.slider_mb(100) == 0, "slider 0 -> -2000 mB, 100 -> 0 mB")
	_check(ao.slider_db(0) == -20.0 and ao.slider_db(30) == -14.0 and ao.slider_db(50) == -10.0 and ao.slider_db(100) == 0.0,
		"dB = v/5 - 20: 0 -> -20, 30 -> -14, 50 -> -10, 100 -> 0")
	_check(ao.slider_db(-5) == -20.0 and ao.slider_db(250) == 0.0, "values outside 0..100 clamp")

	# Defaults (READ): BGM 30, Effect 50, Env 50, no mutes.
	var d = ao.from_config(ConfigFile.new())
	_check(d.bgm == 30 and d.effect == 50 and d.env == 50, "an empty settings file gives BGM 30 / Effect 50 / Env 50")
	_check(not d.bgm_muted and not d.effect_muted and not d.env_muted, "and nothing muted")

	# Saved form: round trip through ConfigFile's own text.
	var o = ao.new()
	o.bgm = 7
	o.effect = 100
	o.env = 0
	o.env_muted = true
	var file := ConfigFile.new()
	file.set_value("server", "address", "127.0.0.1:15779") # another section survives
	o.write_to(file)
	var text := file.encode_to_text()
	var back := ConfigFile.new()
	_check(back.parse(text) == OK, "the written settings text parses back (no unquoted strings)")
	var r = ao.from_config(back)
	_check(r.bgm == 7 and r.effect == 100 and r.env == 0 and r.env_muted and not r.bgm_muted,
		"the six values survive a save and load")
	_check(back.get_value("server", "address", "") == "127.0.0.1:15779", "the file's other settings are kept")
	_check(text.contains("[audio]") and text.contains("bgm=7") and text.contains("env_muted=true"), "they live under [audio]:\n" + text)
	var bad := ConfigFile.new()
	bad.set_value("audio", "bgm", 400)
	_check(ao.from_config(bad).bgm == 100, "a saved value past 100 is clamped on load")

	# Review follow-up: a settings file that does not parse is not rewritten.
	var bad_path := "user://audio_options_test_settings.cfg"
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_string("[world]\nseasonal=christmas,halloween\n[server]\naddress=\"x\"\n")
	f.close()
	var before := FileAccess.get_file_as_string(bad_path)
	_check(o.save(bad_path) == false, "save() refuses a settings file that does not parse")
	_check(FileAccess.get_file_as_string(bad_path) == before, "and leaves it as it was (its other settings are not lost)")
	DirAccess.remove_absolute(bad_path)
	var ok_path := "user://audio_options_test_settings2.cfg"
	_check(o.save(ok_path) and ao.from_config(_load(ok_path)).bgm == 7, "a missing file is created with the values")
	DirAccess.remove_absolute(ok_path)

	# The buses: BGM, Effect, Env under Master, volume = slider dB, mute.
	ao.ensure_buses()
	ao.ensure_buses() # idempotent
	var names := []
	for i in range(AudioServer.bus_count):
		names.append(AudioServer.get_bus_name(i))
	_check(names.count("BGM") == 1 and names.count("Effect") == 1 and names.count("Env") == 1,
		"exactly one BGM, Effect and Env bus exist: %s" % str(names))
	for bus in ["BGM", "Effect", "Env"]:
		_check(AudioServer.get_bus_send(AudioServer.get_bus_index(bus)) == "Master", "%s sends to Master" % bus)
	var saved_state := [AudioServer.get_bus_volume_db(AudioServer.get_bus_index("BGM")),
		AudioServer.is_bus_mute(AudioServer.get_bus_index("Env"))]
	o.apply_to_buses()
	_check(is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("BGM")), -18.6)
		and is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Effect")), 0.0)
		and is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Env")), -20.0),
		"bus volumes are the sliders' dB (BGM 7 -> -18.6, Effect 100 -> 0, Env 0 -> -20)")
	_check(AudioServer.is_bus_mute(AudioServer.get_bus_index("Env")) and not AudioServer.is_bus_mute(AudioServer.get_bus_index("BGM")),
		"a muted row mutes its bus, and only its bus")
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("BGM"), saved_state[0])
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Env"), saved_state[1])
	_finish()

func _load(path: String) -> ConfigFile:
	var c := ConfigFile.new()
	c.load(path)
	return c

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
