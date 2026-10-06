extends Node3D
class_name CharacterBlobs

## The round shadow under characters -- Shadow Detail "Circle" (round 702).
##
## **What the original does (READ, sro_client.exe).** `SWorld::vslot_024`
## (0xa182f0) draws the world's character shadows by the Shadow Detail value
## it keeps at SWorld+0x2e58 (`param_1[0xb96]`; vslot_043 case 2 stores it):
## - 1 (Circle): it walks the world's object list in order and, for each
##   object that IsKindOf CICharactor (runtime class 0xef1a5c, returned by
##   CICharactor::vslot_000 -- players, monsters and NPCs alike) and whose
##   vslot 0x50 answers non-zero, draws `skybox\shadowsphere.ddj` (loaded by
##   Map::FUN_00a0d1b0 into world+0x2a3f) through SWorld::vslot_022 with size
##   `FUN_009c75c0() + 5` -- the character's reference record +0x118, its
##   BCRadius (characterdata column 50; docs/protocol/teleport_network.md:
##   read at 0x972ce2) -- and colour 0xa8000000. It stops after ten
##   characters (`if (9 < count) break`).
## - 2 (Detail): no circle at all. It draws the per-character projected
##   shadows instead (Map::FUN_009f35f0 for each of the DAT_0110192c slots
##   SWorld::vslot_025 rendered: up to ten characters, each drawn into a 96 x
##   96 target and kept as a 32 x 32 texture, the list walked while its key is
##   at most 3000).
## - 0 (Nothing): neither.
## SWorld::vslot_022 projects the texture onto the ground under the position
## (it re-draws the ground cells there, Map::FUN_009f3c10) through an
## orthographic projection of width and height `size` (D3DXMatrixOrthoLH at
## 0x9f4462: the size is the circle's diameter), with stage 0
## MODULATE(TEXTURE, TFACTOR) and SRCALPHA / INVSRCALPHA blending; the
## TFACTOR (0x9f44cd) is the colour argument -- so the circle is black at
## 0xa8 / 255 = 0.659 of the texture's alpha (READ, round 702 review).
## The list is the world's object map keyed by `(int)(|object - player| x
## 10)` (CICPlayer::vslot_005 0x9d6f19..0x9d6fad), so the ten are the ten
## nearest the LOCAL PLAYER; Circle has no distance limit (Detail's walk
## stops at key 3000, 300 units).
##
## **Here.** A pool of MAX_BLOBS flat quads (OURS: laid at the character's
## feet, not draped over the ground cells -- so a character on a placed floor,
## the Jangan plaza deck, keeps its circle on the deck, where the original's
## would lie on the terrain under the deck and be hidden; consistent with the
## user's ring-on-floors decision of 2026-10-03), shown only in Circle, under
## the ten characters nearest the player (READ). Size BCRadius + 5, the
## diameter (READ; 9 for the default body, BCRadius 4).

## READ: vslot_024 draws at most ten.
const MAX_BLOBS := 10
## READ: the colour argument 0xa8000000 (alpha 0xa8), the TFACTOR the draw
## modulates the texture's alpha by (0x9f44cd).
const ALPHA := 168.0 / 255.0
## READ: the size (the diameter) is the character's BCRadius plus 5.
const SIZE_ADD := 5.0
## OURS: a character whose BCRadius is not known is drawn as the default
## body's (characterdata column 50 of CHAR_CH_MAN_FIGHTER is 4, MEASURED).
const DEFAULT_RADIUS := 4.0
## OURS: above the ground, so the quad does not fight it.
const LIFT := 0.15
## OURS: the nearest are chosen again every this many frames (positions are
## followed every frame).
const RESELECT_FRAMES := 6

## Nodes that cast a circle join this group (register); META_RADIUS is their
## BCRadius in world units.
const GROUP := &"srr_blob_caster"
const META_RADIUS := &"srr_blob_radius"

## **Detail's casters (round 739, crowd_scale.md B2).** READ (round 739's
## review, F4): SWorld::vslot_025 (0xa17ab0) walks the map at 0xec24c0, which
## CICPlayer::vslot_005 fills from the global GID-object list (0xec4ae4) keyed
## round(|object - player| x 10.0) (the double at 0xe1b840), and stops at the
## tenth drawn object or past key 3000 -- 300 units. The local player is in
## that list (CIGIDObject's constructor FUN_009c2340 -> FUN_009c1e30 links
## it), at key 0, so it is one of the ten. Unlike Circle's vslot_024, the walk
## has NO IsKindOf-CICharactor test: any GID object whose vslot 0x50 answers
## (+0xbc != 0) and that has a model (+0x9c) takes a slot -- COS, structures,
## particle objects. Here the set is this group's, characters only: OURS
## (OpenSRO draws no COS or structures yet). Detail itself is the sun's shadow
## map (OURS stand-in, round 702), into which every character's meshes used to
## cast (r736 MEASURED: about 10 ms a frame at 1000 players); now only the ten
## nearest within 300 cast, the others' meshes have their cast_shadow turned
## off, and given back when they are chosen. READ: ten, 300, the player one
## of them.
const DETAIL_MAX := 10
const DETAIL_RANGE := 300.0
## OURS: the casters a pass sets up for the first time (a caster that arrived
## since, or all of them when Detail is turned on), at most this many a pass,
## so turning Detail on beside a crowd is not one long frame; only those within
## ADOPT_RANGE of the player, as farther ones are beyond the shadow map's
## reach (World3D.SHADOW_MAP_DISTANCE, 400 from the camera, which is at most
## 90 from the player) and cast nothing into it.
const DETAIL_ADOPT_PER_PASS := 64
const DETAIL_ADOPT_RANGE := 500.0
## Whether a caster's meshes cast now (true / false; missing: not set up).
const META_DETAIL := &"srr_detail_cast"
## The meshes a caster had casting that were turned off, to give back.
const META_DETAIL_OFF := &"srr_detail_off"

var _blobs: Array[MeshInstance3D] = []
var _chosen: Array = []
var _frame := 0
var _texture: Texture2D = null
var _detail_chosen: Dictionary = {}   # instance id -> Node3D
var _detail_frame := 0
## Casters whose shadow was switched in the last pass (for the tests and the probe).
var detail_switched := 0

## The Shadow Detail values that draw the circle: Circle only (READ, above).
static func blobs_visible(shadow_detail: int) -> bool:
	return shadow_detail == 1

## The circle's size (diameter) for a BCRadius (READ).
static func blob_size(bc_radius: float) -> float:
	return (bc_radius if bc_radius > 0.0 else DEFAULT_RADIUS) + SIZE_ADD

## Marks `node` (its origin at the character's feet) as casting a circle.
static func register(node: Node, bc_radius: float) -> void:
	if node == null:
		return
	node.set_meta(META_RADIUS, bc_radius)
	if not node.is_in_group(GROUP):
		node.add_to_group(GROUP)

## Builds the pool from the original's texture.
func setup(texture: Texture2D) -> void:
	_texture = texture
	if not _blobs.is_empty():
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	# The texture's RGB is black and its alpha the round gradient (MEASURED,
	# the blob's round of 2026-09-07); the colour's alpha is the TFACTOR.
	mat.albedo_color = Color(1.0, 1.0, 1.0, ALPHA)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	for i in MAX_BLOBS:
		var mi := MeshInstance3D.new()
		mi.name = "CharacterShadow%d" % i
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_blobs.append(mi)

func is_ready() -> bool:
	return not _blobs.is_empty()

## The circles shown now, for the QA probe and the tests.
func shown_count() -> int:
	var n := 0
	for b in _blobs:
		if b.visible:
			n += 1
	return n

func blob(i: int) -> MeshInstance3D:
	return _blobs[i] if i >= 0 and i < _blobs.size() else null

## The nearest `limit` of `nodes` to `from` (visible ones only; none past
## `max_distance` when it is above 0). Plain data in, for the tests.
static func nearest(nodes: Array, from: Vector3, limit: int, max_distance: float = 0.0) -> Array:
	var best: Array = []
	var best_d: Array = []
	var max_d2 := max_distance * max_distance
	for n in nodes:
		if not (n is Node3D) or not is_instance_valid(n) or not (n as Node3D).is_visible_in_tree():
			continue
		var d2 := (n as Node3D).global_position.distance_squared_to(from)
		if max_distance > 0.0 and d2 > max_d2:
			continue
		if best.size() >= limit and d2 >= float(best_d[-1]):
			continue
		var at := best_d.bsearch(d2)
		best_d.insert(at, d2)
		best.insert(at, n)
		if best.size() > limit:
			best.pop_back()
			best_d.pop_back()
	return best

## Places the circles for this frame. `from` is the local player's
## position (READ: the original's list is by distance from the player);
## `shadow_detail` is the Video tab's
## row; `ground_y` maps a caster to the height its circle lies at (NAN: none
## found, no circle); `max_distance` is the Character Sight Range (0: any).
func update(from: Vector3, shadow_detail: int, ground_y: Callable, max_distance: float = 0.0) -> void:
	if shadow_detail >= 2:
		update_detail(from, max_distance)
	if _blobs.is_empty():
		return
	if not blobs_visible(shadow_detail):
		for b in _blobs:
			b.visible = false
		_chosen.clear()
		return
	if _frame % RESELECT_FRAMES == 0 or _chosen.is_empty():
		_chosen = nearest(get_tree().get_nodes_in_group(GROUP), from, MAX_BLOBS, max_distance)
	_frame += 1
	for i in _blobs.size():
		var b := _blobs[i]
		if i >= _chosen.size() or not is_instance_valid(_chosen[i]) or not (_chosen[i] as Node3D).is_visible_in_tree():
			b.visible = false
			continue
		var n := _chosen[i] as Node3D
		var y: float = ground_y.call(n)
		if is_nan(y):
			b.visible = false
			continue
		var size := blob_size(float(n.get_meta(META_RADIUS, 0.0)))
		b.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0).scaled(Vector3(size, size, size)),
			Vector3(n.global_position.x, y + LIFT, n.global_position.z))
		b.visible = true

## Detail's casters for this frame (round 739, B2): every RESELECT_FRAMES the
## DETAIL_MAX nearest `from` within DETAIL_RANGE (and the Character Sight
## Range, when it is nearer) cast into the shadow map, and no other caster
## does. Only the casters that change are touched, and new ones are set up
## DETAIL_ADOPT_PER_PASS a pass.
func update_detail(from: Vector3, max_distance: float = 0.0) -> void:
	var due := _detail_frame % RESELECT_FRAMES == 0
	_detail_frame += 1
	if not due:
		return
	var reach := DETAIL_RANGE if max_distance <= 0.0 else minf(DETAIL_RANGE, max_distance)
	var casters: Array = get_tree().get_nodes_in_group(GROUP) if is_inside_tree() else []
	select_detail(casters, from, reach)

## The pass itself, on plain data (the tests call it).
func select_detail(casters: Array, from: Vector3, reach: float) -> void:
	var chosen := {}
	for n in nearest(casters, from, DETAIL_MAX, reach):
		chosen[(n as Node).get_instance_id()] = n
	detail_switched = 0
	for id in _detail_chosen:
		if not chosen.has(id):
			var gone = _detail_chosen[id]
			if is_instance_valid(gone):
				set_casting(gone, false)
				detail_switched += 1
	for id in chosen:
		var n: Node3D = chosen[id]
		if n.get_meta(META_DETAIL, false) != true:
			set_casting(n, true)
			detail_switched += 1
	_detail_chosen = chosen
	var adopted := 0
	var adopt_d2 := DETAIL_ADOPT_RANGE * DETAIL_ADOPT_RANGE
	for n in casters:
		if adopted >= DETAIL_ADOPT_PER_PASS:
			break
		if not (n is Node3D) or not is_instance_valid(n) or (n as Node).has_meta(META_DETAIL):
			continue
		if (n as Node3D).global_position.distance_squared_to(from) > adopt_d2:
			continue
		set_casting(n, chosen.has((n as Node).get_instance_id()))
		adopted += 1

## The casters Detail lets cast now (for the tests and the probe).
func detail_chosen() -> Array:
	return _detail_chosen.values()

## Turns `node`'s meshes' shadow off (keeping which were casting) or gives
## them back. Labels, and meshes set not to cast by whoever built them, are
## left alone.
## Round 747: called with a node about to cast (World3D: a far body comes
## back to its posed meshes first, CrowdGpu). Unset in tests.
static var on_cast: Callable = Callable()

static func set_casting(node: Node, on: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	var off: Array = node.get_meta(META_DETAIL_OFF, [])
	if on and on_cast.is_valid():
		on_cast.call(node)
	if on:
		for gi in off:
			if is_instance_valid(gi):
				(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if node.has_meta(META_DETAIL_OFF):
			node.remove_meta(META_DETAIL_OFF)
	else:
		var kept: Array = []
		for gi in off:
			if is_instance_valid(gi):
				kept.append(gi)
		for gi in node.find_children("*", "GeometryInstance3D", true, false):
			if gi is Label3D:
				continue
			if (gi as GeometryInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
				(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				kept.append(gi)
		node.set_meta(META_DETAIL_OFF, kept)
	node.set_meta(META_DETAIL, on)

## A caster whose meshes were rebuilt (a redress) or given back by someone
## else: its state applied again to the meshes it has now -- a caster that
## casts keeps its new meshes casting, one that does not has them switched off.
static func refresh_detail(node: Node) -> void:
	if node != null and is_instance_valid(node) and node.has_meta(META_DETAIL):
		set_casting(node, bool(node.get_meta(META_DETAIL)))
