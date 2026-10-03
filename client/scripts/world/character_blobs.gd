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
## (it re-draws the ground cells there, Map::FUN_009f3c10) with stage 0
## MODULATE(TEXTURE, TFACTOR) and SRCALPHA / INVSRCALPHA blending; the
## TFACTOR it sets (0x9f44d4) is a stack argument, INFERRED to be the colour
## argument -- so the circle is black at 0xa8 / 255 = 0.659 of the texture's
## alpha.
##
## **Here.** A pool of MAX_BLOBS flat quads (OURS: laid at the character's
## feet, not draped over the ground cells), shown only in Circle, under the
## nearest characters to the camera (INFERRED: the original's list order was
## not read; nearest first keeps the player's own). Size BCRadius + 5, taken
## as the circle's diameter (INFERRED: the texture matrix was not read; for
## the default body, BCRadius 4, it is the 9 units this client drew before).

## READ: vslot_024 draws at most ten.
const MAX_BLOBS := 10
## READ: the colour argument 0xa8000000 (alpha 0xa8); INFERRED to be the
## TFACTOR the draw modulates the texture's alpha by.
const ALPHA := 168.0 / 255.0
## READ: the size is the character's BCRadius plus 5.
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

var _blobs: Array[MeshInstance3D] = []
var _chosen: Array = []
var _frame := 0
var _texture: Texture2D = null

## The Shadow Detail values that draw the circle: Circle only (READ, above).
static func blobs_visible(shadow_detail: int) -> bool:
	return shadow_detail == 1

## The circle's size for a BCRadius (READ: + 5; INFERRED: the diameter).
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

## Places the circles for this frame. `shadow_detail` is the Video tab's
## row; `ground_y` maps a caster to the height its circle lies at (NAN: none
## found, no circle); `max_distance` is the Character Sight Range (0: any).
func update(from: Vector3, shadow_detail: int, ground_y: Callable, max_distance: float = 0.0) -> void:
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
