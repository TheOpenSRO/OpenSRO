extends SceneTree

## Round 856: the state colour's guards (READ, FUN_009cd5e0; StateLook's
## header "THE COLOUR'S GUARDS"). A state bit's colour start (+0x48) and end
## (+0x4c) are left out while the object's body mode is 1 (berserk, 0x30BF
## kind 4) or its decoration kind is 2 (a 'mom' skill's decoration on: the
## Roc's frenzy); DN's end tests the body mode alone. The user: "keep the
## original". Driven through World3D's own handlers -- _on_object_status (the
## 0x3057), _on_state_changed (the 0x30BF) and _on_buff_started /
## _on_buff_ended (OpBuffStart / OpBuffEnd) -- on this player (the owner's
## client), another player's body (an observer's) and a monster (the Roc),
## each on a terrain tile's shared level material, rescanned by CharacterLight
## every frame. What is checked is the colour drawn on the meshes (TintProbe)
## and whose it is (BodyPulse.who), never only the books:
## - riding guards nothing (mounting writes neither byte): a rider's poison
##   draws and ends;
## - berserk, a state before it ending inside it (expiry; a pill curing one of
##   two): berserk's colour stays, and its end leaves no colour;
## - a state starting inside berserk draws no colour; berserk's end then
##   leaves none while the state runs, and the state's end none;
## - the clip speed and the aura are not guarded (FB inside berserk halves the
##   clip speed);
## - kind 2 (a 'mom' buff whose decoration draws its own SCT_MAT colour): the
##   frenzy's colour replaces a poison's, the poison's end inside leaves it,
##   the frenzy's end ends it; a poison inside draws none;
## - kind 2 with no colour of its own: a poison begun before and ended inside
##   keeps its colour (the original's quirk, built deliberately) until a later
##   colour call; DN's end is not kind-guarded (c:0x9cdb35);
## - a kept decoration's colour waits for its fade (300 ms) before it ends.
## Synthetic tables and materials, never game data. Run headless on the render
## box: `client/tools/remote_godot.sh tests`.

const BerserkLook = preload("res://scripts/effects/berserk_look.gd")

var _failures := 0
var _net: Node

const OWN := 4848
const OTHER := 5252
const ROC := 7777
const LEVEL := 153.0 / 384.0
const PS := 0x10
const BU := 0x8
const FB := 0x2
const DN := 0x2000
## The test skills: a 'mom' skill with a colour of its own (the frenzy's
## shape), one with none, and a plain buff whose decoration has a colour.
const MOM_MAT := 31102
const MOM_BARE := 31103
const MAT_BUFF := 31104
const FRENZY_C1 := Color8(170, 30, 0)
const DECO_C1 := Color8(1, 1, 50)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(90.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_net = root.get_node_or_null("NetClient")
	_check(_net != null, "the NetClient autoload is there")
	if _net != null:
		_tables()
		var world := _make_world()
		if world != null:
			_net.set("own_character_id", OWN)
			_net.set("current_character_name", "Aria")
			world.call("_sync_own_id")
			var catalog := SkillBuffCatalog.new(null)
			catalog.set_row({"id": MOM_MAT, "mom": true})
			catalog.set_row({"id": MOM_BARE, "mom": true})
			catalog.set_row({"id": MAT_BUFF, "mom": false})
			var board := HudBuffBoard.new(null, catalog)
			world.set("_hud_buff_board", board)
			var base := ShaderMaterial.new()
			base.shader = ObjectLoader.object_shader("solid")
			var player: Node3D = world.get("player")
			_give_skeleton(player, base)
			var other := Node3D.new()
			world.add_child(other)
			_give_skeleton(other, base)
			(world.get("_other_bodies") as Dictionary)[OTHER] = other
			var roc := Node3D.new()
			world.add_child(roc)
			_give_skeleton(roc, base)
			(world.get("_monster_bodies") as Dictionary)[ROC] = roc
			_test_unit()
			for view in [[OWN, player, "the owner's client"], [OTHER, other, "an observer's client"]]:
				_test_riding(world, int(view[0]), view[1], String(view[2]))
				_test_berserk(world, int(view[0]), view[1], String(view[2]))
			_test_frenzy(world, roc)
			_test_deco_fade(world, roc)
			world.set("_hud_buff_board", null)
			board.free()
			SkillEffects.effect_factory = Callable()
			SkillEffects.reset()
			StateLook.clear()
			BerserkLook.clear()
			root.remove_child(world)
			world.free()
		BerserkLook.effect_factory = Callable()
		BerserkLook.sound_player = Callable()
		_net.set("own_character_id", -1)
		(_net.get("body_modes") as Dictionary).clear()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- the pure rule ---------------------------------------------------------------

func _test_unit() -> void:
	var none := StateLook.guard_of(0, 0)
	var berserk := StateLook.guard_of(1, 0)
	var mom := StateLook.guard_of(0, 2)
	var other_modes := true
	for mode in [0, 2, 3, 4, 6, 7]:
		other_modes = other_modes and not StateLook.colour_guarded(PS, true, StateLook.guard_of(mode, 0))
	_check(other_modes, "body modes other than 1 (2 untouchable, 4 stealth ...) guard nothing")
	_check(not StateLook.colour_guarded(PS, true, StateLook.guard_of(0, 1)), "kind 1 ('pmhp' 100) guards nothing")
	var all_on := true
	for v in StateLook.TINTS:
		all_on = all_on and StateLook.colour_guarded(int(v), true, berserk) and StateLook.colour_guarded(int(v), true, mom) \
			and StateLook.colour_guarded(int(v), false, berserk) and not StateLook.colour_guarded(int(v), true, none)
	_check(all_on, "every colour bit's start and end is guarded by body mode 1 and kind 2, by neither unguarded")
	_check(not StateLook.colour_guarded(DN, false, mom) and StateLook.colour_guarded(DN, false, berserk)
		and StateLook.colour_guarded(BU, false, mom),
		"DN's end tests the body mode alone (c:0x9cdb35); BU's end tests both")
	var w := StateLook.walk(0, FB, {}, berserk)
	_check(w["pulse"] == null and float(w["speed"]) == StateLook.SPEED_FB and (w["on"] as Array) == [1],
		"FB inside berserk: no colour call, the clip speed 0.5 and the aura's start stay")
	w = StateLook.walk(0, 0x1, {}, mom)
	_check(bool(w["frozen"]) and (w["on"] as Array) == [0], "FZ inside the frenzy still freezes")

# --- World3D paths -----------------------------------------------------------------

func _status(world: Node, id: int, mask: int, kind := 0) -> void:
	var st := StatusNet.ObjectStatus.new()
	st.owner_kind = kind
	st.owner_id = id
	st.mask = mask
	world.call("_on_object_status", st)

func _body_mode(world: Node, id: int, value: int) -> void:
	var change := WorldNet.StateChange.new()
	change.object_id = id
	change.kind = WorldNet.STATE_KIND_BODY_MODE
	change.value = value
	WorldNet.note_body_mode(_net.get("body_modes"), change)
	if id == OWN:
		_net.set("own_body_mode", value)
	world.call("_on_state_changed", change)
	BerserkLook.tick(0.25)
	BerserkLook.tick(0.25)

var _token := 500

func _buff(world: Node, id: int, kind: int, skill: int) -> int:
	_token += 1
	var bs := SkillNet.BuffStart.new()
	bs.owner_id = id
	bs.owner_kind = kind
	bs.skill_id = skill
	bs.token = _token
	bs.duration_ms = 60000
	bs.remaining_ms = 60000
	world.call("_on_buff_started", bs)
	return _token

func _buff_end(world: Node, id: int, kind: int, token: int) -> void:
	var be := SkillNet.BuffEnd.new()
	be.owner_id = id
	be.owner_kind = kind
	be.tokens.append(token)
	world.call("_on_buff_ended", be)

## A frame of the game's: the pulse steps and CharacterLight rescans the body.
func _frame(body: Node3D) -> void:
	BodyPulse.tick(1.0 / 60.0)
	CharacterLight.set_on(body, LEVEL, true)
	BodyPulse.tick(1.0 / 60.0)

func _frames(body: Node3D, n := 6) -> void:
	for i in n:
		_frame(body)

func _drawn(body: Node3D) -> int:
	return int(TintProbe.measure(body)["tinted"])

## The colour the body's mesh draws, its slot's owner and the shared count.
func _look(body: Node3D) -> String:
	_frame(body)
	return "%s (%d mesh(es) coloured, %d shared)" % [BodyPulse.who(body) if BodyPulse.who(body) != "" else "none",
		_drawn(body), TintProbe.shared_tinted()]

func _is(body: Node3D, who: String) -> bool:
	_frame(body)
	if TintProbe.shared_tinted() != 0:
		return false
	if who == "":
		return BodyPulse.who(body) == "" and _drawn(body) == 0
	return BodyPulse.who(body) == who and _drawn(body) >= 1

func _test_riding(world: Node, id: int, body: Node3D, who: String) -> void:
	# Mounting writes neither +0x2c2 nor +0x448 (READ): a rider's colour is
	# drawn and ends as anyone's.
	(world.get("_riders") as Dictionary)[id] = 999
	_status(world, id, PS)
	_frames(body)
	_check(_is(body, "state"), "%s, a poison while riding: drawn (%s)" % [who, _look(body)])
	_status(world, id, 0)
	_check(_is(body, ""), "%s, the poison's expiry while riding: no colour (%s)" % [who, _look(body)])
	(world.get("_riders") as Dictionary).erase(id)

func _test_berserk(world: Node, id: int, body: Node3D, who: String) -> void:
	# A poison, then berserk; the poison expires inside; berserk ends.
	_status(world, id, PS)
	_frames(body)
	_check(_is(body, "state"), "%s, a poison: its colour (%s)" % [who, _look(body)])
	_body_mode(world, id, 1)
	_frames(body)
	_check(_is(body, "berserk"), "%s, berserk on: berserk's colour over the poison's (%s)" % [who, _look(body)])
	_status(world, id, 0)
	_frames(body)
	_check(_is(body, "berserk"), "%s, the poison expiring inside berserk: berserk's colour stays (guarded +0x4c; %s)" % [who, _look(body)])
	_body_mode(world, id, 0)
	_check(_is(body, ""), "%s, berserk's end: no colour (%s)" % [who, _look(body)])

	# A burn and a poison, then berserk; the pill cures the poison inside.
	_status(world, id, BU)
	_status(world, id, BU | PS)
	_body_mode(world, id, 1)
	_status(world, id, BU)
	_frames(body)
	_check(_is(body, "berserk"), "%s, a pill curing the poison inside berserk: berserk's colour stays (%s)" % [who, _look(body)])
	_body_mode(world, id, 0)
	_check(_is(body, ""), "%s, berserk's end with the burn still on: no colour (the original's; %s)" % [who, _look(body)])
	_status(world, id, 0)
	_check(_is(body, ""), "%s, the burn's end after: no colour (%s)" % [who, _look(body)])

	# Berserk first; a poison inside draws nothing; it outlasts berserk.
	_body_mode(world, id, 1)
	_status(world, id, PS)
	_frames(body)
	_check(_is(body, "berserk"), "%s, a poison starting inside berserk: no poison colour (guarded +0x48; %s)" % [who, _look(body)])
	_body_mode(world, id, 0)
	_frames(body)
	_check(_is(body, ""), "%s, berserk's end with the poison on: no colour (%s)" % [who, _look(body)])
	_status(world, id, 0)
	_check(_is(body, ""), "%s, the poison's end after: no colour (%s)" % [who, _look(body)])

	# Frostbite inside berserk: no colour, but the clip speed is halved.
	_body_mode(world, id, 1)
	_status(world, id, FB)
	var key := "character:%d" % id
	var look: Dictionary = (world.get("_state_looks") as Dictionary).get(key, {})
	_check(_is(body, "berserk") and is_equal_approx(StateLook.clip_speed(look), StateLook.SPEED_FB),
		"%s, frostbite inside berserk: berserk's colour, the clip speed %.2f" % [who, StateLook.clip_speed(look)])
	_status(world, id, 0)
	_body_mode(world, id, 0)
	_check(_is(body, ""), "%s, frostbite and berserk over: no colour" % who)

func _test_frenzy(world: Node, roc: Node3D) -> void:
	var kind := SkillNet.OWNER_MONSTER
	# The frenzy's own colour (its decoration's SCT_MAT): a poison before it.
	_status(world, ROC, PS, kind)
	_frames(roc)
	_check(_is(roc, "state"), "the Roc, a poison: its colour (%s)" % _look(roc))
	var t := _buff(world, ROC, kind, MOM_MAT)
	var c = BodyPulse.colour_of(roc)
	_frames(roc)
	_check(_is(roc, SkillEffects.DECO_WHO) and c != null and (c as Color).is_equal_approx(Color(FRENZY_C1, 1.0)),
		"the Roc, the frenzy starts: its own colour over the poison's (%s, %s)" % [_look(roc), c])
	_status(world, ROC, 0, kind)
	_frames(roc)
	_check(_is(roc, SkillEffects.DECO_WHO), "the Roc, the poison's end inside the frenzy: the frenzy's colour stays (kind 2; %s)" % _look(roc))
	_status(world, ROC, BU, kind)
	_frames(roc)
	_check(_is(roc, SkillEffects.DECO_WHO), "the Roc, a burn starting inside the frenzy: no burn colour (%s)" % _look(roc))
	_buff_end(world, ROC, kind, t)
	_frames(roc)
	_check(_is(roc, ""), "the Roc, the frenzy's end: no colour, the burn still on (%s)" % _look(roc))
	_status(world, ROC, 0, kind)
	_check(_is(roc, ""), "the Roc, the burn's end after: no colour (%s)" % _look(roc))

	# A 'mom' decoration with no colour of its own: the poison's colour is
	# kept through its end inside (the original's quirk, built deliberately).
	_status(world, ROC, PS, kind)
	var t2 := _buff(world, ROC, kind, MOM_BARE)
	_status(world, ROC, 0, kind)
	_frames(roc)
	_check(_is(roc, "state"), "kind 2 with no colour: a poison begun before and ended inside keeps its colour (%s)" % _look(roc))
	_buff_end(world, ROC, kind, t2)
	_frames(roc)
	_check(_is(roc, "state"), "... and still after the 'mom' decoration's end: nothing calls +0x4c (%s)" % _look(roc))
	_status(world, ROC, BU, kind)
	_status(world, ROC, 0, kind)
	_check(_is(roc, ""), "... until the next colour call: a burn's start and end leave no colour (%s)" % _look(roc))

	# DN's end is not kind-guarded (c:0x9cdb35).
	_status(world, ROC, DN, kind)
	var t3 := _buff(world, ROC, kind, MOM_BARE)
	_status(world, ROC, 0, kind)
	_check(_is(roc, ""), "kind 2: a darkness begun before ends its colour inside (DN's end reads the body mode alone; %s)" % _look(roc))
	_buff_end(world, ROC, kind, t3)

func _test_deco_fade(world: Node, roc: Node3D) -> void:
	var kind := SkillNet.OWNER_MONSTER
	var t := _buff(world, ROC, kind, MAT_BUFF)
	var c = BodyPulse.colour_of(roc)
	_frames(roc)
	_check(_is(roc, SkillEffects.DECO_WHO) and c != null and (c as Color).is_equal_approx(Color(DECO_C1, 1.0)),
		"a buff whose decoration has SCT_MAT draws its colour (%s, %s)" % [_look(roc), c])
	_buff_end(world, ROC, kind, t)
	SkillEffects.tick(0.1)
	_check(_is(roc, SkillEffects.DECO_WHO), "its end: the colour holds through the decoration's 300 ms fade (100 ms in; %s)" % _look(roc))
	SkillEffects.tick(0.25)
	_check(_is(roc, ""), "... and is off when the fade is over (350 ms; %s)" % _look(roc))

# --- tables, bodies, the world -------------------------------------------------------

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _skill_row(id: int, code: String, group: String) -> String:
	return "1\t%d\t%d\t%s\tname\t%s\t0\t1\t0\t0\t0\r\n" % [id, id, code, group]

func _row(id: String, obj: String, fade: String, script: String) -> String:
	var cols: Array = ["label", id, "ACT_L", "0", "FALSE", "none", "MOB_BASE", "0", "0", "0", "0", "1",
		fade, "AT_LOOP", "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", "none", obj, "none", "0,0,0",
		"none", "0,0,0", "none", "0", script, "none", "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

func _tables() -> void:
	var sd := _skill_row(MOM_MAT, "TEST_FRENZY_A", "TEST_FRENZY")
	sd += _skill_row(MOM_BARE, "TEST_MOM_BARE_A", "TEST_MOM_BARE")
	sd += _skill_row(MAT_BUFF, "TEST_MAT_BUFF_A", "TEST_MAT_BUFF")
	SkillAudio.set_tables(SkillAudio.parse_skills(_utf16(sd)), {})
	var text := "#section skilleffectset\r\n"
	text += _row("TEST_FRENZY", "none", "0,0", "SCT_MAT,170,30,0,235,155,0,1000")
	text += _row("TEST_MOM_BARE", "none", "0,0", "none")
	text += _row("TEST_MAT_BUFF", "none", "300,300", "SCT_MAT,1,1,50,50,1,1,5000")
	SkillEffects.reset()
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)), {})
	SkillEffects.effect_factory = func(_p: String): return null
	SkillEffects.quality = SkillEffects.EFFECTS_ALL
	var bt: Array = ["label", "SYSTEM_CH_HWANMODE", "ACT_L", "0", "FALSE", "none", "CHAR_BASE", "0", "0", "0", "0", "1",
		"0,0", "AT_LOOP", "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", "fx\\", "keep.efp", "Bip01", "0,0,0",
		"none", "0,0,0", "none", "0", "SCT_MAT,10,20,30,110,120,130,1000", "none", "none"]
	BerserkLook.set_rows(BerserkLook.parse_rows(_utf16("#section\tskilleffectset\r\n" + "\t".join(PackedStringArray(bt)) + "\r\n")))
	BerserkLook.effect_factory = func(_path: String): return null
	BerserkLook.sound_player = func(_path: String, _pos) -> void: pass

func _give_skeleton(body: Node3D, base: Material) -> void:
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	body.add_child(skel)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = ObjectLight.with_object_color(base, LEVEL)
	skel.add_child(mi)
	body.set_meta(CharacterLight.META_VALUE, LEVEL)

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	SkillEffects.own_body = world.get("player")
	return world
