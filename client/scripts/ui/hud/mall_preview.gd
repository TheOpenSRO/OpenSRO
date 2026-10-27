extends SubViewport
class_name MallPreview

## Round 837: the item mall's character preview, the right panel of
## CIFNewItemMall (docs/protocol/item_mall.md section 4 and its corrections;
## item_mall_verify.md section 4 and "Missed / The try-on"). Retail draws it
## with a CIFRenderStatic (ID 123, mall +0x850) over the rect of control 111,
## 215 x 332; this SubViewport is that control's render, shown by the window
## through a TextureRect (ViewportPixels keeps it at physical pixels), and the
## window forwards the rect's mouse input to handle_input.
##
## Labels: READ (an address in sro_client.exe, re-read this round in the
## disassembly unless it says "decompile"), MEASURED (looked at the data),
## INFERRED (with why), OURS (this client's choice).
##
## **The models** (READ 0x561780 / 0x55f100 / 0x55f470 / 0x55f520): a vector
## of model wrappers, each with a base position (+0x14), a yaw (+0xc) and a
## scale (+0x10 = its characterdata Scale / 100, 0x55e550). Its world matrix
## is diag(scale) x RotY(-yaw) with the translation base x RotY(-yaw), unscaled:
## m00 = cos, m02 = sin, m20 = -sin, m22 = cos (0x55f520). So a drag turns
## every model as one turntable about the origin, where the body stands; the
## pets orbit it. The body's matrix is the identity until the first drag
## (0x5603b0 at the build, item_mall_verify "Missed" 7); a pet gets its own at
## once (0x55fe70). The slots +0x854 (body), +0x858 (pick pet), +0x85c
## (attack pet) are INDICES into that vector and are not renumbered when a
## model is erased (0x561480 memmoves the vector): kept that way here.
##
## **The camera** (READ 0x7d8bf0, 0xbae580 / 0xbae810, item_mall_verify W3):
## look-at (0, 13, 0), angles (0, 2pi, 0), distance 35, eye = at -
## (0, 0, dist) x RotZ x RotX x RotY(2pi), up +Y, LookAtLH, a VERTICAL field of
## view of 60 degrees (PerspectiveFovLH), near 1, far 500, aspect = the
## control's w / h. In D3D's left-handed space the eye is (0, 13, -35) looking
## toward +Z. Here the models hang under a D3DSpace node (scale z -1, the
## paper doll's and the portrait's convention; AGENTS.md), so a D3D point
## (x, y, z) is Godot's (x, y, -z): the eye is (0, 13, +35) looking along
## Godot's -Z with +Y up -- Camera3D's own orientation, an identity basis.
## Pan and zoom move the look-at point and the eye with it (the angles never
## change in the mall): eye_godot = (tx, ty, dist - tz).
##
## **The light** (decided on evidence): CIFRenderStatic's draw (vslot_052,
## 0x560c30) fills a D3DLIGHT9 (+0x538: directional, diffuse 0.7, ambient
## 0.3, specular 1.0, range 10000; direction the camera's at - eye, copied
## each tick by vslot_012 0x560fc0) and hands it to the DEVICE's SetLight
## (`call [vtable+0xcc]` on the device 0x1112428 -- IDirect3DDevice9 slot 51).
## The models are then drawn by vslot_054 (0x560ee0) through the global
## object renderer (0xbbda90 -> 0xbc1030; its +0x28 / +0xc / +0x14 / +0x18),
## the very calls CIFPlayerMiniInfo's portrait makes (0x7b7740: device +0xcc,
## then 0xbbda90's +0x28 / +0xc / +0x14 / +0x18). Round 635 READ that renderer
## to be CObjRendererVS, whose vertex shader's light constants come only from
## the world draw (vslot_025 0xbeecc0) -- the fixed-function light is state no
## draw reads. So the preview is lit as the portrait and the equipment doll
## are: by the zone's light, PlayerPortrait's materials (to-light (0.707,
## 0.707, 0) in the file's coordinates, object colour 0.6 x ambient, material
## x diffuse, MODULATE2X). The +0x538 light is not modelled.
##
## **The clear** (READ 0x560c30): Clear(0, 0, 2 = ZBUFFER, 0, 1.0, 0) -- the
## depth only; the frame art (layout controls 112 and 130) shows behind the
## body. Here: a transparent background.
##
## **Animation** (READ 0x5602c0, 0x560030 / 0x55ff20, item_mall_verify 4a
## step 4): action 0 (STAND1) with fade-in 0, events off, speed 1, weight 1;
## the clip's own IsCyclic decides loop or hold, and every play starts it
## from t = 0 -- at the build, at every try-on and take-off on the body, and
## when a pet is made or swapped. The models advance each frame (vslot_012's
## 0xa5ac80(1, 0)) while the preview renders (set_active).

signal changed

## READ: control 111's rect (ifnewitemmall.txt, `..._RIGHT`, 567,46,215,332),
## the render's viewport (0x7d8fcb, 0x6531a0).
const VIEW_SIZE := Vector2i(215, 332)
## READ 0x7d8c86: the look-at (0, 13.0 (0xd8acc8), 0).
const TARGET_START := Vector3(0.0, 13.0, 0.0)
## READ 0x55efd0's angles (0, 0xdcc1a4 = 6.2831855, 0): RotX, RotY, RotZ.
const ANGLE_X := 0.0
const ANGLE_Y := 6.2831854820251465
const ANGLE_Z := 0.0
## READ 0xdcc1a0: the distance.
const DIST_START := 35.0
## READ: the camera's vertical field of view (camera ctor 0xbae0a0, 60.0),
## near 1.0 (+0x42c), far 500.0 (0xdcc19c, written at 0x7d8cd8).
const FOV_DEG := 60.0
const NEAR := 1.0
const FAR := 500.0
## READ: the wheel's step, +2.0 (0xd86ecc) for a delta > 0, else -2.0
## (0xd89ca8), at 0x55ee33..0x55ee43 (`jle`: a zero delta is -2).
const ZOOM_STEP := 2.0
## READ: +0x398 = 40.0 (0xd82ef4, ctor 0x560b3f..0x560b58), the zoom range
## over the box's span.
const ZOOM_RANGE := 40.0
## READ: the pan's 2.0 (0xe1b898).
const PAN_FACTOR := 2.0
## READ: the box's min y is pos.y + aabb.min.y x 0.5 (0xe1b7d0, 0x55f1c0).
const BOX_MIN_Y_FACTOR := 0.5
## READ: a CICUser's +0x22c, the box's max y, is 20.0 from its constructor
## (0x9dbf50 at 0x9dc06a..0x9dc075, float 0xd88108; +0x230 / +0x234 the same,
## +0x23c "done" = 1). INFERRED that it stays 20: only 0x9ca600 and 0x9cd090
## restart that interpolator (+0x23c = 0), and nothing in the preview's
## creation (0x561780) calls them.
const BODY_HEIGHT := 20.0
## READ: the wrap's 2pi is the double 0xd81930 (= float 2pi), the drag's pi
## the double 0xd81948 (= float pi).
const TWO_PI := 6.2831854820251465
const PI_F := 3.1415927410125732
## READ (0x7d88c0): the attack (growth) pet, COS 1/2/3/3, in slot +0x85c at
## (-5.5, 0, -2.5) (0xdcc198, 0xdcc194); the pick (ability) pet, COS 1/2/3/4,
## in slot +0x858 at (4.5, 0, -2.5) (0xdcc190).
const ATTACK_PET_AT := Vector3(-5.5, 0.0, -2.5)
const PICK_PET_AT := Vector3(4.5, 0.0, -2.5)
## READ (0x7df560): the refusal's text key, put on the system line by
## 0x7781b0(5, ...). The window prints it (OURS split).
const REFUSE_KEY := "UIIT_MSG_STRGERR_EQUIPITEM"

## One model of the vector (+0x380): the wrapper 0x55f100 builds.
class Model:
	var node: Node3D
	var skel: Node3D
	var ref_id := 0
	## +0x14..+0x1c, +0xc, +0x10.
	var base := Vector3.ZERO
	var yaw := 0.0
	var scale := 1.0
	## Whether 0x55f470 has set its world matrix; until then the body's is
	## the identity 0x5603b0 gave it.
	var matrix_set := false
	var stand: BanReader.ParsedAnimation = null
	var t := 0.0
	var materials: Array = []

var provider: Object = null
var _root: Node3D
var _space: Node3D
var _camera: Camera3D
var _environment: Environment
## The zone-lit materials (PlayerPortrait's machinery, off the tree, as the
## paper doll borrows it).
var _lighter: PlayerPortrait = null

var _models: Array = []
## +0x854, +0x858, +0x85c.
var _slot_body := -1
var _slot_pick := -1
var _slot_attack := -1
## The try list (+0x810 / +0x814): RefItemIDs in the order put on.
var _tried: Array = []
## The body's attached avatars (its +0x160 map): RefItemIDs.
var _body_avatars: Array = []

## +0x1f0: the mouse is on (Start sets it, 0x7d9144).
var _mouse_on := false
## +0x394: the angle of the last left release (reset only by the ctor).
var _angle := 0.0
## +0x3cc: the left drag's start angle AND the right drag's start y (shared).
var _start_shared := 0.0
## +0x3c8: the right drag's start x.
var _start_x := 0.0
## +0x3c0 / +0x3c4: where the last press was.
var _press := Vector2.ZERO
## +0x3d0 / +0x3d4: a left / right drag is on.
var _left_drag := false
var _right_drag := false
## Whether this control holds the mouse capture (0xb9d9b0: the holder at
## 0x110f5fc is this).
var _captured := false
## +0x3f4..+0x3fc, +0x424, +0x418..+0x420.
var _target := TARGET_START
var _dist := DIST_START
var _angles := Vector3(ANGLE_X, ANGLE_Y, ANGLE_Z)
## The pan box (+0x39c..+0x3a4 min, +0x3a8..+0x3b0 max).
var _box_min := Vector3.ZERO
var _box_max := Vector3.ZERO
var _active := false

func _init() -> void:
	name = "MallPreview"
	size = VIEW_SIZE
	transparent_bg = true
	own_world_3d = true
	disable_3d = false
	render_target_update_mode = SubViewport.UPDATE_DISABLED

	_root = Node3D.new()
	_root.name = "MallScene"
	add_child(_root)
	var env := WorldEnvironment.new()
	_environment = Environment.new()
	# The depth-only clear: nothing behind the models (a transparent buffer).
	_environment.background_mode = Environment.BG_CLEAR_COLOR
	# Nothing here is lit by Godot: the materials light themselves.
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = _environment
	_root.add_child(env)

	_camera = Camera3D.new()
	_camera.name = "MallCamera"
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.fov = FOV_DEG
	_camera.near = NEAR
	_camera.far = FAR
	_camera.current = true
	_root.add_child(_camera)

	_space = Node3D.new()
	_space.name = "D3DSpace"
	_space.scale = Vector3(1.0, 1.0, -1.0)
	_root.add_child(_space)
	_lighter = PlayerPortrait.new()
	_update_camera()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _lighter != null and is_instance_valid(_lighter):
		_lighter.free()

## The provider (MallModels, or any object with its methods).
func setup(p: Object) -> void:
	provider = p
	_pull_zone_light()

## The zone's light (World3D's environment channels 2 and 3), as the doll's.
func set_zone_light(diffuse_channel: Color, ambient_channel: Color) -> void:
	_lighter.set_zone_light(diffuse_channel, ambient_channel)

## Renders and steps the models while the window shows them (OURS: the
## CIFRenderStatic's draw and vslot_012 run for a shown control). Under a
## CanvasItem (the window's TextureRect) it follows that item's showing by
## itself; set_active overrides until the next change.
func set_active(on: bool) -> void:
	_active = on
	render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		_pull_zone_light()

func _enter_tree() -> void:
	var view := get_parent() as CanvasItem
	if view != null and not view.visibility_changed.is_connected(_follow_view):
		view.visibility_changed.connect(_follow_view)
		_follow_view.call_deferred()

func _exit_tree() -> void:
	var view := get_parent() as CanvasItem
	if view != null and view.visibility_changed.is_connected(_follow_view):
		view.visibility_changed.disconnect(_follow_view)

func _follow_view() -> void:
	var view := get_parent() as CanvasItem
	if view != null and is_instance_valid(view) and view.is_inside_tree():
		set_active(view.is_visible_in_tree())

## The zone's light as the world has it now (World3D._portrait_zone_light,
## which it pushes to the doll and the portrait): read on showing and once a
## second while shown (OURS), pushed only when it changed.
var _zone_seen: Array = []
var _zone_check := 0.0
func _pull_zone_light() -> void:
	if provider == null or not provider.has_method("zone_light"):
		return
	var z: Array = provider.call("zone_light")
	if z.size() == 2 and z != _zone_seen:
		_zone_seen = z
		set_zone_light(z[0], z[1])

func is_active() -> bool:
	return _active

func get_camera() -> Camera3D:
	return _camera

# --- Create, build, Original --------------------------------------------------

## The window's Create (0x7d9139..0x7d915e), what the window calls when it
## opens: the control is new (its ctor 0x560a50 zeroes +0x394 and +0x1f0),
## Start (0x5612f0) clears every model and resets the camera, the drags and
## the box, +0x1f0 = 1 turns the mouse on, then the build (0x7d8bf0, _build).
## The try list is the new window's, empty. create() is the same call.
func build() -> void:
	create()

func create() -> void:
	_angle = 0.0
	_start_x = 0.0
	_start_shared = 0.0
	_press = Vector2.ZERO
	_left_drag = false
	_right_drag = false
	_release_capture()
	_tried.clear()
	_delete_all_models()
	_target = Vector3.ZERO
	_angles = Vector3.ZERO
	_dist = 40.0 # READ 0x5612f0: +0x424 = 0xd82ef4 (40.0), overwritten by the build
	_box_min = Vector3.ZERO
	_box_max = Vector3.ZERO
	_mouse_on = true
	_build()

## The build (0x7d8bf0), from Create and from Original.
func _build() -> void:
	_slot_body = -1
	_slot_pick = -1
	_slot_attack = -1
	var facts: Dictionary = provider.call("player_facts")
	# 0x561930: a new body from the player's RefObj, dressed from the
	# equipment window's avatar (its avatars and its nine slots).
	_body_avatars.clear()
	for ref in provider.call("worn_avatars"):
		if int(ref) != 0 and not _body_avatars.has(int(ref)):
			_body_avatars.append(int(ref))
	_slot_body = _new_model(int(facts.get("ref", 0)), provider.call("build_body", _body_avatars.duplicate()))
	_play(_slot_body)
	_compute_box()
	_target = TARGET_START
	_angles = Vector3(ANGLE_X, ANGLE_Y, ANGLE_Z)
	_dist = DIST_START
	# 0x5603b0(idx, 0): the body's world matrix is the identity.
	var body := _model_at(_slot_body)
	if body != null:
		body.matrix_set = false
		_apply_matrix(body)
	# The five avatar slots go through the try-on (0x7d8bd0(slot, 0)): into
	# the try list, attached again (a no-op, READ 0x452230 / 0xa5e270).
	for ref in provider.call("worn_avatars"):
		if int(ref) != 0:
			_try_on(int(ref))
	_update_camera()
	changed.emit()

## Original (109, 0x7d8d30, run by the window only with no mall box open):
## the try list cleared and every model deleted (0x7d8480 -> 0x561040), then
## the build. The buy list (0x7d8840) is the window's. +0x394 is NOT reset
## (its only writers are the ctor and the left release), so the body comes
## back at yaw 0 while a pet tried next takes the old angle, and the next
## left press resumes from it.
func original() -> void:
	_tried.clear()
	_delete_all_models()
	_build()

## The try list's RefItemIDs, in the order put on.
func tried() -> Array:
	return _tried.duplicate()

## The body's attached avatars (for the tests and the log).
func body_avatars() -> Array:
	return _body_avatars.duplicate()

# --- What can be worn ------------------------------------------------------------

## The cell's +0x551 (READ 0x7df430) for a good whose first item is `ref_id`:
## an avatar 3/1/13 whose TypeID4 is not 3 (no attachment; hats 1, dresses 2,
## flags 4), or a 3/2/1 item whose Desc1 names a COS 1/2/3/3 or 1/2/3/4 with
## the Bionic bit (0x666c00 / 0x666c40: the attack and the pick pet). Never a
## devil's spirit (3/1/14), a horse (summoned by 3/3/3 items) or anything
## else; Bionic items never. The window refuses a bundle itself (+0x555 and
## 0x8bf0d0: a good of two or more items).
func can_wear(ref_id: int) -> bool:
	var item: ItemTableReader.Item = provider.call("item", ref_id)
	if item == null:
		return false
	var tw := item.type_word()
	if is_avatar_word(tw):
		if type4_of(tw) != 3:
			return true
	if (tw & 2) != 0 or (tw & 0x1c) != 0xc or (tw & 0x60) != 0x40 or (tw & 0x780) != 0x80:
		return false
	var cos := _cos_of(item)
	if cos.is_empty():
		return false
	var cw := int(cos["type_word"])
	return is_attack_pet_word(cw) or is_pick_pet_word(cw)

## The can-equip test the try-on runs, 0x8bb570(-1), as far as an item row
## and the player decide it (READ, the disassembly of 0x8bb570):
## - 0x02: the item is equipment, 3/1, without the Bionic bit;
## - 0x08: ref +0x1c8 (ReqStr, column 59) <= the player's Str (word +0x87c,
##   `movzx ecx, word [edx+0x87c]` at 0x8bb5fd);
## - 0x10: ref +0x1cc (ReqInt, column 60) <= the player's Int (+0x87e);
## - 0x20: the four (type +0xd0+4i, level +0xe0+4i) pairs: a type-1 pair at or
##   under the player's level (byte +0x868, 0x8bb65b) passes at once; a type-1
##   pair over it fails unless a later one passes; no type-1 pair passes;
## - 0x100: a pair whose type is over 10 is a mastery: when the player has it
##   (FUN_009c1180) its level must reach the pair's, same rule; one the player
##   lacks is skipped;
## - 0x40: ref +0x1c4 (ReqGender, column 58) is the player's sex or 2;
## - 0x200: ref +0x9c (Country, column 14) is 3 or the player's.
## Not decided here (INFERRED to pass for a mall good's item): 0x01 (the
## item's byte +0x28), 0x04 (+0xf4 / +0x98) and 0x800 (+0x178), the item
## instance's own fields; 0x80 (a weapon / shield pairing, only for TypeID3
## 1 and 9 and shields) and 0x400 (3/1/6/16 only) never apply to avatars.
## (item_mall_verify.md's "+0x21f" and "+0x21a" are the decompiler's int*
## scaling of +0x87c and +0x868.)
func can_equip(ref_id: int) -> bool:
	var item: ItemTableReader.Item = provider.call("item", ref_id)
	if item == null:
		return false
	var tw := item.type_word()
	if (tw & 2) != 0 or (tw & 0x1c) != 0xc or (tw & 0x60) != 0x20:
		return false
	var facts: Dictionary = provider.call("player_facts")
	if item.req_str > int(facts.get("str", 0)):
		return false
	if item.req_int > int(facts.get("int", 0)):
		return false
	var n := mini(item.req_level_types.size(), item.req_levels.size())
	var ok := true
	for i in range(n):
		if item.req_level_types[i] == 1:
			if item.req_levels[i] <= int(facts.get("level", 0)):
				ok = true
				break
			ok = false
	if not ok:
		return false
	ok = true
	for i in range(n):
		if item.req_level_types[i] > 10:
			var m: int = provider.call("mastery_level", item.req_level_types[i]) if provider.has_method("mastery_level") else -1
			if m >= 0:
				if item.req_levels[i] <= m:
					ok = true
					break
				ok = false
	if not ok:
		return false
	if item.req_gender != int(facts.get("sex", -1)) and item.req_gender != 2:
		return false
	if item.country != 3 and item.country != int(facts.get("country", -1)):
		return false
	return true

## Wear Item (the cell menu, 0x7df560, for a good whose first item is
## `ref_id`): an equipment item (3/1) that fails can_equip is refused with
## "Cannot equip the selected item" and nothing changes; otherwise the try-on
## (0x7d88c0). OURS: an item can_wear refuses is refused too (the window only
## offers Wear Item where +0x551 is set). The window's own gates (a mall box
## open, a purchase pending, a bundle) and its buy list (0x7d8720) are its.
## Returns {"ok": bool, "reason": "" | "not_wearable" | "equip",
## "text_key": the system line's key when refused for can-equip}.
func wear(ref_id: int) -> Dictionary:
	if provider == null:
		return {"ok": false, "reason": "not_wearable", "text_key": ""}
	if not can_wear(ref_id):
		return {"ok": false, "reason": "not_wearable", "text_key": ""}
	var item: ItemTableReader.Item = provider.call("item", ref_id)
	var tw := item.type_word()
	if (tw & 2) == 0 and (tw & 0x1c) == 0xc and (tw & 0x60) == 0x20 and not can_equip(ref_id):
		return {"ok": false, "reason": "equip", "text_key": REFUSE_KEY}
	_try_on(ref_id)
	changed.emit()
	return {"ok": true, "reason": "", "text_key": ""}

## Takes `ref_id` off the preview (0x7d8500): an avatar is detached from the
## body (0x55ff20, the stand replayed); with `reapply` the player's own worn
## avatar whose whole 16-bit type word equals the item's goes back on
## (0x7d8bd0, the lump buy's reply does this, 0x87e2a3..0x87e2d5). A pet's
## model is deleted (0x561480, by its COS ref) and its slot reset. An item
## not in the try list changes nothing.
func take_off(ref_id: int, reapply: bool) -> void:
	_take_off(ref_id, reapply)
	changed.emit()

# --- The try-on internals ----------------------------------------------------------

static func is_avatar_word(tw: int) -> bool:
	return (tw & 2) == 0 and (tw & 0x1c) == 0xc and (tw & 0x60) == 0x20 and (tw & 0x780) == 0x680

static func type4_of(tw: int) -> int:
	return (tw >> 11) & 0x1f

## 0x666c00: COS 1/2/3/3 with the Bionic bit, the attack (growth) pet.
static func is_attack_pet_word(tw: int) -> bool:
	return (tw & 2) != 0 and (tw & 0x1c) == 4 and (tw & 0x60) == 0x40 and (tw & 0x780) == 0x180 and (tw & 0xf800) == 0x1800

## 0x666c40: COS 1/2/3/4 with the Bionic bit, the pick (ability) pet.
static func is_pick_pet_word(tw: int) -> bool:
	return (tw & 2) != 0 and (tw & 0x1c) == 4 and (tw & 0x60) == 0x40 and (tw & 0x780) == 0x180 and (tw & 0xf800) == 0x2000

## TypeID1..4 equal (the masks 0x1c, 0x60, 0x780, 0xf800 of 0x7d891a..
## 0x7d8944: the CashItem and Bionic bits do not count).
static func same_type(a: int, b: int) -> bool:
	return ((a ^ b) & (0x1c | 0x60 | 0x780 | 0xf800)) == 0

## The COS a 3/2/1 item summons: 0x9461a0(item ref + 0x304), its Desc1.
func _cos_of(item: ItemTableReader.Item) -> Dictionary:
	if item == null or item.desc1 == "":
		return {}
	return provider.call("char_ref", item.desc1)

## 0x7d8bd0(item, goods) -> 0x7d88c0(item); the buy list's 0x7d8720 is the
## window's (a no-op for the build's goods 0).
func _try_on(ref_id: int) -> void:
	var item: ItemTableReader.Item = provider.call("item", ref_id)
	if item == null:
		return
	var tw := item.type_word()
	# One per exact TypeID1..4: the first entry of the same type comes off,
	# without the reapply.
	for other in _tried.duplicate():
		var o: ItemTableReader.Item = provider.call("item", int(other))
		if o != null and same_type(o.type_word(), tw):
			_take_off(int(other), false)
			break
	_tried.append(ref_id)
	if can_equip(ref_id):
		var body := _model_at(_slot_body)
		if body != null and body.skel != null:
			_attach(ref_id, tw)
		return
	# Not equipment that passes: a COS item 3/2/1 (non-Bionic).
	if (tw & 2) != 0 or (tw & 0x1c) != 0xc or (tw & 0x60) != 0x40 or (tw & 0x780) != 0x80:
		return
	var cos := _cos_of(item)
	if cos.is_empty():
		return
	var cw := int(cos["type_word"])
	if (cw & 2) == 0:
		return
	var cos_ref := int(cos["id"])
	if is_attack_pet_word(cw):
		_slot_attack = _place_pet(_slot_attack, cos_ref, ATTACK_PET_AT)
	elif is_pick_pet_word(cw):
		_slot_pick = _place_pet(_slot_pick, cos_ref, PICK_PET_AT)

## A pet in its slot: made once (0x561780) or the slot's model re-made for
## the new COS (0x561170), placed at `at` with yaw +0x394 (0x55fe70), action 0
## (0x5602c0). Returns the slot's index.
func _place_pet(slot: int, cos_ref: int, at: Vector3) -> int:
	var built: Dictionary = provider.call("build_cos", cos_ref)
	if slot == -1:
		slot = _new_model(cos_ref, built)
	else:
		var m := _model_at(slot)
		if m == null:
			return slot
		m.ref_id = cos_ref
		m.scale = float(provider.call("ref_scale", cos_ref))
		_set_model_node(m, built)
	var pet := _model_at(slot)
	if pet == null:
		return slot
	pet.base = at
	pet.yaw = _angle
	pet.matrix_set = true
	_apply_matrix(pet)
	_play(slot)
	return slot

## AttachAvatarVisual (0x9daf80 -> 0xa60ef0) for an avatar or a devil's
## spirit, then the rebuild and action 0 again (0x560030 with 1).
## InstallEquipVisual's branch (any other 3/1 item) is unreachable here:
## can_wear admits avatars only and the five slots hold avatars and devil's
## spirits.
func _attach(ref_id: int, tw: int) -> void:
	var avatarish := (tw & 2) == 0 and (tw & 0x1c) == 0xc and (tw & 0x60) == 0x20 \
		and ((tw & 0x780) == 0x680 or (tw & 0x780) == 0x700)
	if not avatarish:
		return
	if _body_avatars.has(ref_id):
		# Already on (0xa609f0 skips a resource attached, READ 0xa5e270): the
		# rebuild changes nothing drawn; the stand still starts over.
		_play(_slot_body)
		return
	_body_avatars.append(ref_id)
	_rebuild_body()

func _detach(ref_id: int, tw: int) -> void:
	var avatarish := (tw & 2) == 0 and (tw & 0x1c) == 0xc and (tw & 0x60) == 0x20 \
		and ((tw & 0x780) == 0x680 or (tw & 0x780) == 0x700)
	if avatarish and _body_avatars.has(ref_id):
		_body_avatars.erase(ref_id)
		_rebuild_body()
		return
	_play(_slot_body)

## The model's rebuild (vslot 0x20) and its action replayed: here a new
## dressed copy in the same wrapper (its world matrix and yaw kept).
func _rebuild_body() -> void:
	var body := _model_at(_slot_body)
	if body == null:
		return
	_set_model_node(body, provider.call("build_body", _body_avatars.duplicate()))
	_play(_slot_body)

func _take_off(ref_id: int, reapply: bool) -> void:
	for i in range(_tried.size()):
		if int(_tried[i]) != ref_id:
			continue
		var item: ItemTableReader.Item = provider.call("item", ref_id)
		if item == null:
			continue
		var tw := item.type_word()
		if (tw & 2) != 0:
			continue
		if (tw & 0x1c) == 0xc and (tw & 0x60) == 0x20:
			_detach(ref_id, tw)
			_tried.remove_at(i)
			if reapply:
				var worn: Array = provider.call("worn_avatars")
				for w in worn:
					if int(w) == 0:
						continue
					var wi: ItemTableReader.Item = provider.call("item", int(w))
					if wi != null and wi.type_word() == tw:
						_try_on(int(w))
			return
		if (tw & 0x1c) == 0xc and (tw & 0x60) == 0x40 and (tw & 0x780) == 0x80:
			var cos := _cos_of(item)
			if not cos.is_empty():
				var cw := int(cos["type_word"])
				if not is_attack_pet_word(cw):
					if is_pick_pet_word(cw) and _slot_pick != -1:
						_delete_model_by_ref(int(cos["id"]))
						_slot_pick = -1
				elif _slot_attack != -1:
					_delete_model_by_ref(int(cos["id"]))
					_slot_attack = -1
			_tried.remove_at(i)
			return

# --- The models --------------------------------------------------------------------

func _new_model(ref_id: int, built: Dictionary) -> int:
	var m := Model.new()
	m.ref_id = ref_id
	m.node = Node3D.new()
	m.node.name = "Model%d" % _models.size()
	_space.add_child(m.node)
	# 0x55e550(1.0): +0x10 = ref +0x110 / 100.
	m.scale = float(provider.call("ref_scale", ref_id)) if provider.has_method("ref_scale") else 1.0
	_models.append(m)
	_set_model_node(m, built)
	return _models.size() - 1

func _set_model_node(m: Model, built: Dictionary) -> void:
	if m.skel != null and is_instance_valid(m.skel):
		m.skel.queue_free()
	m.skel = null
	m.materials = []
	m.stand = null
	var node = built.get("node") if built != null else null
	if node is Node3D:
		var skel := node as Node3D
		if skel.get_parent() != null:
			skel.get_parent().remove_child(skel)
		# The model's own scale (a body's Height factor), unsigned: this stage
		# mirrors itself (D3DSpace), as the portrait's.
		skel.transform = Transform3D(Basis.from_scale(skel.scale.abs()), Vector3.ZERO)
		m.node.add_child(skel)
		m.skel = skel
		var before: int = (_lighter.get("_materials") as Array).size()
		_lighter.call("_apply_materials", skel)
		m.materials = (_lighter.get("_materials") as Array).slice(before)
		m.stand = built.get("stand") as BanReader.ParsedAnimation
		# The body's action for its worn parts' own clips (WornItemFx: a part
		# replays its clip of the body's stand / walk / run, READ 0xa5faf0);
		# the world's bodies get it from AnimSounds as their clip plays.
		if m.stand != null:
			skel.set_meta(WornItemFx.BODY_CLIP_META, m.stand)
	_refresh_material_list()

## The light's list of materials: the live models' only.
func _refresh_material_list() -> void:
	var all: Array = []
	for m in _models:
		all.append_array((m as Model).materials)
	_lighter.set("_materials", all)

func _model_at(i: int) -> Model:
	if i < 0 or i >= _models.size():
		if i >= 0:
			# READ: retail's vector subscript throws "invalid vector<T>
			# subscript" (0x55f8d0) here; OURS: the operation is skipped.
			push_warning("MallPreview: model index %d of %d (retail throws here)" % [i, _models.size()])
		return null
	return _models[i]

## 0x5602c0 / the 0xbc replay: action 0 from t = 0.
func _play(i: int) -> void:
	var m := _model_at(i)
	if m == null:
		return
	m.t = 0.0
	_pose(m)

func _pose(m: Model) -> void:
	if m.stand == null or not (m.skel is Skeleton3D):
		return
	Skeleton3DBuilder.apply_ban_pose_at(m.skel as Skeleton3D, m.stand, m.t, m.stand.cyclic)

## 0x561480: the first model whose COS ref is `ref_id` is deleted and erased
## from the vector (the slots keep their numbers).
func _delete_model_by_ref(ref_id: int) -> void:
	for i in range(_models.size()):
		var m: Model = _models[i]
		if m.ref_id == ref_id:
			if is_instance_valid(m.node):
				m.node.queue_free()
			_models.remove_at(i)
			_refresh_material_list()
			return

## 0x561040: every model deleted, the vector emptied.
func _delete_all_models() -> void:
	for m in _models:
		if is_instance_valid((m as Model).node):
			(m as Model).node.queue_free()
	_models.clear()
	_refresh_material_list()

## The model's world matrix (0x55f470 when set, else the identity).
func _apply_matrix(m: Model) -> void:
	if not m.matrix_set:
		m.node.transform = Transform3D.IDENTITY
		return
	var r := Basis(Vector3.UP, -m.yaw)
	m.node.transform = Transform3D(r * Basis.from_scale(Vector3.ONE * m.scale), r * m.base)

## The world position of a model's base in the D3D space (a test hook).
func model_d3d_position(i: int) -> Vector3:
	var m := _model_at(i)
	return m.node.transform.origin if m != null else Vector3.INF

func model_count() -> int:
	return _models.size()

func model(i: int) -> Model:
	return _model_at(i)

func slots() -> Dictionary:
	return {"body": _slot_body, "pick": _slot_pick, "attack": _slot_attack}

## 0x561250 / 0x55f1c0: the box reset to 0, then grown by each model: x and
## z by base + its bounds, y down by base.y + 0.5 x its min y and up by its
## entity's +0x22c. At the build only the body exists, so the box is the
## body's (the pets never enter it). The bounds are the model's compound
## box (CCompChar slot 4, 0xc1f0a0: +0xb0), which 0xc2b2d0 resets to
## (FLT_MAX, -FLT_MAX) and grows by every part's mesh box (mesh +0x124,
## 0xc26a40: a plain min / max, no transform) -- READ. That +0x124 is the
## mesh's own vertex bounds is INFERRED (Godot's mesh AABB here).
func _compute_box() -> void:
	_box_min = Vector3.ZERO
	_box_max = Vector3.ZERO
	for m in _models:
		var mm := m as Model
		var b := model_bounds(mm.skel)
		_box_max.x = maxf(_box_max.x, mm.base.x + b.end.x)
		_box_max.y = maxf(_box_max.y, BODY_HEIGHT)
		_box_max.z = maxf(_box_max.z, mm.base.z + b.end.z)
		_box_min.x = minf(_box_min.x, mm.base.x + b.position.x)
		_box_min.y = minf(_box_min.y, mm.base.y + b.position.y * BOX_MIN_Y_FACTOR)
		_box_min.z = minf(_box_min.z, mm.base.z + b.position.z)

## The union of a model's mesh boxes, each in its own space and untransformed
## (0xc2b2d0 -> 0xc26a40): a weapon's box where its file puts it, not at the
## hand.
static func model_bounds(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	if root == null:
		return out
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or _in_effect(mi, root):
			continue
		var box := mi.mesh.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out

## Whether a mesh is a particle effect's (EfpEffect), not a part of the model.
static func _in_effect(n: Node, root: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != root:
		if p is EfpEffect:
			return true
		p = p.get_parent()
	return false

func box() -> AABB:
	return AABB(_box_min, _box_max - _box_min)

# --- The camera ----------------------------------------------------------------------

## The eye in D3D space: at - (0, 0, dist) x RotZ(+0x420) x RotX(+0x418) x
## RotY(+0x41c) (0xbae580's perspective path, row vectors).
func eye_d3d() -> Vector3:
	var v := Vector3(0.0, 0.0, _dist)
	v = PlayerPortrait._d3d_rot_z(v, _angles.z)
	v = PlayerPortrait._d3d_rot_x(v, _angles.x)
	v = PlayerPortrait._d3d_rot_y(v, _angles.y)
	return _target - v

func target_d3d() -> Vector3:
	return _target

func distance() -> float:
	return _dist

func stored_angle() -> float:
	return _angle

func _update_camera() -> void:
	var eye := PlayerPortrait.to_godot(eye_d3d())
	var at := PlayerPortrait.to_godot(_target)
	var up := Vector3(0.0, 1.0, 0.0)
	up = PlayerPortrait._d3d_rot_z(up, _angles.z)
	up = PlayerPortrait._d3d_rot_x(up, _angles.x)
	up = PlayerPortrait._d3d_rot_y(up, _angles.y)
	_camera.transform = Transform3D(Basis.looking_at(at - eye, PlayerPortrait.to_godot(up)), eye)

# --- The mouse (CIFRenderStatic vslot_017 0x560720, vslot_036 0x55ee20) ----------------

## The window's TextureRect forwards its gui_input here with its size (UI
## units; positions are the rect's local ones -- the drags and the wheel use
## ratios of the rect, so the UI scale does not enter). Returns true when the
## control took the event.
##
## Routing (OURS, the CGWnd rule): while this control holds the capture every
## mouse message is its; otherwise only one over its rect. A second press
## within the double-click time is WM_xBUTTONDBLCLK (0x203 / 0x206), which
## the handler ignores: the game window's class has CS_DBLCLKS (READ, style
## 0xb at 0x831310; INFERRED to be the game window's class).
func handle_input(event: InputEvent, rect_size: Vector2) -> bool:
	if not _mouse_on or provider == null:
		return false
	var mb := event as InputEventMouseButton
	if mb != null:
		var inside := Rect2(Vector2.ZERO, rect_size).has_point(mb.position)
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not mb.pressed or not (inside or _captured):
				return false
			# Wheel away from the user: a positive delta.
			wheel(1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1, mb.position, rect_size)
			return true
		if not (inside or _captured):
			return false
		if mb.double_click and mb.pressed:
			return true
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					left_down(mb.position)
				else:
					left_up(mb.position, rect_size)
				return true
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					right_down(mb.position)
				else:
					right_up()
				return true
		return false
	var mm := event as InputEventMouseMotion
	if mm != null:
		move(mm.position, rect_size)
		return _captured
	return false

## WM_LBUTTONDOWN (case 1): a left drag starts unless a right drag holds the
## capture, in which case the capture is released and nothing else happens
## (0x560767; the flags stay).
func left_down(at: Vector2) -> void:
	if not _captured or not _right_drag:
		_left_drag = true
		_start_shared = _angle
		_press = at
		_captured = true
		return
	_release_capture()

## WM_LBUTTONUP (case 2): the capture released if a left drag held it; then
## ALWAYS the angle from the release x and +0x3cc, wrapped, the drag off and
## the angle stored in +0x394. The models are not touched.
func left_up(at: Vector2, rect_size: Vector2) -> void:
	if _captured and _left_drag:
		_release_capture()
	var a := _drag_angle(at.x, rect_size.x)
	_left_drag = false
	_angle = a

## WM_RBUTTONDOWN (case 4): a right drag starts unless a left drag holds the
## capture (then only the capture is released). The start point is the
## look-at's x and y, in +0x3c8 / +0x3cc.
func right_down(at: Vector2) -> void:
	if not _captured or not _left_drag:
		_right_drag = true
		_start_x = _target.x
		_start_shared = _target.y
		_press = at
		_captured = true
		return
	_release_capture()

## WM_RBUTTONUP (case 5): the capture released if a right drag held it; the
## drag off.
func right_up() -> void:
	if _captured and _right_drag:
		_release_capture()
	_right_drag = false

## WM_MOUSEMOVE (case 0): nothing unless this control holds the capture.
## A left drag turns every model to start + 2pi dx / width (wrapped); then,
## independently, a right drag pans the look-at: x = x0 - dx dist 2 / width,
## y = y0 + dy dist 2 / height, clamped to the box.
func move(at: Vector2, rect_size: Vector2) -> void:
	if not _captured:
		return
	if _left_drag:
		var a := _drag_angle(at.x, rect_size.x)
		for m in _models:
			var mm := m as Model
			mm.yaw = a
			mm.matrix_set = true
			_apply_matrix(mm)
	if not _right_drag:
		return
	var dx := at.x - _press.x
	var dy := at.y - _press.y
	_target.x = _start_x - (dx * _dist * PAN_FACTOR) / rect_size.x
	_target.y = (dy * _dist * PAN_FACTOR) / rect_size.y + _start_shared
	_clamp_target()
	_update_camera()

## start + (dx / width) x pi x 2, wrapped by 0x55e780.
func _drag_angle(x: float, width: float) -> float:
	var f := ((x - _press.x) / width) * PI_F
	return wrap_angle(f + f + _start_shared)

## 0x55e780: k = trunc(angle / 2pi); the angle loses k x 2pi only when k > 1.
## So [2pi, 4pi) and every negative angle stay as they are.
static func wrap_angle(a: float) -> float:
	var k := int(a / TWO_PI)
	if float(k) > 1.0:
		return a - float(k) * TWO_PI
	return a

## WM_MOUSEWHEEL (vslot_036 0x55ee20): +2 for a delta > 0 (zoom OUT), else
## -2, the distance clamped (0x55e6a0), and the look-at slid by the same ratio
## toward the pointer's ray so the point under the pointer stays: r = d / dist
## (nothing when r = 0); vx = (2 px / w - 1) / proj._11, vy = -(2 py / h - 1) /
## proj._22; w = (vx, vy, 1) x the inverse view (rows 0..2); target.x -= r dist
## (w.x - fwd.x), target.y -= r dist (w.y - fwd.y), z unchanged; dist += r
## dist; then the pan clamp. fwd = at - eye (+0x40c). With the mall's camera
## (the angles never change) w = (vx, vy, 1) and fwd = (0, 0, dist).
func wheel(delta: int, at: Vector2, rect_size: Vector2) -> void:
	var step := ZOOM_STEP if delta > 0 else -ZOOM_STEP
	var d := _zoom_change(_dist, step)
	var r := d / _dist
	if r == 0.0:
		return
	var aspect := rect_size.x / rect_size.y
	var cot := 1.0 / tan(deg_to_rad(FOV_DEG) * 0.5)
	var p11 := cot / aspect
	var p22 := cot
	var vx := ((at.x * PAN_FACTOR) / rect_size.x - 1.0) / p11
	var vy := -(((PAN_FACTOR * at.y) / rect_size.y - 1.0) / p22)
	var inv := _view_inverse_rows()
	var wx: float = vx * inv[0].x + vy * inv[1].x + inv[2].x
	var wy: float = vx * inv[0].y + vy * inv[1].y + inv[2].y
	var fwd := _target - eye_d3d()
	_target.x -= r * (wx - fwd.x) * _dist
	_target.y -= r * (wy - fwd.y) * _dist
	_dist = r * _dist + _dist
	_clamp_target()
	_update_camera()

## The view matrix's inverse, rows 0..2 (D3D row vectors): the camera's
## right, up and forward axes, RotZ x RotX x RotY of the angles.
func _view_inverse_rows() -> Array:
	var rows := []
	for v in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]:
		var w: Vector3 = v
		w = PlayerPortrait._d3d_rot_z(w, _angles.z)
		w = PlayerPortrait._d3d_rot_x(w, _angles.x)
		w = PlayerPortrait._d3d_rot_y(w, _angles.y)
		rows.append(w)
	return rows

## 0x55e6a0: the change that keeps dist + step in [s + near, s + 40], s the
## larger of the box's x and z spans; the upper bound wins.
func _zoom_change(dist: float, step: float) -> float:
	var s := absf(_box_max.x - _box_min.x)
	var sz := absf(_box_max.z - _box_min.z)
	if s < sz:
		s = sz
	var lo := s + NEAR
	var want := dist + step
	var v := lo if want < lo else want
	var hi := ZOOM_RANGE + s
	if hi <= v:
		return hi - dist
	if lo <= want:
		return want - dist
	return lo - dist

## 0x55e5b0: x into [min.x, max.x] and y into [min.y, max.y], the max
## winning; z untouched.
func _clamp_target() -> void:
	var v := _target.x if _box_min.x <= _target.x else _box_min.x
	if _box_max.x <= v:
		_target.x = _box_max.x
	else:
		_target.x = _target.x if _box_min.x <= _target.x else _box_min.x
	var y := _target.y if _box_min.y <= _target.y else _box_min.y
	if y < _box_max.y:
		_target.y = _box_min.y if _target.y < _box_min.y else _target.y
	else:
		_target.y = _box_max.y

func _release_capture() -> void:
	_captured = false

## The drag state, for the tests: {captured, left, right, angle, start}.
func drag_state() -> Dictionary:
	return {"captured": _captured, "left": _left_drag, "right": _right_drag,
		"angle": _angle, "start": _start_shared, "start_x": _start_x, "press": _press}

# --- The tick ------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active:
		return
	_zone_check += delta
	if _zone_check >= 1.0:
		_zone_check = 0.0
		_pull_zone_light()
	step(delta)

## Advances every model's clip (vslot_012's 0xa5ac80 per model).
func step(delta: float) -> void:
	for m in _models:
		var mm := m as Model
		mm.t += delta
		_pose(mm)
