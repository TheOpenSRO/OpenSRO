extends SceneTree

## Exercises the animation-fired sounds against SYNTHETIC data only -- a
## hand-built .bsr sound section, a synthetic navmesh tile map and tile
## table, synthetic effect rows -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/audio_anim/anim_sounds_test.gd`
##
## Loads its subjects by path (not by class_name), so the same file run
## against an older checkout's scripts fails loudly on what is missing.

var BsrReaderScript = load("res://scripts/bsr/bsr_reader.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

# --- byte builders ---------------------------------------------------------

func _u32(buf: PackedByteArray, v: int) -> void:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	buf.append_array(b)

func _str(buf: PackedByteArray, s: String) -> void:
	var a := s.to_ascii_buffer()
	_u32(buf, a.size())
	buf.append_array(a)

func _zeros(buf: PackedByteArray, n: int) -> void:
	var z := PackedByteArray()
	z.resize(n)
	buf.append_array(z)

## A sound mod: header, one track list keyed `default`. tracks: [[key, name]]
## or [] entries meaning a flag-0 track.
func _sound_mod(buf: PackedByteArray, tracks: Array) -> void:
	_u32(buf, 0x50000)
	_zeros(buf, 28)
	_u32(buf, 1)
	_zeros(buf, 44)
	_str(buf, "default")
	_u32(buf, tracks.size())
	for t in tracks:
		if (t as Array).is_empty():
			_u32(buf, 0)
			continue
		_u32(buf, 1)
		_str(buf, "prim\\snd\\player\\x.wav")
		_u32(buf, int(t[0]))
		_str(buf, String(t[1]))

func _set_head(buf: PackedByteArray, kind: int, action_type: int, name: String, mods: int) -> void:
	_u32(buf, kind)
	_u32(buf, action_type)
	_str(buf, name)
	_u32(buf, mods)

## A file: 0x44 header bytes with the sound pointer at 0x24, then the
## section, then a CResAttachable/CResChar tail.
func _build(bad_track_count: bool = false) -> Dictionary:
	var buf := PackedByteArray()
	_zeros(buf, 0x44)
	buf.encode_s32(0x24, 0x44)
	# First list: two sets keyed by name.
	_u32(buf, 2)
	_set_head(buf, 2, -1, "ambient", 1)
	_u32(buf, 0x60000)  # DyVertex: header only
	_zeros(buf, 28)
	_set_head(buf, 0, -1, "x_runforward", 1)
	_sound_mod(buf, [[289, "snd_run"]])
	# Second list: sets keyed by (type, group).
	_u32(buf, 6)
	_set_head(buf, 1, 7, "default", 3)
	# A particle mod (one entry, 4th flag byte set -> 12 more bytes) and a
	# material mod (flag bit 4 -> a second list) before the sound mod.
	_u32(buf, 0x30000)
	_zeros(buf, 28)
	_u32(buf, 1)
	_u32(buf, 0)
	_str(buf, "a.efp")
	_str(buf, "Bip01")
	_zeros(buf, 12)
	_u32(buf, 0)
	buf.append_array(PackedByteArray([0, 0, 0, 1]))
	_zeros(buf, 12)
	_u32(buf, 0x00000)
	_zeros(buf, 28)
	_u32(buf, 0)
	_u32(buf, 4)
	_u32(buf, 0)
	_u32(buf, 1)
	_zeros(buf, 20)
	_u32(buf, 2)
	_zeros(buf, 16)
	_zeros(buf, 36)
	_sound_mod(buf, [[289, "snd_run1"], [], [619, "snd_run1"]])
	_set_head(buf, 1, 0, "default", 1)
	_sound_mod(buf, [[100, "snd_stand"]])
	_set_head(buf, 1, 3, "default", 1)
	_sound_mod(buf, [[0, "voc_moan"]])
	_set_head(buf, 1, 4, "default", 1)
	_sound_mod(buf, [[0, "voc_death"], [1500, "snd_death"]])
	_set_head(buf, 1, 2, "sword", 1)
	var swing := [[200, "snd_swing1"], [200, "voc_shout1"], [300, "voc_emo"], [310, "snd_stand5"]]
	if bad_track_count:
		for i in range(12):
			swing.append([400 + i, "snd_swing2"])
	_sound_mod(buf, swing)
	_set_head(buf, 1, 5, "sword", 0)
	var section_end := buf.size()
	# The attachment tail: three words, one pair, combo 0.
	_u32(buf, -1)
	_u32(buf, 13)
	_u32(buf, 0)
	_u32(buf, 1)
	_u32(buf, 2)
	_u32(buf, 6)
	_u32(buf, 0)
	return {"data": buf, "end": section_end}

func _anim(duration: int, action_type: int, group: String) -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.duration_ms = duration
	a.set_meta("bsr_entry", [action_type, group])
	return a

func _init() -> void:
	var AnimSoundsScript = load("res://scripts/audio_anim/anim_sounds.gd")
	var StubScript = load("res://scripts/audio_anim/anim_sound_stub.gd")
	var SeamScript = load("res://scripts/audio_anim/anim_sound_seam.gd")
	var TableScript = load("res://scripts/audio/sound_table.gd")
	var loaded := true
	for sc in [AnimSoundsScript, StubScript, SeamScript, TableScript, BsrReaderScript]:
		loaded = loaded and sc != null and (sc as GDScript).can_instantiate()
	_check(loaded, "the audio_anim scripts and BsrReader load and compile")
	var bsr_methods: Array = []
	for m in (BsrReaderScript as GDScript).get_script_method_list():
		bsr_methods.append(String(m["name"]))
	_check("parse_sound_section" in bsr_methods, "BsrReader parses the sound section")
	if _failures > 0:
		print("FAILURES: %d" % _failures)
		quit(1)
		return

	# --- the parse -----------------------------------------------------------
	var built := _build()
	var data: PackedByteArray = built["data"]
	var section = BsrReaderScript.parse_sound_section(data, 0x44)
	_check(section != null, "the synthetic sound section parses")
	if section == null:
		print("FAILURES: %d" % _failures)
		quit(1)
		return
	_check(int(section["end"]) == int(built["end"]), "the section is consumed exactly (end %d, want %d)" % [section["end"], built["end"]])
	_check(BsrReaderScript.attachable_tail_end(data, section["end"]) == data.size(), "the attachment tail after it ends at EOF")
	_check((section["by_clip"] as Array).size() == 2 and (section["by_type"] as Array).size() == 6, "2 sets by clip, 6 by type")
	var mods: Dictionary = section["mods"]
	_check(int(mods.get(0x50000, 0)) == 6 and int(mods.get(0x30000, 0)) == 1 and int(mods.get(0x00000, 0)) == 1 and int(mods.get(0x60000, 0)) == 1,
		"mod kinds counted: 6 sound, 1 particle, 1 material, 1 dyvertex (%s)" % str(mods))
	var obj = BsrReaderScript.ParsedObject.new()
	BsrReaderScript._attach_sound_sets(obj, data)
	var run = obj.sound_set_for(7, "default")
	_check(run != null and run.tracks.size() == 2 and run.empty_tracks == 1, "run set: two tracks, one flag-0 track dropped")
	_check(run != null and run.tracks[0].key_ms == 289 and run.tracks[1].key_ms == 619 and run.tracks[0].name == "snd_run1",
		"run tracks at 289 and 619, snd_run1")
	_check(obj.sound_set_for(7, "sword") == null, "no fallback to another group's set")
	_check(obj.sound_sets_by_clip.has("x_runforward"), "the clip-keyed set is kept by name")
	var bad := _build(true)
	_check(BsrReaderScript.parse_sound_section(bad["data"], 0x44) == null, "16 tracks on one animation is refused (MAX_SOUND_TRACK_PER_ANI 15)")
	var cut: PackedByteArray = (built["data"] as PackedByteArray).slice(0, int(built["end"]) - 3)
	_check(BsrReaderScript.parse_sound_section(cut, 0x44) == null, "a truncated section is refused, not read past the end")

	# --- firing a clip ---------------------------------------------------------
	var stub = StubScript.new()
	SeamScript.set_sink(stub)
	var sounds = AnimSoundsScript.new()
	sounds.print_lines = false
	var clock := [0]
	sounds.now_msec = func() -> int: return clock[0]
	var skel := Node3D.new()
	var owner = AnimSoundsScript.Owner.new()
	owner.label = "player"
	owner.is_pc = true
	owner.token = "PCM_FIGHTER"
	owner.parsed = obj
	owner.weapon_kind = 2
	var material := [3]
	owner.material = func() -> int: return material[0]
	sounds.register(skel, owner)

	var run_anim := _anim(666, 7, "default")
	# A loop swapped in mid-cycle fires nothing on its first frame.
	sounds.advance(skel, run_anim, 0.0, 300.0, true)
	_check(stub.keys().is_empty(), "a loop joined at 300 ms fires nothing at once")
	sounds.advance(skel, run_anim, 0.0, 600.0, true)
	_check(stub.keys().is_empty(), "300 -> 600 passes no key")
	sounds.advance(skel, run_anim, 0.0, 650.0, true)
	_check(stub.keys() == ["PLAYER:snd_run1:-:FIELD:STONE:-"], "619 fires the STONE footstep (%s)" % str(stub.keys()))
	sounds.advance(skel, run_anim, 0.0, 10.0, true)
	sounds.advance(skel, run_anim, 0.0, 290.0, true)
	_check(stub.keys().size() == 2 and stub.keys()[1] == "PLAYER:snd_run1:-:FIELD:STONE:-", "the wrap and 289 fire the next one")
	_check(sounds.fired.size() == 2 and int(sounds.fired[1][1]) == 289, "fired at key time 289")

	# The material: a terrain tile (GRASS) against an object floor (DIRT).
	var region := NvmReader.ParsedRegion.new()
	for i in range(NvmReader.TILE_COUNT):
		var tile := NvmReader.Tile.new()
		tile.cell_index = 0
		tile.texture_id = 1 if i == 5 * NvmReader.TILE_MAP_SIDE + 3 else 0
		region.tiles.append(tile)
	var table := TileIndexReader.parse((TileIndexReader.MAGIC + "\n2\n" +
		'00000 0x00000000 "a" "a.ddj"\n00001 0x0000000a "b" "b.ddj"\n').to_ascii_buffer())
	_check(table != null, "synthetic tile table parses")
	var on_tile: int = AnimSoundsScript.material_at(region, 3 * 20.0 + 5.0, 5 * 20.0 + 5.0, NavGraph.ON_TERRAIN, table)
	var on_floor: int = AnimSoundsScript.material_at(region, 3 * 20.0 + 5.0, 5 * 20.0 + 5.0, 4, table)
	var neighbour: int = AnimSoundsScript.material_at(region, 4 * 20.0 + 5.0, 5 * 20.0 + 5.0, NavGraph.ON_TERRAIN, table)
	_check(on_tile == 10, "the terrain tile's tile2d type is GRASS (%d)" % on_tile)
	_check(on_floor == 0, "the same spot on an object's floor is DIRT (%d)" % on_floor)
	_check(neighbour == 0, "the next tile is the table's DIRT row (%d)" % neighbour)
	_check(AnimSoundsScript.material_at(region, -1.0, 5.0, NavGraph.ON_TERRAIN, table) == -1, "off the region: no cell")
	material[0] = on_tile
	sounds.advance(skel, run_anim, 0.0, 630.0, true)
	material[0] = on_floor
	sounds.advance(skel, run_anim, 0.0, 280.0, true)
	sounds.advance(skel, run_anim, 0.0, 295.0, true)
	var k: Array = stub.keys()
	_check(k[k.size() - 2] == "PLAYER:snd_run1:-:FIELD:GRASS:-" and k[k.size() - 1] == "PLAYER:snd_run1:-:FIELD:DIRT:-",
		"grass tile then object floor: GRASS, DIRT (%s)" % str(k.slice(k.size() - 2)))
	material[0] = -1
	var before: int = stub.keys().size()
	sounds.advance(skel, run_anim, 0.0, 630.0, true)
	_check(stub.keys().size() == before, "no navmesh cell: no footstep")

	# A one-shot fires from 0, and its swing is keyed by the weapon.
	var swing := _anim(900, 2, "sword")
	stub.calls.clear()
	sounds.advance(skel, swing, 5.0, 0.0, false)
	sounds.advance(skel, swing, 5.0, 250.0, false)
	sounds.advance(skel, swing, 5.0, 900.0, false)
	_check(stub.keys() == ["PLAYER:snd_swing1:-:SWORD:-:-"],
		"swing fires SWORD once; voc_shout1 (skill-keyed), voc_emo (no-op), snd_stand5 (no handler) stay silent (%s)" % str(stub.keys()))
	owner.hwan = true
	sounds.advance(skel, swing, 6.0, 250.0, false)
	_check(stub.keys()[-1] == "PLAYER:snd_swing3:-:HWAN:SWORD:-", "berserk plays the hwan swing3 key")
	owner.hwan = false
	owner.weapon_kind = AnimSoundsScript.WEAPON_NONE
	sounds.advance(skel, swing, 7.0, 250.0, false)
	_check(stub.keys()[-1] == "PLAYER:snd_swing1:-:PUNCH:-:-", "an empty hand swings PUNCH")
	owner.weapon_kind = AnimSoundsScript.WEAPON_UNKNOWN
	before = stub.keys().size()
	sounds.advance(skel, swing, 8.0, 250.0, false)
	_check(stub.keys().size() == before, "an unknown weapon swings silently")

	# Hurt and death voices, with the player's own sound object.
	sounds.advance(skel, _anim(500, 3, "default"), 9.0, 10.0, false)
	_check(stub.keys()[-1] == "PCM_FIGHTER:voc_moan:-:NORMAL:-:-", "hit: NORMAL moan")
	owner.critical = true
	sounds.advance(skel, _anim(500, 3, "default"), 10.0, 10.0, false)
	_check(stub.keys()[-1] == "PCM_FIGHTER:voc_moan:-:CRITYCAL:-:-", "a critical hit: CRITYCAL moan")

	# --- a monster ------------------------------------------------------------
	var mob_skel := Node3D.new()
	var mob = AnimSoundsScript.Owner.new()
	mob.label = "monster 1"
	mob.token = "MOB_MANGNYANG"
	mob.parsed = obj
	sounds.register(mob_skel, mob)
	stub.calls.clear()
	sounds.advance(mob_skel, run_anim, 0.0, 280.0, true)
	sounds.advance(mob_skel, run_anim, 0.0, 300.0, true)
	sounds.advance(mob_skel, swing, 1.0, 0.0, false)
	sounds.advance(mob_skel, swing, 1.0, 400.0, false)
	var die := _anim(2000, 4, "default")
	sounds.advance(mob_skel, die, 2.0, 0.0, false)
	sounds.advance(mob_skel, die, 2.0, 1600.0, false)
	_check(stub.keys() == ["MOB_MANGNYANG:snd_run1:-:-:-:-", "MOB_MANGNYANG:voc_death:-:-:-:-", "MOB_MANGNYANG:snd_death:-:-:-:-"],
		"monster: material-less footstep, no swing (no skill code), voc_death at 0, snd_death at 1500 (%s)" % str(stub.keys()))
	_check(AnimSoundsScript.key_for(mob, "snd_swing1")["key"] == "", "a monster's swing is not keyed without its skill")

	# --- the idle and the blank counter ----------------------------------------
	var rows_stub = StubScript.new()
	rows_stub.rows["MOB_MANGNYANG:snd_stand:-:-:-:-"] = [{"file": "stand.wav", "blank": 2}]
	SeamScript.set_sink(rows_stub)
	var stand := _anim(1000, 0, "default")
	sounds.advance(mob_skel, stand, 3.0, 50.0, true)
	for cycle in range(6):
		sounds.advance(mob_skel, stand, 3.0, 500.0, true)
		sounds.advance(mob_skel, stand, 3.0, 50.0, true)
	_check(rows_stub.keys().size() == 6, "the idle's snd_stand reaches play_key every loop (%d)" % rows_stub.keys().size())
	_check(rows_stub.sounded.size() == 2, "with blank 2 it sounds twice in six loops: the 1st and the 4th (%d)" % rows_stub.sounded.size())

	# --- not registered: silent -------------------------------------------------
	var doll := Node3D.new()
	var n_before: int = rows_stub.calls.size()
	sounds.advance(doll, stand, 0.0, 50.0, true)
	sounds.advance(doll, stand, 0.0, 500.0, true)
	_check(rows_stub.calls.size() == n_before, "a body that is not registered (the paper doll, NPCs) is silent")

	# --- the log is rate-limited ------------------------------------------------
	clock[0] = 2000
	var lines_before: int = sounds.lines.size()
	for i in range(3):
		sounds.dispatch(mob, obj.sound_set_for(4, "default").tracks[0], "4:default")
	clock[0] = 5000
	sounds.dispatch(mob, obj.sound_set_for(4, "default").tracks[0], "4:default")
	var new_lines: Array = sounds.lines.slice(lines_before)
	_check(new_lines.size() == 2 and String(new_lines[1]).contains("(+2 since the last line)"),
		"one AUDIO line per key per second, with the swallowed count (%s)" % str(new_lines))

	# --- the sound object map -----------------------------------------------------
	var text := "#section\tcharacterInfo\t\t\r\n//code\tname\r\nMOB_CH_MANGNYANG\tMOB_MANGNYANG\t2\r\nNPC_CH_SMITH\tPLAYER\r\nMOB_CH_MANGNYANG\tOTHER\r\n#section\tskilleffectset\r\nX\tY\r\n"
	var utf16 := PackedByteArray([0xFF, 0xFE])
	utf16.append_array(text.to_utf16_buffer())
	# The core's characterInfo map (SoundTable.sound_object reads it through
	# this parser) gives the sound objects this round's keys are built from.
	# A code written twice takes its later row there (the core's choice).
	var map: Dictionary = TableScript.parse_character_info(utf16)
	_check(map.size() == 2 and map.get("MOB_CH_MANGNYANG") == "OTHER" and map.get("NPC_CH_SMITH") == "PLAYER" and not map.has("X"),
		"characterInfo through the core: codes -> sound objects, other sections ignored (%s)" % str(map))
	# The keys this round builds are spelled as the core's make_key spells them.
	_check(TableScript.make_key("PLAYER", "SND_RUN1", "-", "FIELD", "DIRT") == "PLAYER:snd_run1:-:FIELD:DIRT:-",
		"make_key lowercases the handle, as the table stores it")
	SeamScript.set_sink(null)

	skel.free()
	mob_skel.free()
	doll.free()
	if _failures > 0:
		print("FAILURES: %d" % _failures)
		quit(1)
	else:
		print("ALL PASS")
		quit(0)
