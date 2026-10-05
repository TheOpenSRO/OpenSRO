extends RefCounted
class_name AmbientParticles

## A placed object's always-on particle effects (round 720): the teleport
## gates' glows and their kind. docs/protocol/teleport_effects.md has the
## census and every address.
##
## What is READ (sro_client.exe):
## - Which effects: a `.bsr`'s mod section carries particle mods
##   (ModDataParticle::vslot_004, 0x00c643b0; BsrReader.ParticleMod). A mod
##   set named `ambient` is the object's always-on set: ModPalette::
##   FUN_00c0b060 gives the set whose name compares equal to "ambient" (7
##   characters, FUN_004722d0) set kind 2, the kind every draw applies
##   (round 625). Every town gate's set is `ambient`.
## - Where: an entry of mode != 0 is placed at its offset in the object's
##   frame (CRTModParticle::FUN_00c81820; FUN_00c81190 builds the world
##   matrix as translate(scale x offset) x the object's world matrix, the
##   scale being the object's own, 1 for a placed map object); mode 0 at the
##   named bone (FUN_00c818c0 -> FUN_00c2c820, the bone by name). An entry
##   whose byte +0x53 is set also turns by the rotation FUN_00c67500 builds
##   from its three angles (rotation_basis), applied in the object's frame
##   before its own (FUN_00c81190's second product).
## - The glow: an entry whose byte +0x50 is not 0 is drawn by the glow pass
##   (FUN_00c43100, through CRTModParticle::FUN_00c81450 when the effect's
##   +0x90 is set and the manager's +0x1a4 / +0x1ac are 1 -- the constructor
##   sets +0x1a4 to 1 and nothing changes it; +0x1ac is 1 when the device
##   creates an occlusion query, FUN_00c807f0's CreateQuery(9)):
##     * every 500 ms (the pass's accumulator +0xa4 against 0x1f5, then
##       `% 500`) a depth-tested point is drawn inside an occlusion query
##       (CVisibleChecker::vslot_002: ZENABLE on, colour writes off, FVF
##       XYZ|DIFFUSE, one point) at the effect's position moved toward the
##       camera by (byte - 1.0) units (the double 1.0 at 0x00e1b7f0); the
##       effect is visible when the point passes;
##     * each frame its alpha (+0x4c, a byte) moves toward 255 when visible
##       and toward 0 when not by trunc(frame ms x 1.5) (CRTModParticle::
##       FUN_00c81080, the double 1.5 at 0x00e1b7e8); an effect the pass did
##       not see the frame before restarts at 0;
##     * the effects are drawn with ZENABLE off, and only while their alpha
##       is not 0 (FUN_00c81130);
##     * the alpha reaches the draw as CEFEffect +0x4a (vslot_009), which
##       scales each particle colour's alpha byte, (a x alpha) >> 8, when it
##       is not 255 (EFEffect::FUN_00c893f0, 0x00c8affd).
##
## OURS:
## - The occlusion query is a physics ray from the camera to the moved point
##   (OCCLUDER_MASK: terrain, placed objects and the characters' pick
##   bodies, not the NPCs), passing through alpha-tested pieces (occluder).
## - Which objects play them: the placed objects that stand at a teleport
##   structure (World3D._attach_gate_effects). The original plays every
##   placed object's ambient set (1,300 sets across 8,539 `.bsr`, MEASURED);
##   the rest of the world is not done here.
## - An ambient effect is kept (looping) for as long as its object stands.

## The meta a committed object carries its ambient entries under
## (ObjectLoader._commit_node).
const META_ENTRIES := "ambient_particles"
## The query period, ms (0x1f5 = 501: a query when more than 500 ms have
## gathered, the remainder kept).
const QUERY_MS := 500
## Alpha per millisecond (the double at 0x00e1b7e8).
const FADE_PER_MS := 1.5
## The bias's own offset (the double at 0x00e1b7f0).
const BIAS_OFFSET := 1.0
## What the occlusion ray meets (OURS, the closest set to what the
## original's depth buffer holds): layer 1, the terrain and the placed
## objects; and the characters' pick bodies -- monsters (layer 6), other
## players (8) and the player (9), World3D's MONSTER_ / OTHER_PLAYER_ /
## SELF_CLICK_COLLISION_LAYER. Not the NPCs: their layer is the navmesh
## walls' (5), which draw nothing.
const OCCLUDER_MASK := 0b1 | 0b100000 | 0b10000000 | 0b100000000

## The entries of `mods`' `ambient` sets, in file order.
static func ambient_entries(mods: Array) -> Array:
	var out: Array = []
	for pm in mods:
		var m := pm as BsrReader.ParticleMod
		if m == null or m.set_kind != BsrReader.SET_BY_CLIP:
			continue
		if not m.set_name.to_lower().begins_with("ambient"):
			continue
		for e in m.entries:
			out.append(e)
	return out

## FUN_00c67500's rotation from an entry's three angles (x, y, z radians),
## as a Godot basis in the object's frame. READ: the D3D row-vector matrix
##   m00 = cy cz            m01 = -sz cy            m02 = -sy
##   m10 = sz cx - sx sy cz m11 = cz cx + sx sy sz  m12 = -sx cy
##   m20 = sz sx + cx sy cz m21 = cz sx - cx sy sz  m22 = cx cy
## (cos 0xb44a10, sin 0xb44b40 of +0x54, +0x58, +0x5c). A row vector is
## placed as v x M, so Godot's column form is M's rows as the columns -- the
## same correspondence NavGraph.godot_yaw holds for an object's yaw (its
## matrix is this one's transpose, hence the sign there).
static func rotation_basis(angles: Vector3) -> Basis:
	var cx := cos(angles.x)
	var sx := sin(angles.x)
	var cy := cos(angles.y)
	var sy := sin(angles.y)
	var cz := cos(angles.z)
	var sz := sin(angles.z)
	var r0 := Vector3(cy * cz, -sz * cy, -sy)
	var r1 := Vector3(sz * cx - sx * sy * cz, cz * cx + sx * sy * sz, -sx * cy)
	var r2 := Vector3(sz * sx + cx * sy * cz, cz * sx - cx * sy * sz, cx * cy)
	return Basis(r0, r1, r2)

## The alpha after one frame (CRTModParticle::FUN_00c81080): `seen_last`
## false restarts it at 0 when not visible; a fade step is trunc(ms x 1.5).
static func step_alpha(alpha: int, visible: bool, frame_ms: float, seen_last: bool) -> int:
	var d := int(frame_ms * FADE_PER_MS)
	if visible:
		return mini(alpha + d, 255)
	if not seen_last:
		return 0
	var v := alpha - d
	return v if v >= 1 else 0

## The point the occlusion test draws: the effect's position moved toward
## the camera by (byte - 1.0).
static func query_point(at: Vector3, camera: Vector3, byte: int) -> Vector3:
	var to_cam := camera - at
	if to_cam.length_squared() < 1e-12:
		return at
	return at + to_cam.normalized() * (float(byte) - BIAS_OFFSET)

class Glow:
	var fx: EfpEffect
	var byte: int = 0
	var alpha: int = 0
	var visible := false
	var seen_frame := -1
	## What the last query's ray met first (the QA log), "" when visible.
	var blocker := ""

var _glows: Array[Glow] = []
var _gathered_ms := 0.0
var _frame := 0

## Builds and attaches `host`'s entries' effects. Returns them.
func attach(host: Node3D, entries: Array, particles: Pk2Reader) -> Array:
	var made: Array = []
	for e_v in entries:
		var e := e_v as BsrReader.ParticleEntry
		if e == null or e.efp == "":
			continue
		var fx := EfpEffect.create(e.efp, particles)
		if fx == null:
			print("AMBIENT %s: %s did not build (%s)" % [host.name, e.efp, EfpEffect.last_error])
			continue
		fx.loop = true
		fx.auto_free = false
		if e.rotated:
			fx.follow_basis = rotation_basis(e.angles)
		if e.mode == 0:
			SkillEffects.attach(fx, host, e.bone, Vector3.ZERO)
		else:
			SkillEffects.attach(fx, host, "none", e.offset)
		if e.b50 != 0:
			fx.make_glow()
			var g := Glow.new()
			g.fx = fx
			g.byte = e.b50
			_glows.append(g)
		made.append(fx)
	return made

## The glow pass, once a frame.
func update(frame_ms: float, camera: Camera3D, space: PhysicsDirectSpaceState3D) -> void:
	_frame += 1
	var alive: Array[Glow] = []
	for g in _glows:
		if is_instance_valid(g.fx) and g.fx.is_inside_tree():
			alive.append(g)
	_glows = alive
	if _glows.is_empty():
		_gathered_ms = 0.0
		return
	_gathered_ms += frame_ms
	if _gathered_ms > QUERY_MS and camera != null and space != null:
		_gathered_ms = fmod(_gathered_ms, QUERY_MS)
		var eye := camera.global_position
		for g in _glows:
			var p := query_point(g.fx.placed_at(), eye, g.byte)
			var hit := occluder(space, eye, p)
			g.visible = hit.is_empty()
			g.blocker = "" if g.visible else _blocker_name(hit)
	for g in _glows:
		g.alpha = step_alpha(g.alpha, g.visible, frame_ms, g.seen_frame == _frame - 1)
		g.seen_frame = _frame
		g.fx.set_glow_alpha(g.alpha)

## The first static-world surface between `from` and `to` that hides a
## point, or {} when none does. An alpha-tested piece (an object material
## with an alpha test: leaves, fences) is passed through: the original's
## depth buffer has holes where its texels fail the test, which a collision
## trimesh does not (OURS, the closest the ray comes to the depth test --
## its opaque texels then do not hide a glow either). Round 720 found
## Jangan's glow hidden from 150 units by a bare tree's leaf cards.
static func occluder(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var exclude: Array[RID] = []
	for _i in range(MAX_PASS_THROUGH + 1):
		var q := PhysicsRayQueryParameters3D.create(from, to, OCCLUDER_MASK, exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or not _alpha_tested(hit.get("collider")):
			return hit
		exclude.append(hit["rid"])
	return {}

## How many alpha-tested pieces one ray passes through before giving up
## (OURS; a glow behind more foliage than this is taken as visible).
const MAX_PASS_THROUGH := 8

## Whether a collider is a piece drawn with an alpha test: ObjectLoader puts a
## piece's StaticBody3D under its MeshInstance3D, and an alpha-tested
## material carries `alpha_scissor` above 0 (_build_foliage_material,
## _build_mod_material).
static func _alpha_tested(collider) -> bool:
	if not (collider is Node):
		return false
	var mi := (collider as Node).get_parent() as MeshInstance3D
	if mi == null:
		return false
	var m := mi.material_override as ShaderMaterial
	if m == null:
		return false
	var ref = m.get_shader_parameter("alpha_scissor")
	return ref != null and float(ref) > 0.0

static func _blocker_name(hit: Dictionary) -> String:
	var c = hit.get("collider")
	if c is Node:
		var n := c as Node
		var owner_name := String(n.get_parent().name) if n.get_parent() != null else ""
		var top := n
		while top.get_parent() != null and not String(top.name).begins_with("Obj_") and not String(top.name).begins_with("RealTerrain"):
			top = top.get_parent()
		return "%s/%s at %s" % [String(top.name), owner_name, str((hit["position"] as Vector3).round())]
	return "?"

func glow_count() -> int:
	return _glows.size()

## For the QA log: each glow's alpha and visibility.
func describe() -> String:
	var parts: Array[String] = []
	for g in _glows:
		if is_instance_valid(g.fx):
			parts.append("%s a%d %s" % [g.fx.path.get_file(), g.alpha, "vis" if g.visible else "hid by " + g.blocker])
	return ", ".join(parts)
