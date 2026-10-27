extends SceneTree

## Round 837: the item mall's try-on preview (MallPreview) against the
## original's rules (docs/protocol/item_mall.md section 4 and its corrections,
## item_mall_verify.md section 4 and "Missed / The try-on"): the camera, every
## mouse rule with numbers, what can be worn, the can-equip refusals, one per
## type, the reapply, Original keeping +0x394, the stand restarting. Synthetic
## models and items; a last part reads the real Media.pk2 (SKIP when absent).
##   godot4 --headless --path client --script res://scripts/ui/hud/mall_preview_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const RECT := Vector2(215, 332)
const EPS := 1e-4

var _failures := 0

## The provider contract (MallModels') with synthetic rows and models.
## The real archive's bodies and pets behind the same contract (World3D's
## builders are CharacterAppearance and SkinnedBsrAssembler, as here).
class RealProvider extends FakeProvider:
	var appearance: CharacterAppearance
	var data: Pk2Reader
	var cos_table: CosTable
	var body_ref := 1907
	func build_body(avatars: Array) -> Dictionary:
		body_builds += 1
		last_avatars = avatars.duplicate()
		var list: Array = []
		for a in avatars:
			list.append({"id": int(a), "plus": 0})
		var built := appearance.build(body_ref, CharacterAppearance.DEFAULT_SCALE, list)
		if built == null:
			return {}
		var stand := appearance.animation_for(built, BsrReader.AnimationEntry.TYPE_STAND)
		var skel := built.skeleton
		built.remove_child(skel)
		skel.scale = built.scale
		built.free()
		return {"node": skel, "stand": stand}
	func build_cos(cos_ref: int) -> Dictionary:
		cos_builds.append(cos_ref)
		var row := cos_table.row(cos_ref)
		if row == null or row.model == "":
			return {}
		var a := SkinnedBsrAssembler.assemble_from_archive(data, row.model, true, false, 0)
		if a == null:
			return {}
		return {"node": a.skeleton, "stand": SkinnedBsrAssembler.animation_for(data, a, BsrReader.AnimationEntry.TYPE_STAND)}

class FakeProvider extends RefCounted:
	var items := {}
	var refs := {}
	var facts := {"ref": 1907, "sex": 1, "country": 1, "level": 10, "str": 20, "int": 20}
	var worn := [0, 0, 0, 0, 0]
	var scales := {}
	var masteries := {}
	var body_builds := 0
	var last_avatars: Array = []
	var cos_builds: Array = []
	func item(ref_id: int) -> ItemTableReader.Item:
		return items.get(ref_id)
	func char_ref(code: String) -> Dictionary:
		return refs.get(code, {})
	func player_facts() -> Dictionary:
		return facts.duplicate()
	func worn_avatars() -> Array:
		return worn.duplicate()
	func ref_scale(ref_id: int) -> float:
		return float(scales.get(ref_id, 1.0))
	func mastery_level(id: int) -> int:
		return int(masteries.get(id, -1))
	func zone_light() -> Array:
		return []
	## A body whose meshes span x [-4, 4], y [-2, 18], z [-2, 2].
	func build_body(avatars: Array) -> Dictionary:
		body_builds += 1
		last_avatars = avatars.duplicate()
		return {"node": FakeProvider.box_skeleton(Vector3(8, 20, 4), Vector3(0, 8, 0)), "stand": null}
	func build_cos(cos_ref: int) -> Dictionary:
		cos_builds.append(cos_ref)
		return {"node": FakeProvider.box_skeleton(Vector3(3, 3, 3), Vector3(0, 1.5, 0)), "stand": null}
	static func box_skeleton(extent: Vector3, centre: Vector3) -> Skeleton3D:
		var skel := Skeleton3D.new()
		# The mesh's own vertices span the box (the model's parts are in its
		# space; their node transforms do not enter the box, 0xc26a40).
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var lo := centre - extent * 0.5
		var hi := centre + extent * 0.5
		st.add_vertex(lo)
		st.add_vertex(Vector3(hi.x, lo.y, lo.z))
		st.add_vertex(hi)
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.position = Vector3(100, 100, 100)
		skel.add_child(mi)
		return skel

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = EPS) -> bool:
	return absf(a - b) <= eps

func _vnear(a: Vector3, b: Vector3, eps: float = EPS) -> bool:
	return a.distance_to(b) <= eps

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

static func _item(id: int, t: Array, gender: int = 1, country: int = 3, desc1: String = "") -> ItemTableReader.Item:
	var it := ItemTableReader.Item.new()
	it.id = id
	it.code_name = "ITEM_%d" % id
	it.type_ids = PackedInt32Array(t)
	it.req_gender = gender
	it.country = country
	it.desc1 = desc1
	it.req_level_types = PackedInt32Array([-1, -1, -1, -1])
	it.req_levels = PackedInt32Array([0, 0, 0, 0])
	return it

static func _cos_word(t4: int, bionic: int = 1) -> int:
	return (bionic << 1) | (1 << 2) | (2 << 5) | (3 << 7) | (t4 << 11)

func _provider() -> FakeProvider:
	var p := FakeProvider.new()
	var add := func(it: ItemTableReader.Item) -> void: p.items[it.id] = it
	add.call(_item(100, [3, 1, 13, 1]))                 # hat A
	add.call(_item(101, [3, 1, 13, 1]))                 # hat B
	add.call(_item(102, [3, 1, 13, 2]))                 # dress
	add.call(_item(103, [3, 1, 13, 3]))                 # attachment (wings)
	add.call(_item(104, [3, 1, 13, 4]))                 # flag
	add.call(_item(105, [3, 1, 14, 1]))                 # devil's spirit
	add.call(_item(106, [3, 1, 13, 1], 0))              # a woman's hat
	add.call(_item(107, [3, 1, 13, 1], 1, 0))           # China only
	var lv := _item(108, [3, 1, 13, 1])
	lv.req_level_types = PackedInt32Array([1, -1, -1, -1])
	lv.req_levels = PackedInt32Array([50, 0, 0, 0])
	add.call(lv)
	var lv2 := _item(109, [3, 1, 13, 1])
	lv2.req_level_types = PackedInt32Array([1, 1, -1, -1])
	lv2.req_levels = PackedInt32Array([50, 5, 0, 0])
	add.call(lv2)
	var st := _item(110, [3, 1, 13, 1])
	st.req_str = 30
	add.call(st)
	var it_ := _item(111, [3, 1, 13, 1])
	it_.req_int = 21
	add.call(it_)
	add.call(_item(120, [3, 2, 1, 1], 2, 3, "COS_P_WOLF"))   # attack-pet flute
	add.call(_item(121, [3, 2, 1, 2], 2, 3, "COS_P_CAT"))    # pick-pet scroll
	add.call(_item(122, [3, 2, 1, 1], 2, 3, "COS_P_BEAR"))   # another flute
	add.call(_item(123, [3, 3, 3, 1], 2, 3, "COS_C_HORSE"))  # a horse's whistle
	add.call(_item(124, [3, 2, 1, 1], 2, 3, "COS_C_HORSE"))  # a flute naming a horse
	var bio := _item(125, [3, 1, 13, 1])
	bio.bionic = 1
	add.call(bio)
	add.call(_item(130, [3, 1, 13, 1]))                 # the player's own hat
	add.call(_item(131, [3, 1, 14, 1]))                 # the player's devil's spirit
	add.call(_item(132, [3, 1, 13, 3]))                 # the player's wings
	var ms := _item(140, [3, 1, 13, 2])
	ms.req_level_types = PackedInt32Array([277, -1, -1, -1])
	ms.req_levels = PackedInt32Array([20, 0, 0, 0])
	add.call(ms)
	p.refs["COS_P_WOLF"] = {"id": 5000, "type_word": _cos_word(3), "scale": 1.4}
	p.refs["COS_P_CAT"] = {"id": 5001, "type_word": _cos_word(4), "scale": 0.5}
	p.refs["COS_P_BEAR"] = {"id": 5002, "type_word": _cos_word(3), "scale": 1.0}
	p.refs["COS_C_HORSE"] = {"id": 5003, "type_word": _cos_word(1), "scale": 1.0}
	p.scales = {5000: 1.4, 5001: 0.5, 5002: 1.0}
	return p

func _new_preview(p: FakeProvider) -> MallPreview:
	var mp := MallPreview.new()
	root.add_child(mp)
	mp.setup(p)
	mp.create()
	return mp

func _btn(index: int, pressed: bool, at: Vector2, dbl: bool = false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = index
	e.pressed = pressed
	e.position = at
	e.double_click = dbl
	return e

func _motion(at: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = at
	return e

func _run() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	_test_camera()
	_test_left_drag_and_orbit()
	_test_wrap()
	_test_release_and_double_click()
	_test_shared_start_field()
	_test_pan()
	_test_wheel()
	_test_press_during_drag()
	_test_wear_rules()
	_test_one_per_type_and_reapply()
	_test_pets()
	_test_original_keeps_angle()
	_test_stand_restart()
	_test_refs_parse()
	await _test_window_hookup()
	_test_real_archive()
	await _test_real_models()

# --- the camera ----------------------------------------------------------------

func _test_camera() -> void:
	var mp := _new_preview(_provider())
	var cam := mp.get_camera()
	_check(_vnear(mp.eye_d3d(), Vector3(0, 13, -35)), "eye (0, 13, -35) in D3D space: %s" % mp.eye_d3d())
	_check(_vnear(mp.target_d3d(), Vector3(0, 13, 0)), "look-at (0, 13, 0)")
	_check(_vnear(cam.transform.origin, Vector3(0, 13, 35)), "Godot eye (0, 13, 35) under the z flip: %s" % cam.transform.origin)
	_check(cam.transform.basis.is_equal_approx(Basis.IDENTITY), "the camera looks along Godot -Z, +Y up (identity basis)")
	_check(cam.fov == 60.0 and cam.keep_aspect == Camera3D.KEEP_HEIGHT, "vertical FOV 60")
	_check(cam.near == 1.0 and cam.far == 500.0, "near 1, far 500")
	_check(mp.size == Vector2i(215, 332), "the control's 215 x 332")
	# The picture is D3D's: a D3D point projected by LookAtLH + PerspectiveFovLH
	# lands where Godot's camera puts the mirrored point.
	var aspect := 215.0 / 332.0
	var cot := 1.0 / tan(deg_to_rad(30.0))
	for p in [Vector3(5, 13, 0), Vector3(-3, 20, 4), Vector3(2, 1, -6)]:
		var vz: float = p.z + 35.0
		var sx: float = ((p.x * cot / aspect) / vz + 1.0) * 0.5 * 215.0
		var sy: float = (1.0 - (((p.y - 13.0) * cot) / vz + 1.0) * 0.5) * 332.0
		var g := cam.unproject_position(PlayerPortrait.to_godot(p))
		_check(absf(g.x - sx) < 0.01 and absf(g.y - sy) < 0.01, "D3D %s projects to (%.2f, %.2f), Godot (%.2f, %.2f)" % [p, sx, sy, g.x, g.y])
	_check(cam.unproject_position(PlayerPortrait.to_godot(Vector3(5, 13, 0))).x > 107.5, "D3D +X is the screen's right (left-handed view from -Z)")
	mp.queue_free()

# --- the left drag: every model turns, the pets orbit ---------------------------------

func _test_left_drag_and_orbit() -> void:
	var p := _provider()
	p.scales[1907] = 1.25
	var mp := _new_preview(p)
	var r := mp.wear(120)
	_check(r["ok"], "the flute is tried on")
	var pet_i: int = mp.slots()["attack"]
	var body := mp.model(mp.slots()["body"])
	_check(body.node.transform == Transform3D.IDENTITY, "the body's world matrix is the identity before any drag (late scale)")
	_check(_vnear(mp.model_d3d_position(pet_i), Vector3(-5.5, 0, -2.5)), "the attack pet at (-5.5, 0, -2.5)")
	_check(_near(mp.model(pet_i).node.transform.basis.get_scale().x, 1.4), "a pet's scale applies at once (1.4)")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), RECT)
	_check(mp.drag_state()["captured"] and mp.drag_state()["left"], "left press: drag on, capture taken")
	mp.handle_input(_motion(Vector2(153.75, 100)), RECT)
	var a := 2.0 * (53.75 / 215.0) * MallPreview.PI_F
	_check(_near(body.yaw, a) and _near(mp.model(pet_i).yaw, a), "dx 53.75 of 215 turns every model to 2pi dx / w = %.6f" % a)
	_check(_near(body.node.transform.basis.get_scale().x, 1.25), "the body's ref scale (1.25) applies at the first drag")
	_check(_vnear(mp.model_d3d_position(pet_i), Vector3(2.5, 0, -5.5), 1e-3), "the pet orbits: (-5.5, 0, -2.5) at pi/2 -> (2.5, 0, -5.5): %s" % mp.model_d3d_position(pet_i))
	_check(_near(mp.model(pet_i).node.rotation.y, -a), "under D3DSpace the model's Godot rotation.y is -yaw")
	# The direction: a point on the body's +X goes toward +Z (away).
	var px := body.node.transform * Vector3(1, 0, 0)
	_check(px.z > 0.99 * 1.25, "a right drag swings +X toward +Z (away from the camera)")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(153.75, 100)), RECT)
	_check(_near(mp.stored_angle(), a) and not mp.drag_state()["captured"], "left release stores +0x394 and releases")
	# A second drag resumes from the stored angle.
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(10, 10)), RECT)
	mp.handle_input(_motion(Vector2(20.75, 400)), RECT)
	_check(_near(body.yaw, a + 2.0 * (10.75 / 215.0) * MallPreview.PI_F), "the next drag starts from +0x394; dy does nothing")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(20.75, 400)), RECT)
	mp.queue_free()

func _test_wrap() -> void:
	var tp := MallPreview.TWO_PI
	_check(_near(MallPreview.wrap_angle(3.0 * PI), 3.0 * PI), "wrap: 3pi (k = 1) is kept")
	_check(_near(MallPreview.wrap_angle(5.0 * PI), 5.0 * PI - 2.0 * tp), "wrap: 5pi (k = 2) loses 2 x 2pi")
	_check(_near(MallPreview.wrap_angle(-6.0 * PI), -6.0 * PI), "wrap: negative angles are kept")
	_check(_near(MallPreview.wrap_angle(tp), tp), "wrap: 2pi itself is kept")
	_check(_near(MallPreview.wrap_angle(2.0 * tp), 0.0), "wrap: 4pi -> 0")
	_check(_near(MallPreview.wrap_angle(4.4 * tp), 4.4 * tp - 4.0 * tp), "wrap: 4.4 turns -> 0.4 turn")
	# Through the drag: 2.5 widths of drag is 5pi, dragged past the rect.
	var mp := _new_preview(_provider())
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(0, 100)), RECT)
	mp.handle_input(_motion(Vector2(537.5, 100)), RECT)
	_check(_near(mp.model(0).yaw, 5.0 * MallPreview.PI_F - 2.0 * tp, 1e-3), "a drag 2.5 widths long wraps to pi")
	mp.handle_input(_motion(Vector2(322.5, 100)), RECT)
	_check(_near(mp.model(0).yaw, 3.0 * MallPreview.PI_F, 1e-3), "1.5 widths: 3pi, not wrapped")
	mp.handle_input(_motion(Vector2(-300, 100)), RECT)
	_check(mp.model(0).yaw < 0.0, "a drag to the left goes negative and stays negative")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(-300, 100)), RECT)
	_check(_near(mp.stored_angle(), 2.0 * (-300.0 / 215.0) * MallPreview.PI_F), "the release outside the rect (captured) stores it")
	mp.queue_free()

func _test_release_and_double_click() -> void:
	var mp := _new_preview(_provider())
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), RECT)
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(100, 100)), RECT)
	_check(_near(mp.stored_angle(), 0.0), "a click without a move stores the start angle")
	# The second press of a double click is WM_LBUTTONDBLCLK: ignored.
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(120, 100), true), RECT)
	_check(not mp.drag_state()["captured"] and not mp.drag_state()["left"], "a double click's press starts no drag")
	mp.handle_input(_motion(Vector2(200, 100)), RECT)
	_check(_near(mp.model(0).yaw, 0.0) and not mp.model(0).matrix_set, "no capture: a move turns nothing")
	# Its release still recomputes +0x394 from the LAST press (x 100).
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(121.5, 100)), RECT)
	var want := 2.0 * (21.5 / 215.0) * MallPreview.PI_F
	_check(_near(mp.stored_angle(), want), "a release with no drag still stores start + 2pi dx / w (%.5f)" % want)
	_check(not mp.model(0).matrix_set, "the release leaves the models alone")
	# A release outside the rect with no capture is not the control's.
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(400, 100)), RECT)
	_check(_near(mp.stored_angle(), want), "a release off the rect without the capture is another window's")
	mp.queue_free()

func _test_shared_start_field() -> void:
	var mp := _new_preview(_provider())
	mp.handle_input(_btn(MOUSE_BUTTON_RIGHT, true, Vector2(100, 100)), RECT)
	_check(_near(mp.drag_state()["start"], 13.0) and _near(mp.drag_state()["start_x"], 0.0), "right press: +0x3c8 = target x, +0x3cc = target y (13)")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), RECT)
	var s := mp.drag_state()
	_check(not s["captured"] and s["right"] and not s["left"], "a left press during the right drag only releases the capture")
	mp.handle_input(_motion(Vector2(150, 150)), RECT)
	_check(_vnear(mp.target_d3d(), Vector3(0, 13, 0)), "the pan stops there")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(121.5, 100)), RECT)
	var raw := 13.0 + 2.0 * (21.5 / 215.0) * MallPreview.PI_F
	var want := raw - 2.0 * MallPreview.TWO_PI
	_check(_near(mp.stored_angle(), want), "the left release takes +0x3cc = 13 (the pan's start y) as its start: +0x394 = %.5f" % want)
	mp.handle_input(_btn(MOUSE_BUTTON_RIGHT, false, Vector2(100, 100)), RECT)
	_check(not mp.drag_state()["right"], "right release ends the right drag")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(0, 0)), RECT)
	_check(_near(mp.drag_state()["start"], want), "the next left drag starts from that angle")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(0, 0)), RECT)
	mp.queue_free()

func _test_pan() -> void:
	var mp := _new_preview(_provider())
	var b := mp.box()
	_check(_vnear(b.position, Vector3(-4, -1, -2)) and _vnear(b.end, Vector3(4, 20, 2)),
		"the pan box: x [-4, 4], y [0.5 x -2, 20 (+0x22c)], z [-2, 2]: %s" % b)
	mp.handle_input(_btn(MOUSE_BUTTON_RIGHT, true, Vector2(100, 100)), RECT)
	mp.handle_input(_motion(Vector2(110, 120)), RECT)
	var x := 0.0 - 10.0 * 35.0 * 2.0 / 215.0
	var y := 13.0 + 20.0 * 35.0 * 2.0 / 332.0
	_check(_vnear(mp.target_d3d(), Vector3(x, y, 0)), "pan: x = x0 - dx d 2 / w, y = y0 + dy d 2 / h -> (%.4f, %.4f)" % [x, y])
	_check(_vnear(mp.get_camera().transform.origin, Vector3(x, y, 35)), "the eye moves with it")
	mp.handle_input(_motion(Vector2(300, 400)), RECT)
	_check(_vnear(mp.target_d3d(), Vector3(-4, 20, 0)), "clamped to (min x, max y)")
	mp.handle_input(_motion(Vector2(-300, -400)), RECT)
	_check(_vnear(mp.target_d3d(), Vector3(4, -1, 0)), "clamped to (max x, min y)")
	mp.handle_input(_btn(MOUSE_BUTTON_RIGHT, false, Vector2(-300, -400)), RECT)
	mp.handle_input(_motion(Vector2(100, 100)), RECT)
	_check(_vnear(mp.target_d3d(), Vector3(4, -1, 0)), "after the release a move pans nothing")
	# The pets never enter the box.
	mp.wear(121)
	_check(_vnear(mp.box().end, Vector3(4, 20, 2)), "a pet tried on does not grow the box")
	mp.queue_free()

func _test_wheel() -> void:
	var mp := _new_preview(_provider())
	var centre := Vector2(107.5, 166)
	mp.handle_input(_btn(MOUSE_BUTTON_WHEEL_UP, true, centre), RECT)
	_check(_near(mp.distance(), 37.0) and _vnear(mp.target_d3d(), Vector3(0, 13, 0)), "wheel away (positive): +2, zoom OUT; at the centre the target stays")
	mp.handle_input(_btn(MOUSE_BUTTON_WHEEL_DOWN, true, centre), RECT)
	_check(_near(mp.distance(), 35.0), "wheel toward: -2")
	mp.wheel(0, centre, RECT)
	_check(_near(mp.distance(), 33.0), "a zero delta is -2")
	mp.wheel(1, centre, RECT)
	# Toward the pointer: zoom in by 2 at the rect's top-left corner.
	var aspect := 215.0 / 332.0
	var cot := 1.0 / tan(deg_to_rad(30.0))
	var vx := (0.0 - 1.0) / (cot / aspect)
	var vy := -((0.0 - 1.0) / cot)
	var before := Vector2(mp.target_d3d().x + mp.distance() * vx, mp.target_d3d().y + mp.distance() * vy)
	mp.wheel(-1, Vector2(0, 0), RECT)
	_check(_near(mp.distance(), 33.0), "zoom in: 35 -> 33")
	_check(_vnear(mp.target_d3d(), Vector3(2.0 * vx, 13.0 + 2.0 * vy, 0)), "the target slides 2 x (vx, vy) = (%.4f, %.4f)" % [2.0 * vx, 2.0 * vy])
	var after := Vector2(mp.target_d3d().x + mp.distance() * vx, mp.target_d3d().y + mp.distance() * vy)
	_check(after.distance_to(before) < 1e-4, "the point under the pointer on the look-at plane stays put")
	_check(_vnear(mp.get_camera().transform.origin, Vector3(2.0 * vx, 13.0 + 2.0 * vy, 33)), "the camera follows")
	# The clamp: s = max(span x 8, span z 4) = 8 -> [9, 48].
	for i in range(30):
		mp.wheel(-1, centre, RECT)
	_check(_near(mp.distance(), 9.0), "zoom in stops at s + near = 9")
	for i in range(30):
		mp.wheel(1, centre, RECT)
	_check(_near(mp.distance(), 48.0), "zoom out stops at s + 40 = 48")
	mp.wheel(1, Vector2(0, 0), RECT)
	_check(_near(mp.distance(), 48.0), "at the limit (r = 0) nothing moves")
	mp.queue_free()

func _test_press_during_drag() -> void:
	var mp := _new_preview(_provider())
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), RECT)
	mp.handle_input(_motion(Vector2(110, 100)), RECT)
	var y0 := mp.model(0).yaw
	mp.handle_input(_btn(MOUSE_BUTTON_RIGHT, true, Vector2(110, 100)), RECT)
	var s := mp.drag_state()
	_check(not s["captured"] and s["left"] and not s["right"], "a right press during the left drag only releases the capture")
	mp.handle_input(_motion(Vector2(200, 150)), RECT)
	_check(_near(mp.model(0).yaw, y0) and _vnear(mp.target_d3d(), Vector3(0, 13, 0)), "the drag has ended: nothing turns or pans")
	mp.handle_input(_btn(MOUSE_BUTTON_RIGHT, false, Vector2(200, 150)), RECT)
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(150, 100)), RECT)
	_check(_near(mp.stored_angle(), 2.0 * (50.0 / 215.0) * MallPreview.PI_F), "its left release still stores from the left start")
	_check(not mp.drag_state()["left"], "the left drag flag is cleared by the release")
	mp.queue_free()

# --- what can be worn ------------------------------------------------------------

func _test_wear_rules() -> void:
	var p := _provider()
	var mp := _new_preview(p)
	_check(mp.can_wear(100) and mp.can_wear(102) and mp.can_wear(104), "hats, dresses and flags can be tried on")
	_check(not mp.can_wear(103), "an attachment (3/1/13/3) cannot")
	_check(not mp.can_wear(105), "a devil's spirit (3/1/14) cannot")
	_check(mp.can_wear(120) and mp.can_wear(121), "an attack-pet flute and a pick-pet scroll can")
	_check(not mp.can_wear(123) and not mp.can_wear(124), "a horse (3/3/3 item, or a COS 1/2/3/1) cannot")
	_check(not mp.can_wear(125), "a Bionic item cannot")
	_check(not mp.can_equip(120), "a pet item fails can-equip (bit 0x02), which routes it to the pet path")
	var builds := p.body_builds
	var tried := mp.tried()
	for case in [[106, "another gender"], [107, "another race"], [108, "a level over the player's"],
			[110, "Str over the player's"], [111, "Int over the player's"]]:
		var r := mp.wear(int(case[0]))
		_check(not r["ok"] and r["reason"] == "equip" and r["text_key"] == "UIIT_MSG_STRGERR_EQUIPITEM",
			"refused, %s: \"Cannot equip the selected item\"" % case[1])
	_check(mp.tried() == tried and p.body_builds == builds, "a refusal sets nothing")
	_check(mp.wear(109)["ok"], "a later type-1 pair at the player's level passes the level test")
	_check(not mp.wear(103)["ok"] and mp.wear(103)["reason"] == "not_wearable", "Wear on an attachment is refused")
	p.masteries[277] = 10
	_check(not mp.can_equip(140), "a mastery the player has under the level refuses (0x100)")
	p.masteries.erase(277)
	_check(mp.can_equip(140), "a mastery the player lacks is skipped (0x100)")
	p.facts["sex"] = 0
	_check(mp.can_equip(106) and not mp.can_equip(100), "a woman wears the woman's hat, not the man's")
	mp.queue_free()

func _test_one_per_type_and_reapply() -> void:
	var p := _provider()
	p.worn = [130, 0, 132, 0, 131]
	var mp := _new_preview(p)
	_check(mp.tried() == [130, 132, 131], "the build puts the worn avatars in the try list: %s" % str(mp.tried()))
	_check(mp.body_avatars() == [130, 132, 131], "the body wears them (the dress copy)")
	_check(p.last_avatars == [130, 132, 131], "the body was built with them")
	mp.wear(100)
	_check(mp.tried() == [132, 131, 100] and not mp.body_avatars().has(130) and mp.body_avatars().has(100),
		"a hat takes the worn hat off first (no reapply): %s" % str(mp.tried()))
	mp.wear(101)
	_check(mp.tried() == [132, 131, 101] and not mp.body_avatars().has(100), "one per exact TypeID1..4: hat B replaces hat A")
	mp.wear(102)
	_check(mp.tried() == [132, 131, 101, 102], "a dress is another type: both stay")
	mp.take_off(101, true)
	_check(mp.tried() == [132, 131, 102, 130] and mp.body_avatars().has(130) and not mp.body_avatars().has(101),
		"take off with reapply: the player's own hat (same 16-bit type word) goes back on: %s" % str(mp.tried()))
	mp.take_off(102, true)
	_check(mp.tried() == [132, 131, 130] and not mp.body_avatars().has(102), "no worn dress: nothing comes back")
	mp.take_off(102, true)
	_check(mp.tried() == [132, 131, 130], "taking off what is not tried changes nothing")
	mp.take_off(130, false)
	_check(mp.tried() == [132, 131] and not mp.body_avatars().has(130), "take off without reapply leaves it off")
	mp.queue_free()

func _test_pets() -> void:
	var p := _provider()
	var mp := _new_preview(p)
	mp.wear(120)
	var s := mp.slots()
	_check(s["attack"] == 1 and mp.model_count() == 2 and mp.model(1).ref_id == 5000, "the attack pet is model 1 (slot +0x85c)")
	mp.wear(122)
	s = mp.slots()
	_check(mp.tried() == [122] and mp.model_count() == 2 and s["attack"] == 1 and mp.model(1).ref_id == 5002,
		"a second flute (same item type) takes the first off: its model deleted, a new one made")
	mp.wear(121)
	s = mp.slots()
	_check(s["pick"] == 2 and _vnear(mp.model_d3d_position(2), Vector3(4.5, 0, -2.5)), "the pick pet at (4.5, 0, -2.5), slot +0x858")
	_check(_near(mp.model(2).node.transform.basis.get_scale().x, 0.5), "its Scale 50 -> 0.5")
	mp.take_off(122, false)
	s = mp.slots()
	_check(s["attack"] == -1 and mp.model_count() == 2 and mp.model(1).ref_id == 5001,
		"taking the flute off deletes its model by COS ref and resets the slot")
	_check(s["pick"] == 2, "the pick pet's slot keeps its old index (retail does not renumber)")
	mp.take_off(121, false)
	_check(mp.slots()["pick"] == -1 and mp.model_count() == 1, "the scroll off: only the body left")
	_check(mp.tried().is_empty(), "the try list is empty")
	mp.queue_free()

func _test_original_keeps_angle() -> void:
	var p := _provider()
	p.worn = [130, 0, 0, 0, 0]
	var mp := _new_preview(p)
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(0, 50)), RECT)
	mp.handle_input(_motion(Vector2(53.75, 50)), RECT)
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(53.75, 50)), RECT)
	var a := mp.stored_angle()
	_check(_near(a, MallPreview.PI_F * 0.5), "dragged to pi/2")
	mp.wear(121)
	_check(_near(mp.model(mp.slots()["pick"]).yaw, a), "a pet takes +0x394")
	mp.wear(100)
	mp.handle_input(_btn(MOUSE_BUTTON_WHEEL_UP, true, Vector2(0, 0)), RECT)
	mp.original()
	_check(mp.model_count() == 1 and not mp.model(0).matrix_set and mp.model(0).node.transform == Transform3D.IDENTITY,
		"Original: the pets go, the new body stands at yaw 0 (identity)")
	_check(mp.tried() == [130], "Original: the try list is the worn avatars again")
	_check(_near(mp.distance(), 35.0) and _vnear(mp.target_d3d(), Vector3(0, 13, 0)), "Original: target and distance back to (0, 13, 0) and 35")
	_check(_near(mp.stored_angle(), a), "Original does NOT reset +0x394")
	mp.wear(120)
	_check(_near(mp.model(mp.slots()["attack"]).yaw, a) and _near(mp.model(0).yaw, 0.0),
		"a pet tried after Original stands at the old angle while the body is at 0")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 50)), RECT)
	mp.handle_input(_motion(Vector2(100, 50)), RECT)
	_check(_near(mp.model(0).yaw, a), "the next drag resumes from the old angle (the body jumps to it)")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(100, 50)), RECT)
	mp.queue_free()

func _test_stand_restart() -> void:
	var p := _provider()
	var mp := _new_preview(p)
	mp.step(0.7)
	_check(_near(mp.model(0).t, 0.7), "the stand runs (0.7 s)")
	mp.wear(100)
	_check(_near(mp.model(0).t, 0.0), "a try-on replays STAND from t = 0")
	mp.wear(120)
	mp.step(0.3)
	var pet: int = mp.slots()["attack"]
	_check(_near(mp.model(pet).t, 0.3) and _near(mp.model(0).t, 0.3), "both run")
	mp.wear(102)
	_check(_near(mp.model(0).t, 0.0) and _near(mp.model(pet).t, 0.3), "a body try-on restarts the body only")
	mp.take_off(102, false)
	_check(_near(mp.model(0).t, 0.0), "a take-off replays it too")
	mp.step(0.2)
	mp.wear(122)
	_check(_near(mp.model(mp.slots()["attack"]).t, 0.0), "a new pet starts at t = 0")
	# An already-attached avatar (the build's re-attach) still restarts the stand.
	var p2 := _provider()
	p2.worn = [130, 0, 0, 0, 0]
	var mp2 := _new_preview(p2)
	_check(p2.body_builds == 1, "the build's re-attach of a worn avatar does not rebuild the body")
	mp.queue_free()
	mp2.queue_free()

# --- the window's hookup ------------------------------------------------------------

## As the window installs it: a child of its TextureRect, build() at open, the
## rect's gui_input forwarded. It renders while the rect shows.
func _test_window_hookup() -> void:
	var view := TextureRect.new()
	view.size = RECT
	root.add_child(view)
	var mp := MallPreview.new()
	mp.setup(_provider())
	view.add_child(mp)
	mp.build()
	await process_frame
	_check(mp.is_active() and mp.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "under a shown TextureRect it renders")
	view.hide()
	await process_frame
	_check(not mp.is_active() and mp.render_target_update_mode == SubViewport.UPDATE_DISABLED, "hidden with the rect, it stops")
	view.show()
	await process_frame
	_check(mp.is_active(), "shown again, it renders")
	var took := mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(10, 10)), view.size)
	_check(took and mp.drag_state()["left"], "build() turns the mouse on (+0x1f0 = 1)")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(10, 10)), view.size)
	view.queue_free()
	await process_frame

# --- the refs table and the real archive ------------------------------------------

func _test_refs_parse() -> void:
	var cols := PackedStringArray()
	cols.resize(60)
	for i in range(60):
		cols[i] = "0"
	cols[MallModels.COL_ID] = "5000"
	cols[MallModels.COL_CODE] = "COS_P_WOLF_001"
	cols[MallModels.COL_BIONIC] = "1"
	cols[MallModels.COL_TYPE1] = "1"
	cols[MallModels.COL_TYPE1 + 1] = "2"
	cols[MallModels.COL_TYPE1 + 2] = "3"
	cols[MallModels.COL_TYPE1 + 3] = "3"
	cols[MallModels.COL_SCALE] = "140"
	var line2 := cols.duplicate()
	line2[MallModels.COL_ID] = "1907"
	line2[MallModels.COL_CODE] = "CHAR_CH_MAN_ADVENTURER"
	line2[MallModels.COL_TYPE1 + 1] = "1"
	line2[MallModels.COL_TYPE1 + 2] = "0"
	line2[MallModels.COL_TYPE1 + 3] = "0"
	line2[MallModels.COL_SCALE] = "100"
	var text := "\t".join(cols) + "\r\n" + "\t".join(line2) + "\r\n"
	var refs := {}
	# The archive's text tables are UTF-16LE with a BOM.
	var bytes := PackedByteArray([0xFF, 0xFE])
	bytes.append_array(text.to_utf16_buffer())
	MallModels.parse_refs(bytes, refs)
	_check(refs.has("COS_P_WOLF_001") and MallPreview.is_attack_pet_word(int(refs["COS_P_WOLF_001"]["type_word"])),
		"parse_refs: a COS 1/2/3/3 Bionic row is an attack pet")
	_check(refs.has("COS_P_WOLF_001") and refs.has("CHAR_CH_MAN_ADVENTURER")
		and _near(float(refs["COS_P_WOLF_001"]["scale"]), 1.4) and float(refs["CHAR_CH_MAN_ADVENTURER"]["scale"]) == 1.0,
		"parse_refs: Scale 140 -> 1.4, 100 -> exactly 1.0")

func _test_real_archive() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP real archive (no %s)" % MEDIA)
		return
	var media := Pk2Reader.open(MEDIA)
	_check(media != null, "Media.pk2 opens")
	if media == null:
		return
	var items: Dictionary = ItemTableReader.load_all(media)
	var refs := {}
	for path in CharTables.table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			MallModels.parse_refs(media.read_file(entry), refs)
	var p := FakeProvider.new()
	p.items = items
	p.refs = refs
	var mp := MallPreview.new()
	mp.setup(p)
	var counts := {"hat": 0, "dress": 0, "attach": 0, "flag": 0, "devil": 0, "attack": 0, "pick": 0, "flute_bad": 0, "scroll_bad": 0, "horse": 0,
		"avatar_rows": 0, "level_req": 0, "mastery_req": 0}
	for id in items:
		var it: ItemTableReader.Item = items[id]
		if it.type_ids.size() < 4:
			continue
		var t := [it.type_ids[0], it.type_ids[1], it.type_ids[2], it.type_ids[3]]
		var w := mp.can_wear(int(id))
		if t[0] == 3 and t[1] == 1 and (t[2] == 13 or t[2] == 14):
			counts["avatar_rows"] += 1
			for i in range(it.req_level_types.size()):
				if it.req_level_types[i] == 1:
					counts["level_req"] += 1
				elif it.req_level_types[i] > 10:
					counts["mastery_req"] += 1
		if t[0] == 3 and t[1] == 1 and t[2] == 13:
			var k: String = ["", "hat", "dress", "attach", "flag"][clampi(t[3], 0, 4)] if t[3] <= 4 else ""
			if k != "" and w:
				counts[k] += 1
		elif t[0] == 3 and t[1] == 1 and t[2] == 14 and w:
			counts["devil"] += 1
		elif t[0] == 3 and t[1] == 2 and t[2] == 1 and t[3] == 1:
			if w and MallPreview.is_attack_pet_word(int((refs.get(it.desc1, {}) as Dictionary).get("type_word", 0))):
				counts["attack"] += 1
			else:
				counts["flute_bad"] += 1
		elif t[0] == 3 and t[1] == 2 and t[2] == 1 and t[3] == 2:
			if w and MallPreview.is_pick_pet_word(int((refs.get(it.desc1, {}) as Dictionary).get("type_word", 0))):
				counts["pick"] += 1
			else:
				counts["scroll_bad"] += 1
		elif t[0] == 3 and t[1] == 3 and w:
			counts["horse"] += 1
	print("real archive: wearable %s" % str(counts))
	_check(counts["hat"] > 0 and counts["dress"] > 0 and counts["flag"] > 0, "real: hats, dresses and flags are wearable")
	_check(counts["attach"] == 0 and counts["devil"] == 0 and counts["horse"] == 0, "real: no attachment, devil's spirit or horse item is")
	_check(counts["attack"] > 0 and counts["flute_bad"] == 0, "real: every 3/2/1/1 item names an attack pet (%d)" % counts["attack"])
	_check(counts["pick"] > 0 and counts["scroll_bad"] == 0, "real: every 3/2/1/2 item names a pick pet (%d)" % counts["pick"])
	_check(counts["mastery_req"] == 0, "real: no avatar or devil's spirit asks for a mastery (0x100 never decides here; %d rows, %d type-1 level pairs)" % [counts["avatar_rows"], counts["level_req"]])
	var chars := 0
	var odd := 0
	for code in refs:
		if String(code).begins_with("CHAR_"):
			chars += 1
			if float(refs[code]["scale"]) != 1.0:
				odd += 1
	_check(chars > 0 and odd == 0, "real: every CHAR_ row's Scale is 100 (the body's late scale changes nothing): %d rows" % chars)
	mp.free()

## A real body and a real pet through MallPreview: the pan box and the zoom
## range the original would compute for them (MEASURED here), the stand
## clips' IsCyclic, the try-on of a real hat, the zone-lit materials.
func _test_real_models() -> void:
	var data_path := MEDIA.get_base_dir().path_join("Data.pk2")
	if not FileAccess.file_exists(MEDIA) or not FileAccess.file_exists(data_path):
		print("SKIP real models (no archives)")
		return
	var media := Pk2Reader.open(MEDIA)
	var data := Pk2Reader.open(data_path)
	var items: Dictionary = ItemTableReader.load_all(media)
	var p := RealProvider.new()
	p.items = items
	p.data = data
	p.appearance = CharacterAppearance.from_archives(data, media, items)
	p.cos_table = CosTable.new()
	var refs := {}
	for path in CharTables.table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			var bytes := media.read_file(entry)
			p.cos_table.parse(bytes)
			MallModels.parse_refs(bytes, refs)
	p.refs = refs
	p.scales = {}
	for code in refs:
		p.scales[int(refs[code]["id"])] = float(refs[code]["scale"])
	var cat := p.appearance.catalog()
	var e := cat.get_entry(p.body_ref) if cat != null else null
	_check(e != null and e.is_body, "body %d is a catalogue body" % p.body_ref)
	if e == null:
		return
	p.facts = {"ref": p.body_ref, "sex": e.sex, "country": e.race, "level": 100, "str": 300, "int": 300}
	var mp := MallPreview.new()
	root.add_child(mp)
	mp.setup(p)
	mp.create()
	var b := mp.box()
	var span := maxf(b.size.x, b.size.z)
	print("MEASURED %s: pan box x [%.2f, %.2f] y [%.2f, %.2f] z [%.2f, %.2f]; zoom [%.2f, %.2f]" % [
		e.code, b.position.x, b.end.x, b.position.y, b.end.y, b.position.z, b.end.z, span + 1.0, span + 40.0])
	_check(b.end.y == 20.0 and b.position.y <= 0.0 and b.size.x > 0.0, "a real body's box: max y 20, min y <= 0, a width")
	_check(span + 1.0 < 35.0 and 35.0 < span + 40.0, "the start distance 35 lies inside the zoom range")
	var body := mp.model(0)
	_check(body.stand != null and body.stand.cyclic, "the body's STAND clip is cyclic (it loops): %s" % (body.stand.animation_name if body.stand != null else "none"))
	# Handedness, measured: facing the camera, the body's right hand is drawn
	# on the screen's LEFT (the doll's rule, round 633's review), and a drag
	# to the right turns the face toward the screen's right.
	var cam := mp.get_camera()
	var sk := body.skel as Skeleton3D
	var rh := _bone_screen(cam, sk, "Bip01 R Hand")
	var lh := _bone_screen(cam, sk, "Bip01 L Hand")
	var head := _bone_screen(cam, sk, "Bip01 Head")
	print("MEASURED %s at yaw 0: R hand %s, L hand %s, head %s (picture 215x332)" % [e.code, rh.round(), lh.round(), head.round()])
	_check(rh.x < lh.x, "the right hand is on the screen's left: the body faces the camera, not mirrored")
	_check(head.x > 90.0 and head.x < 125.0 and head.y > 0.0 and head.y < 166.0, "the head is centred in the upper half")
	_check(absf(_facing_dx(cam, sk)) < 0.5, "at yaw 0 the face points at the camera")
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), RECT)
	mp.handle_input(_motion(Vector2(100 + 215.0 / 8.0, 100)), RECT)
	_check(_facing_dx(cam, sk) > 1.0, "a drag to the right turns the face to the screen's right (%.1f px)" % _facing_dx(cam, sk))
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(100 + 215.0 / 8.0, 100)), RECT)
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), RECT)
	mp.handle_input(_motion(Vector2(100 - 215.0 / 8.0, 100)), RECT)
	mp.handle_input(_btn(MOUSE_BUTTON_LEFT, false, Vector2(100 - 215.0 / 8.0, 100)), RECT)
	_check(absf(_facing_dx(cam, sk)) < 0.5 and _near(mp.stored_angle(), 0.0), "dragged back: facing the camera again")
	_check(body.materials.size() > 0, "the body's materials are the zone-lit ones (%d)" % body.materials.size())
	# A real hat for this body's sex and race.
	var hat := 0
	for id in items:
		var it: ItemTableReader.Item = items[id]
		if it.type_ids.size() >= 4 and it.type_ids[0] == 3 and it.type_ids[1] == 1 and it.type_ids[2] == 13 \
				and it.type_ids[3] == 1 and it.bionic == 0 and (it.req_gender == e.sex or it.req_gender == 2) \
				and (it.country == 3 or it.country == e.race) and it.model_path != "":
			hat = int(id)
			break
	_check(hat != 0, "a hat for %s found (%d)" % [e.code, hat])
	if hat != 0:
		var meshes_before := body.skel.find_children("*", "MeshInstance3D", true, false).size()
		var r := mp.wear(hat)
		_check(r["ok"] and mp.body_avatars().has(hat), "the real hat is tried on")
		var meshes_after := mp.model(0).skel.find_children("*", "MeshInstance3D", true, false).size()
		print("body meshes %d -> %d with the hat" % [meshes_before, meshes_after])
	var flute := 0
	for id in items:
		var it: ItemTableReader.Item = items[id]
		if it.type_ids.size() >= 4 and it.type_ids[0] == 3 and it.type_ids[1] == 2 and it.type_ids[2] == 1 and it.type_ids[3] == 1:
			flute = int(id)
			break
	var r2 := mp.wear(flute)
	var pet := mp.model(mp.slots()["attack"]) if mp.slots()["attack"] >= 0 else null
	_check(r2["ok"] and pet != null and pet.skel != null, "a real flute's pet is made (%s)" % (items[flute] as ItemTableReader.Item).desc1)
	if pet != null and pet.skel != null:
		var pb := MallPreview.model_bounds(pet.skel)
		print("MEASURED pet %s: bounds %s, Scale %.2f, stand %s cyclic %s" % [(items[flute] as ItemTableReader.Item).desc1, pb, pet.scale,
			pet.stand.animation_name if pet.stand != null else "none", pet.stand.cyclic if pet.stand != null else false])
		_check(pet.stand != null and pet.stand.cyclic, "the pet's STAND clip loops")
		_check(_vnear(mp.box().end, b.end) and _vnear(mp.box().position, b.position), "the pet does not change the box")
		var pet_x := cam.unproject_position(pet.skel.global_transform.origin).x
		_check(pet_x < 107.5, "the attack pet stands on the screen's left (D3D x -5.5): %.1f" % pet_x)
	mp.step(0.5)
	_check(_near(mp.model(0).t, 0.5), "the models step")
	mp.set_active(true)
	await process_frame
	await process_frame
	_check(mp.model(0).t > 0.5, "an active preview steps itself each frame")
	mp.queue_free()
	await process_frame

func _bone_screen(cam: Camera3D, sk: Skeleton3D, bone: String) -> Vector2:
	var i := sk.find_bone(bone)
	if i < 0:
		return Vector2(-1, -1)
	return cam.unproject_position(sk.global_transform * sk.get_bone_global_pose(i).origin)

## How far right of the head a point 3 in front of it lands (the body's front
## is its own -Z in the file's coordinates).
func _facing_dx(cam: Camera3D, sk: Skeleton3D) -> float:
	var i := sk.find_bone("Bip01 Head")
	if i < 0:
		return 0.0
	var h := sk.get_bone_global_pose(i).origin
	var a := cam.unproject_position(sk.global_transform * h)
	var b := cam.unproject_position(sk.global_transform * (h + Vector3(0, 0, -3)))
	return b.x - a.x
