extends SceneTree

## The music state machine (ZoneMusic), the ambient tick (AmbientBeds) and
## the effectenvsnd / option.txt parse (EnvSoundTable), on synthetic input
## written here -- no game data. Run headless:
## `godot4 --headless --path client --script res://scripts/audio/zone_music_test.gd`
##
## Loaded by path, so a checkout without the scripts prints FAIL lines.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var zm: GDScript = load("res://scripts/audio/zone_music.gd")
	var ab: GDScript = load("res://scripts/audio/ambient_beds.gd")
	var et: GDScript = load("res://scripts/audio/env_sound_table.gd")
	_check(zm != null, "scripts/audio/zone_music.gd exists (ZoneMusic)")
	_check(ab != null, "scripts/audio/ambient_beds.gd exists (AmbientBeds)")
	_check(et != null, "scripts/audio/env_sound_table.gd exists (EnvSoundTable)")
	if zm != null:
		_music(zm)
	if ab != null:
		_ambient(ab)
	if et != null:
		_env_table(et)
	_finish()

func _cmds(m) -> Array:
	var out: Array = m.commands.duplicate()
	m.commands.clear()
	return out

func _music(zm: GDScript) -> void:
	var m = zm.new()
	# From idle a known zone starts at once, hard.
	_check(m.enter_area(true, "town_a.ogg") == "start", "the first known zone starts its track")
	_check(_cmds(m) == [["start", "town_a.ogg"]], "one start order, no fade from silence")
	_check(m.fade_offset_db(-14.0) == 0.0, "a started track plays at the BGM volume (offset 0 dB)")
	# The same track: nothing happens.
	_check(m.enter_area(true, "town_a.ogg") == "same", "a zone with the same track keeps it")
	_check(_cmds(m).is_empty(), "and issues no order (no restart)")
	# An unknown zone keeps whatever plays.
	_check(m.enter_area(false, "") == "unknown", "an unknown zone is reported unknown")
	_check(_cmds(m).is_empty() and m.sounding == "town_a.ogg", "and the music keeps playing")
	# A new track: 10 fade steps of 0.25 s, linear in dB to -30, then a hard start.
	_check(m.enter_area(true, "field_b.ogg") == "fade", "a different track fades the current one first")
	_check(_cmds(m).is_empty() and m.sounding == "town_a.ogg", "nothing new starts yet")
	m.advance(0.25)
	# V = -14 dB: step 1 of 10 -> -14 - (16 * 0.1) = -15.6 dB, offset -1.6.
	_check(is_equal_approx(m.fade_offset_db(-14.0), -1.6), "after one step the old track is 1.6 dB down (of 16 to -30)")
	m.advance(1.0)
	_check(is_equal_approx(m.fade_offset_db(-14.0), -8.0), "halfway (1.25 s) it is 8 dB down")
	m.advance(1.0)
	_check(m.sounding == "town_a.ogg" and is_equal_approx(m.fade_offset_db(-14.0), -14.4), "at 2.25 s: still the old track, 9 steps down")
	_check(_cmds(m).is_empty(), "no start before the tenth step")
	m.advance(0.25)
	_check(_cmds(m) == [["start", "field_b.ogg"]], "the tenth step (2.5 s) hard-starts the new track")
	_check(m.fade_offset_db(-14.0) == 0.0, "at full volume: no fade-in")
	# A request during a fade retargets it.
	m.enter_area(true, "town_a.ogg")
	m.advance(0.5)
	m.enter_area(true, "cave_c.ogg")
	m.advance(2.0)
	_check(_cmds(m) == [["start", "cave_c.ogg"]], "a zone change mid-fade ends the same fade in the newest track")
	# Title playlist over the zone music, then loading.
	m.push("title.ogg", zm.LEVEL_TITLE)
	_check(_cmds(m) == [["stop"], ["start", "title.ogg"]], "the first push stops the zone music and starts its own at once")
	_check(m.enter_area(true, "town_a.ogg") == "held", "while a playlist plays, a zone's music waits")
	_check(_cmds(m).is_empty(), "and nothing changes")
	m.push("title.ogg", zm.LEVEL_TITLE)
	_check(_cmds(m).is_empty(), "pushing the playing title again does not restart it (char select -> title)")
	m.push("siege.ogg", zm.LEVEL_SIEGE)
	m.advance(2.5)
	_check(_cmds(m) == [["start", "siege.ogg"]], "a higher level takes over (fading the title)")
	m.pop(false, zm.LEVEL_SIEGE)
	m.advance(2.5)
	_check(_cmds(m) == [["start", "title.ogg"]], "popping it falls back to the highest level left")
	m.enter_loading()
	_check(_cmds(m) == [["stop"]] and m.sounding == "" and m.active_level == -1, "loading stops the music and pops every level")
	_check(m.enter_area(true, "town_a.ogg") == "start" and _cmds(m) == [["start", "town_a.ogg"]],
		"after loading the zone's track starts from the top, with no fade")
	m.pop(true)
	_check(_cmds(m).is_empty(), "pop-all with no playlist leaves the zone track alone")
	# Mute stops; un-mute restarts from the top.
	m.set_muted(true)
	_check(_cmds(m) == [["stop"]], "muting BGM stops the track")
	_check(m.enter_area(true, "field_b.ogg") == "held", "a zone change while muted plays nothing")
	m.set_muted(false)
	_check(_cmds(m) == [["start", "field_b.ogg"]], "un-muting starts the current zone's track from the top")

func _ambient(ab: GDScript) -> void:
	var entries := []
	for spec in [["bed.wav", 0, 0], ["bird.wav", 10, 20], ["gust.wav", 3, 3]]:
		var e := {"file": spec[0], "a": spec[1], "b": spec[2]}
		entries.append(e)
	var amb = ab.new()
	# EnvSoundTable.Entry is a class; a Dictionary answers .file/.a/.b too.
	var beds: PackedStringArray = amb.start(entries)
	_check(beds == PackedStringArray(["bed.wav"]), "a 0~0 entry is a looping bed")
	_check(amb.shots.size() == 2 and amb.shots[0].countdown == 10, "a one-shot's countdown starts at a")
	var roll := func(): return 7
	var played := []
	# bird: 10 -> 8 -> 6 -> 4 -> 2 (<3, plays at the tick after), then 7 % 10 + 10 = 17.
	for i in range(6):
		for s in amb.tick(roll):
			played.append("%s@%d" % [s.file, i])
	_check(played.has("bird.wav@4") and not played.has("bird.wav@3"), "a=10: counts 10, 8, 6, 4, 2 and plays on the fifth tick (~10 s): %s" % str(played))
	_check(amb.shots[0].countdown == 15, "then resets to rand() %% (b - a) + a = 7 %% 10 + 10 = 17, less 2 a tick after: %d" % amb.shots[0].countdown)
	_check(played.has("gust.wav@1") and not played.has("gust.wav@0"), "a == b != 0 (never in the data) does not divide by zero")
	var amb2 = ab.new()
	amb2.start(entries)
	var due: Array = amb2.advance(1.9, roll)
	_check(due.is_empty(), "the tick is 2 s: nothing at 1.9 s")
	due = amb2.advance(0.2, roll)
	_check(amb2.shots[0].countdown == 8, "one tick at 2 s takes 2 off")
	amb2.stop()
	_check(amb2.beds.is_empty() and amb2.shots.is_empty(), "stop clears the list")
	_check(not ab.is_night(-1.0) and not ab.is_night(4.0) and not ab.is_night(20.0) and not ab.is_night(12.0),
		"day is hour 4..20 inclusive, and 'no clock' is day")
	_check(ab.is_night(3.99) and ab.is_night(20.01) and ab.is_night(0.0), "night is h < 4 or h > 20")

func _ascii(s: String) -> PackedByteArray:
	return s.to_ascii_buffer()

func _env_table(et: GDScript) -> void:
	var day := PackedByteArray([0xB3, 0xB7])
	var night := PackedByteArray([0xB9, 0xE3])
	var b := PackedByteArray()
	b.append_array(_ascii("<1>\tZoneOne\t\t\r\n"))
	b.append_array(_ascii("//\t\"commented_out.ogg\"\r\n"))
	b.append_array(_ascii("\t\"Zone_One.ogg\"\t\t\r\n"))
	b.append_array(_ascii("\t<2>\t"))
	b.append_array(day)
	b.append_array(_ascii("\t\t\r\n"))
	b.append_array(_ascii("\t\t\t<3>\t\"bed_a.wav\"\t0~0\r\n"))
	b.append_array(_ascii("\t\t\t<3>\t\"bird a.wav\"  \t15~30\r\n"))
	b.append_array(_ascii("\t<2>\t"))
	b.append_array(night)
	b.append_array(_ascii("\t\t\r\n"))
	b.append_array(_ascii("\t\t\t<3>\t\"bed_n.wav\"\t0~0\r\n"))
	b.append_array(_ascii("<1>\tZoneTwo\r\n\t\"Two.ogg\"\r\n"))
	b.append_array(_ascii("/*\r\n<1>\tGhost\r\n\t\"ghost.ogg\"\r\n*/\r\n"))
	b.append_array(_ascii("<1>\tZoneTwo\r\n\t\"TwoAgain.ogg\"\r\n"))
	b.append_array(_ascii("<1>\tZoneThree\r\n\t\"Three.ogg\"\t3\r\n"))
	var zones: Dictionary = et.parse(b)
	_check(zones.size() == 3 and zones.has("ZoneOne") and zones.has("ZoneTwo") and zones.has("ZoneThree"), "three zones parse; the /* */ one does not (%s)" % str(zones.keys()))
	var one = zones.get("ZoneOne")
	_check(one != null and one.bgm == "Zone_One.ogg", "the music is the next NON-comment line's quoted name")
	_check(one != null and one.repeat == -1, "no repeat count means -1, loop for ever")
	_check(one != null and one.day.size() == 2 and one.night.size() == 1, "the CP949 day/night labels (B3 B7 / B9 E3) pick the lists")
	if one != null and one.day.size() == 2:
		_check(one.day[1].file == "bird a.wav" and one.day[1].a == 15 and one.day[1].b == 30, "a~b parses, and a quoted name keeps its space")
		_check(one.day[0].a == 0 and one.day[0].b == 0, "0~0 is a bed")
	var two = zones.get("ZoneTwo")
	_check(two != null and two.bgm == "TwoAgain.ogg" and two.repeat == -1, "a later duplicate zone replaces the earlier")
	var three = zones.get("ZoneThree")
	_check(three != null and three.bgm == "Three.ogg" and three.repeat == 3, "a repeat count after the name is read")
	var opt := "//IntroBGM = \"old.ogg\"\r\nIntroName = \"x\"\r\nIntroBGM = \"title_theme.ogg\"\r\n"
	_check(et.parse_intro_bgm(opt.to_ascii_buffer()) == "title_theme.ogg", "option.txt's live IntroBGM line is read, the commented one is not")
	_check(et.parse_intro_bgm("//IntroBGM = \"a.ogg\"\r\n".to_ascii_buffer()) == "", "no live IntroBGM line: none")

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
