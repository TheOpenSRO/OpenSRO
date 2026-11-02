extends SceneTree

## Round 855: "the status effect color lingers when it shouldn't". A body's
## colour pulse (BodyPulse: a state's or berserk's) paints only copies it
## made, follows whatever else changes a mesh's material under it, and at its
## end every mesh draws its own material -- at the body's level now -- with no
## shared material ever painted. Each path below lingered or could (the first
## MEASURED live and in r855_probe on 6b1b1223: CharacterLight's rescan swapped
## the pulse's copy for the shared level copy, the pulse painted that, and its
## last colour stayed on this body and every body at the level).
## Synthetic bodies and materials, never game data. Run headless on the render
## box (`client/tools/remote_godot.sh tests`).

var _failures := 0
const POISON := 0x10
const BURN := 0x8
const LEVEL := 153.0 / 384.0
const LEVEL2 := 200.0 / 384.0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _object_base() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ObjectLoader.object_shader("solid")
	return m

## A body (in CharacterBlobs' sense: the node CharacterLight levels) holding a
## skeleton holding a mesh per material.
func _body(mats: Array) -> Node3D:
	var body := Node3D.new()
	var skel := Skeleton3D.new()
	skel.add_bone("Bip01")
	body.add_child(skel)
	for m in mats:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		mi.material_override = m
		skel.add_child(mi)
	root.add_child(body)
	return body

func _mesh(body: Node3D, i: int) -> MeshInstance3D:
	return SkillEffects.skeleton_of(body).get_child(i) as MeshInstance3D

func _start(body: Node3D, bit: int = POISON) -> void:
	BodyPulse.start(body, StateLook.TINTS[bit][0], StateLook.TINTS[bit][1], StateLook.PULSE_MS, StateLook.WHO)

func _tinted(body: Node3D) -> int:
	return int(TintProbe.measure(body)["tinted"])

func _initialize() -> void:
	_test_level_copy()
	_test_level_changes_mid_pulse()
	_test_replaced_material()
	_test_pieces_added_removed()
	_test_rebuilt_skeleton()
	_test_fade_in_before()
	_test_fade_out_after()
	_test_freed_host()
	_test_walk_events()
	BodyPulse.clear()
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)

## The live path: a body on a terrain tile draws ObjectLight's shared level
## copy; CharacterLight rescans it mid-pulse (every 8th visit).
func _test_level_copy() -> void:
	var base := _object_base()
	var lvl := ObjectLight.with_object_color(base, LEVEL)
	var body := _body([lvl])
	body.set_meta(CharacterLight.META_VALUE, LEVEL)
	var bystander := _body([lvl])
	var mi := _mesh(body, 0)
	_start(body)
	BodyPulse.tick(0.1)
	_check(mi.material_override != lvl and _tinted(body) == 1, "the pulse draws the body on its own copy")
	var copy := mi.material_override
	CharacterLight.set_on(body, LEVEL, true)
	_check(mi.material_override == copy, "CharacterLight leaves a mesh the pulse holds alone")
	BodyPulse.tick(0.3)
	_check(mi.material_override != lvl and TintProbe.tint_of(mi.material_override) != null,
		"CharacterLight's rescan leaves the pulse's copy on it (NEGATIVE on 6b1b1223: swapped for the shared level copy)")
	_check(TintProbe.tint_of(lvl) == null and TintProbe.shared_tinted() == 0 and _tinted(bystander) == 0,
		"the shared level copy is never painted; a body beside it at that level draws no colour")
	_check(BodyPulse.stop(body), "the end is taken")
	_check(mi.material_override == lvl and _tinted(body) == 0 and not mi.has_meta(BodyPulse.ORIGINAL_META),
		"at the end the body draws its level copy again, uncoloured")
	CharacterLight.set_on(body, LEVEL, true)
	_check(_tinted(body) == 0 and TintProbe.shared_tinted() == 0, "and the next rescan finds no colour anywhere (NEGATIVE on 6b1b1223: the poison's green stayed)")
	body.free()
	bystander.free()

## The body walks to another tile mid-pulse: CharacterLight leaves the mesh
## alone (the pulse stands in for the object colour, READ), and at the end it
## draws its material at the level it stands on now.
func _test_level_changes_mid_pulse() -> void:
	var base := _object_base()
	var lvl := ObjectLight.with_object_color(base, LEVEL)
	var body := _body([lvl])
	body.set_meta(CharacterLight.META_VALUE, LEVEL)
	var mi := _mesh(body, 0)
	_start(body)
	BodyPulse.tick(0.1)
	body.set_meta(CharacterLight.META_VALUE, LEVEL2)
	CharacterLight.set_on(body, LEVEL2, true)
	BodyPulse.tick(0.1)
	BodyPulse.stop(body)
	_check(mi.material_override == ObjectLight.with_object_color(base, LEVEL2) and _tinted(body) == 0,
		"walked to another tile while it pulsed: the end draws the material at the new tile's level")
	_check(TintProbe.shared_tinted() == 0, "no level copy was painted on the way")
	body.free()

## Something else replaces a mesh's material mid-pulse (an equipment glow's
## plain material, a fade's end): that material is the mesh's own from then,
## it is never painted, and it is what the end gives back.
func _test_replaced_material() -> void:
	var a := StandardMaterial3D.new()
	a.albedo_color = Color(0.5, 0.5, 0.5)
	var b := StandardMaterial3D.new()
	b.albedo_color = Color(0.25, 0.25, 0.25)
	var body := _body([a])
	var mi := _mesh(body, 0)
	_start(body)
	BodyPulse.tick(0.1)
	mi.material_override = b
	BodyPulse.tick(0.2)
	_check(mi.material_override != b and mi.material_override is StandardMaterial3D, "a material put on mid-pulse is copied and drawn in the colour")
	_check(b.albedo_color.is_equal_approx(Color(0.25, 0.25, 0.25)) and a.albedo_color.is_equal_approx(Color(0.5, 0.5, 0.5)),
		"neither the old nor the new material is painted (NEGATIVE on 6b1b1223: the new one was)")
	BodyPulse.stop(body)
	_check(mi.material_override == b, "the end gives back the material put on, not the one before it")
	body.free()

## A piece put on mid-pulse (equipment) takes the colour; one taken off is
## put back on its own material wherever it went; a freed one is no error.
func _test_pieces_added_removed() -> void:
	var a := StandardMaterial3D.new()
	var body := _body([a, a])
	var skel := SkillEffects.skeleton_of(body)
	_start(body)
	BodyPulse.tick(0.1)
	var cape_mat := StandardMaterial3D.new()
	var cape := MeshInstance3D.new()
	cape.mesh = BoxMesh.new()
	cape.material_override = cape_mat
	skel.add_child(cape)
	BodyPulse.tick(0.1)
	_check(cape.material_override != cape_mat, "a piece put on mid-pulse takes the colour")
	var off := _mesh(body, 1)
	skel.remove_child(off)
	root.add_child(off)
	(_mesh(body, 0)).free()
	BodyPulse.tick(0.1)
	_check(off.material_override == a and not off.has_meta(BodyPulse.ORIGINAL_META), "a piece taken off mid-pulse draws its own material")
	BodyPulse.stop(body)
	_check(cape.material_override == cape_mat, "at the end the piece put on draws its own material")
	off.free()
	body.free()

## The body is rebuilt mid-pulse (a model switch, a job suit: a new skeleton
## under the same body): the new pieces take the colour, and the end leaves
## every piece on its own material.
func _test_rebuilt_skeleton() -> void:
	var a := StandardMaterial3D.new()
	var body := _body([a])
	_start(body, BURN)
	BodyPulse.tick(0.1)
	var old := SkillEffects.skeleton_of(body)
	body.remove_child(old)
	old.free()
	var skel := Skeleton3D.new()
	body.add_child(skel)
	var n := StandardMaterial3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = n
	skel.add_child(mi)
	BodyPulse.tick(0.1)
	_check(mi.material_override != n, "the rebuilt body's pieces take the colour")
	BodyPulse.stop(body)
	_check(mi.material_override == n, "and draw their own at the end")
	body.free()

## A body fading in (AppearFade, its twins shared by its cohort) when its
## colour starts: the shared twin is never painted, the fade gives back the
## pulse's copy, and an end before the fade's own gives back the mesh's own.
func _test_fade_in_before() -> void:
	var base := _object_base()
	var body := _body([base])
	var twin_mate := _body([base])
	var fades = AppearFade.Fades.new()
	fades.start(body)
	fades.start(twin_mate)
	var mi := _mesh(body, 0)
	var twin := mi.material_override
	_check(twin != base and twin == _mesh(twin_mate, 0).material_override, "the two bodies fade on one shared twin")
	_start(body)
	BodyPulse.tick(0.1)
	_check(mi.material_override == twin and TintProbe.tint_of(twin) == null, "the pulse leaves the shared twin alone")
	fades.step(2.5)
	_check(mi.material_override != base and TintProbe.tint_of(mi.material_override) != null and _tinted(twin_mate) == 0,
		"the fade's end gives the body the pulse's copy; its cohort mate draws its own")
	BodyPulse.stop(body)
	_check(mi.material_override == base and _tinted(body) == 0, "the end: its own material")
	# Ended before the fade's own end.
	var body2 := _body([base])
	var fades2 = AppearFade.Fades.new()
	fades2.start(body2)
	_start(body2)
	BodyPulse.tick(0.1)
	BodyPulse.stop(body2)
	fades2.step(2.5)
	_check(_mesh(body2, 0).material_override == base and _tinted(body2) == 0, "a colour ended mid-fade: the fade gives back the mesh's own")
	body.free()
	twin_mate.free()
	body2.free()

## A body leaving view (a despawn's fade-out) mid-pulse: its twin is made
## from the pulse's copy (this mesh's alone) and pulses; an end mid-fade takes
## the colour off that twin at once.
func _test_fade_out_after() -> void:
	var base := _object_base()
	var body := _body([base])
	var mi := _mesh(body, 0)
	_start(body)
	BodyPulse.tick(0.1)
	var fades = AppearFade.Fades.new()
	fades.start_out(body)
	var twin := mi.material_override
	_check(twin.has_meta(AppearFade.TWIN_META) and TintProbe.tint_of(twin) != null, "a fade-out mid-pulse draws a twin of the copy, coloured")
	BodyPulse.stop(body)
	_check(TintProbe.tint_of(twin) == null and _tinted(body) == 0, "an end mid-fade-out takes the colour off that twin at once")
	_check(mi.get_meta(AppearFade.ORIGINAL_META) == base, "and the fade's own material is the mesh's again")
	body.free()

func _test_freed_host() -> void:
	var body := _body([StandardMaterial3D.new()])
	_start(body)
	var before := BodyPulse.count()
	body.free()
	BodyPulse.tick(0.1)
	_check(BodyPulse.count() == before - 1, "a freed body's colour is dropped")

## READ (FUN_009cd5e0): the walk's events in bit order, low to high; the slot
## is what the last tinted event left.
func _test_walk_events() -> void:
	var w := StateLook.walk(0, POISON | BURN, {})
	_check(w["pulse"] == StateLook.TINTS[POISON], "burn and poison at once: poison's colour (bit 4 after bit 3)")
	w = StateLook.walk(POISON | BURN, BURN, w)
	_check(w["pulse"] == [], "the poison ends, the burn stays: the colour ends (+0x4c, whoever set it)")
	w = StateLook.walk(BURN, BURN | 0x100, w)
	_check(w["pulse"] == null, "a slowness beside it changes no colour")
	w = StateLook.walk(POISON, BURN, {})
	_check(w["pulse"] == [], "poison off and burn on in one message: bit 3 on, then bit 4 off -- no colour")
	w = StateLook.walk(BURN, POISON, {})
	_check(w["pulse"] == StateLook.TINTS[POISON], "burn off and poison on in one message: the poison's colour")
	var body := _body([StandardMaterial3D.new()])
	StateLook.apply_pulse(body, StateLook.walk(0, POISON, {})["pulse"])
	_check(StateLook.tinted(body), "apply_pulse starts the state's colour")
	StateLook.apply_pulse(body, null)
	_check(StateLook.tinted(body), "a change with no tinted bit leaves it")
	BodyPulse.start(body, Color.RED, Color.BLUE, 500.0, "berserk")
	StateLook.end_pulse(body)
	_check(BodyPulse.who(body) == "berserk", "a state's look dropped without a walk (a death, a zone change) leaves berserk's colour")
	BodyPulse.start(body, Color.RED, Color.BLUE, 500.0, StateLook.WHO)
	StateLook.end_pulse(body)
	_check(not BodyPulse.on(body), "and ends a state's")
	body.free()
	BodyPulse.tick(0.0)
