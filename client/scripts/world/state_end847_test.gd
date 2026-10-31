extends SceneTree

## Round 847 lane B: "status effects ... linger even after it's been removed
## naturally or through pills ... it eventually goes away but it takes
## awhile". Every way a state ends reaches the client as the same 0x3057
## mask with the state's bit gone (the server's half is
## server/internal/session/status847_test.go): the expiry, the universal pill,
## the purification pill, a death, a renewal and its end. Driven through
## World3D's own _on_object_status on a World3D.tscn whose frame hooks do
## nothing (client_review785_test.gd's pattern), on this player (the owner)
## and on another player's body (what an observer draws), with synthetic
## tables and effects -- never game data. READ (IDecoSkill::FUN_00a4db00 ->
## FUN_00a48190, CIDecoSkill::vslot_014): the state's PARAM_ aura fades out
## over its row's Fade (300 ms on every PARAM_ row, MEASURED) and is freed;
## its colour pulse ends at once (vtable +0x4c). Before round 847 the aura was
## only let go and played its particles out (0.5-4 s; confusion's loop never
## ends by itself: 30 s), so every "gone" check here FAILs on f2a20b92.
## Run headless on the render box: `client/tools/remote_godot.sh tests`.

var _failures := 0
var _net: Node
var _made: Array = []
var _tex: Texture2D = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))

const OWN := 4747
const OTHER := 5151

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
			var player: Node3D = world.get("player")
			_give_skeleton(player)
			var other := Node3D.new()
			world.add_child(other)
			_give_skeleton(other)
			(world.get("_other_bodies") as Dictionary)[OTHER] = other
			for view in [[OWN, player, "the owner"], [OTHER, other, "an observer"]]:
				_test_ends(world, int(view[0]), view[1], String(view[2]))
			_test_tables()
			SkillEffects.reset()
			StateLook.clear()
			root.remove_child(world)
			world.free()
		_net.set("own_character_id", -1)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- the end paths ------------------------------------------------------------

func _status(world: Node, id: int, mask: int) -> void:
	var st := StatusNet.ObjectStatus.new()
	st.owner_kind = 0
	st.owner_id = id
	st.mask = mask
	world.call("_on_object_status", st)

## The aura effects made for a file since `_made` was cleared.
func _made_named(name: String) -> Array:
	var out: Array = []
	for m in _made:
		if m[0] == name and is_instance_valid(m[1]):
			out.append(m[1])
	return out

func _gone(fx) -> bool:
	return fx == null or not is_instance_valid(fx) or (fx as Node).is_queued_for_deletion()

## A state ends (its bit leaves the mask): the same frame its pulse is gone
## and its aura is no longer kept; 150 ms on it is half faded; 300 ms on, the
## row's Fade, it is gone -- without one step of its own particles.
func _ends(world: Node, id: int, body: Node3D, on_mask: int, off_mask: int, file: String, tinted: bool, what: String) -> void:
	_made.clear()
	_status(world, id, on_mask)
	var fx := _made_named(file)
	_check(fx.size() == 1 and (fx[0] as EfpEffect).loop and (not tinted or StateLook.tinted(body)),
		"%s: the state's aura is kept%s" % [what, " and its body pulses" if tinted else ""])
	if fx.size() != 1:
		return
	var e := fx[0] as EfpEffect
	var t0: int = SkillEffects._now()
	_status(world, id, off_mask)
	_check(not _gone(e) and not e.loop and e.end_fade_ms == 300, "%s: at the end it is let go and fades (Fade 300)" % what)
	if tinted:
		_check(not StateLook.tinted(body), "%s: its pulse ends with the message" % what)
	SkillEffects.process(t0 + 150)
	_check(not _gone(e) and e.alpha > 100 and e.alpha < 160, "%s: 150 ms on it is half faded (alpha %d)" % [what, e.alpha])
	SkillEffects.process(t0 + 300)
	_check(_gone(e), "%s: 300 ms on, the row's Fade, it is gone" % what)
	_check(not (world.get("_abnormal_states") as Dictionary).has("character:%d" % id) or off_mask != 0,
		"%s: the book no longer holds the state" % what)

func _test_ends(world: Node, id: int, body: Node3D, who: String) -> void:
	_ends(world, id, body, 0x10, 0, "status_poison.efp", true, "%s, a poison's expiry" % who)
	_ends(world, id, body, 0x8, 0, "status_burn.efp", true, "%s, a burn the universal pill ends" % who)
	_ends(world, id, body, 0x2000, 0, "status_blind.efp", true, "%s, a darkness the purification pill ends" % who)
	_ends(world, id, body, 0x800, 0, "status_bleeding.efp", false, "%s, a bleeding a death ends" % who)
	# Confusion's effect never ends by itself (status_bad_temptation, MEASURED:
	# still drawing 60 s after a release): the fade alone takes it off.
	_ends(world, id, body, 0x10000, 0, "status_never.efp", false, "%s, a confusion's expiry" % who)

	# One state of two ends (a pill cures the poison, the burn stays): only
	# the poison's aura goes.
	_made.clear()
	_status(world, id, 0x10 | 0x8)
	var poison := _made_named("status_poison.efp")
	var burn := _made_named("status_burn.efp")
	var t0: int = SkillEffects._now()
	_status(world, id, 0x8)
	SkillEffects.process(t0 + 300)
	_check(poison.size() == 1 and _gone(poison[0]) and burn.size() == 1 and not _gone(burn[0]) and (burn[0] as EfpEffect).loop,
		"%s: a cure of one of two states ends that one's aura, the other keeps looping" % who)
	_status(world, id, 0)
	SkillEffects.process(t0 + 600)
	_check(burn.size() == 1 and _gone(burn[0]), "%s: and the other's end ends it" % who)

	# A renewal (the same state landed again before its end: the server
	# resends the same mask) keeps the running aura, and the renewal's own
	# end takes it off within the Fade.
	_made.clear()
	_status(world, id, 0x10)
	var first := _made_named("status_poison.efp")
	_status(world, id, 0x10)
	_check(first.size() == 1 and _made_named("status_poison.efp").size() == 1 and not _gone(first[0]) and (first[0] as EfpEffect).loop,
		"%s: a renewed state keeps its one aura (no second, none let go)" % who)
	t0 = SkillEffects._now()
	_status(world, id, 0)
	SkillEffects.process(t0 + 300)
	_check(first.size() == 1 and _gone(first[0]), "%s: the renewed state's end takes it off within the Fade" % who)

# --- the rows -----------------------------------------------------------------

## A row with no Fade is let go as before (round 785): kept no longer, but
## not faded.
func _test_tables() -> void:
	_check(SkillEffects.end_fade_ms_of({"fade": [300, 300]}) == 300 and SkillEffects.end_fade_ms_of({"fade": [0, 0]}) == 0
		and SkillEffects.end_fade_ms_of({}) == 0, "end_fade_ms_of: the Fade column's first value, 0 for none")

# --- the tables and the world -------------------------------------------------

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _row(id: String, obj: String, fade: String) -> String:
	var cols: Array = ["label", id, "ACT_L", "0", "FALSE", "none", "MOB_BASE", "0", "0", "0", "0", "1",
		fade, "AT_LOOP", "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", "battle\\", obj, "Bip01", "0,0,0",
		"none", "0,0,0", "none", "0", "none", "none", "none"]
	return "\t".join(PackedStringArray(cols)) + "\r\n"

func _tables() -> void:
	SkillAudio.set_tables({}, {})
	var text := "#section skilleffectset\r\n"
	text += _row("PARAM_PS", "status_poison.efp", "300,300")
	text += _row("PARAM_BU", "status_burn.efp", "300,300")
	text += _row("PARAM_DN", "status_blind.efp", "300,300")
	text += _row("PARAM_BLOOD", "status_bleeding.efp", "300,300")
	text += _row("PARAM_CHAOS", "status_never.efp", "300,300")
	SkillEffects.reset()
	SkillEffects.set_rows(SkillEffects.parse_rows(_utf16(text)), {})
	SkillEffects.effect_factory = _effect
	SkillEffects.quality = SkillEffects.EFFECTS_ALL

## A tiny synthetic effect: one plate particle, 3 frames; "status_never"
## re-arms itself every wrap (NormalTimeLoop), so it never ends by itself.
func _effect(path: String) -> EfpEffect:
	var n := EfpReader.EfpNode.new()
	n.frames = 3
	var ex := EfpReader.EfpCommand.new()
	ex.name = "NormalTimeLoop" if path.get_file() == "status_never.efp" else "NormalTimeExtinct"
	n.extinct = ex
	var em := EfpReader.EfpCommand.new()
	em.name = "StaticEmit"
	em.value = {"type": "SEFStaticEmit", "delay": 0, "duration": 1, "interval": 1, "max_live": 1, "per_trigger": 1.0}
	n.emit.append(em)
	var rd := EfpReader.EfpCommand.new()
	rd.name = "RenderPlate"
	n.render = rd
	var vw := EfpReader.EfpCommand.new()
	vw.name = "ViewNone"
	n.view = vw
	n.state = EfpReader.EfpRenderState.new()
	n.state.src_blend = 5
	n.state.dest_blend = 2
	var ref := EfpReader.EfpMeshRef.new()
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	var fx := EfpEffect.from_template(EfpSim.compile(n), func(p): return _tex if p == "t.ddj" else null, func(_p): return null, 5)
	_made.append([path.get_file(), fx])
	return fx

func _give_skeleton(body: Node3D) -> void:
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	body.add_child(skel)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mi.mesh = mesh
	mi.material_override = StandardMaterial3D.new()
	skel.add_child(mi)

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
