extends RefCounted
class_name AmbientParticles

## A placed object's always-on particle effects (round 720): the teleport
## gates' glows and their kind. docs/protocol/teleport_effects.md has the
## census and every address.
##
## What is READ (sro_client.exe):
## - Which effects: a `.bsr`'s mod section carries particle mods
##   (ModDataParticle::vslot_004, 0x00c643b0; BsrReader.ParticleMod). A mod
##   set named exactly `ambient` (case-sensitive: FUN_004722d0 is
##   compare(0, size(), "ambient", 7), 0x4722d0..0x47233b) gets set kind 2
##   from ModPalette::FUN_00c0b060 (0xc0b0ca..0xc0b0e1), and kind 2 routes
##   the runtime set into the palette's own slot (FxModManager::FUN_00c7fa40
##   at 0xc7fcea: `cmp [edi+0x18],2` -> `mov [ecx+0x5c],esi`, returned by
##   0xc7c060 and collected by CCompChar::FUN_00c46ab0 at 0xc46b26) -- the
##   set the object plays with no clip running. Every town gate's set is
##   `ambient`. Two gates sit in front of the draw: every CRTModParticle slot
##   first runs 0xc43780, which passes only when the mod's +0x3c (0.9, the
##   float at 0xde3148, stored by the constructor 0xc77a00) is at least the
##   host's LOD +0x7c (clamped 0..1 by 0xc25620, from the game-object LOD
##   change only, GlobalDataManager::FUN_009c4aa0) -- INFERRED open for a
##   placed building, which keeps its default LOD; and the effect draws only
##   while its +0xb0 or +0xb4 is set (0xc81472; +0xb4 is vslot_001's fifth
##   argument, whose value on the ambient path was not traced -- OPEN).
## - Where: an entry of mode != 0 is placed at its offset in the object's
##   frame (CRTModParticle::FUN_00c81820; FUN_00c81190 builds the world
##   matrix as translate(scale x offset) x the object's world matrix, the
##   scale being the object's own, 1 for a placed map object); mode 0 at the
##   named bone (FUN_00c818c0 -> FUN_00c2c820, the bone by name). An entry
##   whose byte +0x53 is set also turns by the rotation FUN_00c67500 builds
##   from its three angles (rotation_basis), applied in the object's frame
##   before its own (FUN_00c81190's second product).
## - Mode 0 (CRTModParticle::FUN_00c818c0): the host's +0xf4 (a skeleton)
##   and the bone by name; when either is missing the call returns 0 and
##   vslot_001 frees that effect and returns at once (0xc77b9f..0xc77bc4):
##   no later entry of the same mod is built. The bone's full matrix places
##   it (0xc811c5..0xc811e0).
## - Byte +0x51 bit 0: the effect is drawn only while the manager's +0x1a8
##   is set (FUN_00c81450, FUN_00c43100), which SWorld::vslot_004 writes
##   through the thunk 0xbbdbf0 at 0xa2d1c6: 1 when the shifted day phase
##   +0x26a7 is above 0.5 (game_clock.md's night flag). This client keeps
##   the binary's fixed phase 0.5 (shifted 0.25), so such an entry never
##   draws: it is not built (`night`, `shows`).
## - The glow: an entry whose byte +0x50 is not 0 is drawn by the glow pass
##   (FUN_00c43100, through CRTModParticle::FUN_00c81450 when the effect's
##   +0x90 is set and the manager's +0x1a4 / +0x1ac are 1). +0x1a4 is the
##   **Light Effect** video option: its setter 0xbc1230 is reached through
##   the thunk 0xbbdad0 from SWorld::vslot_043 case 0xb (round 720's review;
##   OPTION_VIDEO.md); with it off, FUN_00c81450 draws the effect with the
##   scene, depth-tested at full alpha (0xc814fe), and nothing reaches the
##   glow list (set_light_effect). +0x1ac is 1 when the device creates an
##   occlusion query (FUN_00c807f0's CreateQuery(9)). The pass takes only the
##   effects whose object is drawn this frame (FUN_00c81450 queues them as
##   it draws them; the list is cleared every frame):
##     * every 500 ms (the pass's accumulator +0xa4 against 0x1f5, then
##       `% 500`) a depth-tested point is drawn inside an occlusion query
##       (CVisibleChecker::vslot_002: ZENABLE on, colour writes off, FVF
##       XYZ|DIFFUSE, one point) at the effect's position moved toward the
##       camera by (byte - 1.0) units (the double 1.0 at 0x00e1b7f0); the
##       effect is visible when the point passes -- so a point behind the
##       eye or off the screen, which D3D clips (INFERRED: no
##       D3DRS_CLIPPING write found), is hidden: a camera nearer the glow
##       than (byte - 1) hides it;
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
##   bodies, not the NPCs), passing through alpha-tested pieces (occluder),
##   after the frustum test (point_on_screen).
## - "Drawn" is the host's box against the camera's frustum (drawn).
## - Which objects play them: the placed objects that stand at a teleport
##   structure (World3D._attach_gate_effects), always running. The original
##   plays every placed object's ambient set (1,300 sets across 8,539 `.bsr`,
##   MEASURED); since round 786 every other placed object's plays through
##   WorldAmbientFx, with the original's range rules.
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

## The entries of `mods`' `ambient` sets, one Array per mod in file order
## (a failed mode-0 bone ends its own mod's entries; attach).
static func ambient_entries(mods: Array) -> Array:
	var out: Array = []
	for pm in mods:
		var m := pm as BsrReader.ParticleMod
		if m == null or m.set_kind != BsrReader.SET_BY_CLIP or m.set_name != "ambient":
			continue
		var entries: Array = []
		for e in m.entries:
			entries.append(e)
		if not entries.is_empty():
			out.append(entries)
	return out

## The effect files of ambient_entries' output (the prepare job's preload).
static func efp_paths(mods_entries: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for entries in mods_entries:
		for e_v in entries:
			var e := e_v as BsrReader.ParticleEntry
			if e != null and e.efp != "" and not out.has(e.efp):
				out.append(e.efp)
	return out

## The night flag (the effect manager's +0x1a8): this client keeps the
## binary's fixed day phase, so it is never set (see the class comment).
static var night := false

## Whether an entry is built: not a night-only entry while it is day.
static func shows(e: BsrReader.ParticleEntry) -> bool:
	return (e.b51 & 1) == 0 or night

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
	var host: Node3D
	var box := AABB()
	var byte: int = 0
	var alpha: int = 0
	var visible := false
	var seen_frame := -1
	## What the last query's ray met first (the QA log), "" when visible.
	var blocker := ""

var _glows: Array[Glow] = []
## Every effect attach() built (the QA log's screen positions, round 722).
var _effects: Array = []
var _gathered_ms := 0.0
var _frame := 0
## Mods whose remaining entries a missing mode-0 bone stopped (tests, log).
var aborted_mods := 0
## The Light Effect video option (READ above): off, the glows draw as
## ordinary particles and the pass does nothing.
var light_effect := true

## Turns the glow pass on or off (World3D.apply_video_options).
func set_light_effect(on: bool) -> void:
	if on == light_effect:
		return
	light_effect = on
	for g in _glows:
		if is_instance_valid(g.fx):
			g.fx.use_glow(on)

## Whether a host is drawn this frame (OURS stand-in for FUN_00c81450's
## queueing as it draws): shown in the tree and its box in the frustum.
static func drawn(host: Node3D, box: AABB, camera: Camera3D) -> bool:
	if host == null or not is_instance_valid(host) or not host.is_visible_in_tree():
		return false
	if camera == null:
		return true
	if camera.is_position_in_frustum(box.get_center()):
		return true
	for i in range(8):
		if camera.is_position_in_frustum(box.get_endpoint(i)):
			return true
	return false

## Whether the occlusion point can pass at all: not behind the eye and on
## the screen (D3D clips anything else; READ above).
static func point_on_screen(p: Vector3, camera: Camera3D) -> bool:
	return not camera.is_position_behind(p) and camera.is_position_in_frustum(p)

## Tests only (round 786): builds an effect from its path in place of
## EfpEffect.create, as SkillEffects.effect_factory does.
static var effect_factory: Callable = Callable()

## Builds and attaches `host`'s effects, `mods_entries` as ambient_entries
## gives them. Returns them.
## `display_blend` false keeps the effects' linear blend (a QA A/B only,
## WorldAmbientFx's OPENSRO_QA_WORLD_FX_BLEND=linear).
func attach(host: Node3D, mods_entries: Array, particles: Pk2Reader, display_blend: bool = true) -> Array:
	var made: Array = []
	var box := _host_box(host)
	for entries in mods_entries:
		for e_v in entries:
			var e := e_v as BsrReader.ParticleEntry
			if e == null or e.efp == "" or not shows(e):
				continue
			if e.mode == 0 and not has_bone(host, e.bone):
				# vslot_001 returns at once: the mod's later entries go too.
				print("AMBIENT %s: no bone '%s' -- the rest of its mod is not built" % [host.name, e.bone])
				aborted_mods += 1
				break
			var fx: EfpEffect = effect_factory.call(e.efp) if effect_factory.is_valid() else EfpEffect.create(e.efp, particles)
			if fx == null:
				print("AMBIENT %s: %s did not build (%s)" % [host.name, e.efp, EfpEffect.last_error])
				continue
			fx.loop = true
			fx.auto_free = false
			# Blended in display values, as the original's Direct3D 9 blends
			# (round 722, EfpEffect.display_shader; OURS scope: the objects'
			# ambient effects only).
			if display_blend:
				fx.use_display_blend()
			if e.rotated:
				fx.follow_basis = rotation_basis(e.angles)
			if e.mode == 0:
				fx.follow_bone_full = true
				SkillEffects.attach(fx, host, e.bone, Vector3.ZERO)
			else:
				SkillEffects.attach(fx, host, "none", e.offset)
			if e.b50 != 0:
				fx.make_glow()
				fx.use_glow(light_effect)
				var g := Glow.new()
				g.fx = fx
				g.byte = e.b50
				g.host = host
				g.box = box
				_glows.append(g)
			made.append(fx)
			_effects.append([fx, e.b50])
	return made

## Whether `host` carries a skeleton with a bone named `bone` (mode 0's
## FUN_00c818c0: the host's +0xf4, then the bone by name).
static func has_bone(host: Node, bone: String) -> bool:
	for sk in host.find_children("*", "Skeleton3D", true, false):
		if (sk as Skeleton3D).find_bone(bone) >= 0:
			return true
	return false

## The host's drawn box in world space (its meshes), for drawn().
static func _host_box(host: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for m in host.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null or not mi.is_inside_tree():
			continue
		var b := mi.global_transform * mi.get_aabb()
		out = b if first else out.merge(b)
		first = false
	if first and host.is_inside_tree():
		out = AABB(host.global_position, Vector3.ZERO)
	return out

## The glow pass, once a frame.
func update(frame_ms: float, camera: Camera3D, space: PhysicsDirectSpaceState3D) -> void:
	_frame += 1
	var alive: Array[Glow] = []
	for g in _glows:
		if is_instance_valid(g.fx) and g.fx.is_inside_tree():
			alive.append(g)
	_glows = alive
	if _glows.is_empty() or not light_effect:
		_gathered_ms = 0.0
		return
	var shown: Array[Glow] = []
	for g in _glows:
		# Round 774: an effect its owner has culled (a dungeon's far ones,
		# World3D._cull_dungeon_effects) draws nothing, so its glow is not
		# queued -- FUN_00c81450 queues a glow as it draws it. Not
		# `visible`: a glow hides itself until it fades in (v0.1.523 tested
		# that, and no glow anywhere ever faded in -- the Jangan gate's).
		if not g.fx.culled and drawn(g.host, g.box, camera):
			shown.append(g)
	if shown.is_empty():
		return
	_gathered_ms += frame_ms
	if _gathered_ms > QUERY_MS and camera != null and space != null:
		_gathered_ms = fmod(_gathered_ms, QUERY_MS)
		var eye := camera.global_position
		for g in shown:
			var p := query_point(g.fx.placed_at(), eye, g.byte)
			if not point_on_screen(p, camera):
				g.visible = false
				g.blocker = "off screen or behind the eye"
				continue
			var hit := occluder(space, eye, p)
			g.visible = hit.is_empty()
			g.blocker = "" if g.visible else "%s n.d %.2f" % [_blocker_name(hit),
				(hit.get("normal", Vector3.ZERO) as Vector3).dot((p - eye).normalized())]
			if not last_passed.is_empty():
				g.blocker += " (passed %s)" % ", ".join(last_passed)
	for g in shown:
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
	last_passed.clear()
	for _i in range(MAX_PASS_THROUGH + 1):
		var q := PhysicsRayQueryParameters3D.create(from, to, OCCLUDER_MASK, exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or not _alpha_tested(hit.get("collider")):
			return hit
		# The texel the depth test would have kept or cut (round 722): an
		# opaque texel hides the point as any surface does; a cut one lets
		# the ray on. Unreadable (no face, UV or image) passes, as round 720
		# passed every alpha-tested piece.
		var kept := texel_kept(hit)
		if kept == 1:
			return hit
		last_passed.append("%s %s" % [_blocker_name(hit), "cut texel" if kept == 0 else "unreadable"])
		exclude.append(hit["rid"])
	return {}

## Whether an alpha-tested piece keeps the texel a ray hit lands on (round
## 722): 1 kept (its mip-0 alpha at or above the material's threshold, the
## alpha test GREATEREQUAL 0x80 READ in BMT_FORMAT.md), 0 cut, -1 not
## readable. The hit's face is the trimesh's (`face_index`: the piece's
## faces are its index list in order, ObjectLoader._piece_faces), its UV the
## barycentric mix of that face's three corners.
static func texel_kept(hit: Dictionary) -> int:
	var c = hit.get("collider")
	if not (c is Node):
		return -1
	var mi := (c as Node).get_parent() as MeshInstance3D
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return -1
	var m := mi.material_override as ShaderMaterial
	if m == null:
		return -1
	var tex = m.get_shader_parameter("albedo_texture")
	var ref = m.get_shader_parameter("alpha_scissor")
	if not (tex is Texture2D) or ref == null:
		return -1
	var face := int(hit.get("face_index", -1))
	var arrays := _surface_arrays(mi.mesh)
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs = arrays[Mesh.ARRAY_TEX_UV]
	if face < 0 or uvs == null or 3 * face + 2 >= idx.size():
		return -1
	var a := idx[3 * face]
	var b := idx[3 * face + 1]
	var d := idx[3 * face + 2]
	var local: Vector3 = mi.global_transform.affine_inverse() * (hit["position"] as Vector3)
	var bary := Geometry3D.get_triangle_barycentric_coords(local, pos[a], pos[b], pos[d])
	if bary == Vector3.ZERO:
		return -1
	var uv: Vector2 = (uvs as PackedVector2Array)[a] * bary.x + (uvs as PackedVector2Array)[b] * bary.y \
		+ (uvs as PackedVector2Array)[d] * bary.z
	var img := _alpha_image(tex as Texture2D)
	if img == null:
		return -1
	var w := img.get_width()
	var h := img.get_height()
	var x := posmod(int(floor(uv.x * w)), w)
	var y := posmod(int(floor(uv.y * h)), h)
	return 1 if img.get_pixel(x, y).a >= float(ref) else 0

## A mesh's first surface's arrays, kept (the glow test asks every 500 ms).
static var _arrays_cache := {}
## Meta a mesh may carry with its arrays, read before any readback.
const META_ARRAYS := "opensro_texel_arrays"
static func _surface_arrays(mesh: Mesh) -> Array:
	if mesh.has_meta(META_ARRAYS):
		return mesh.get_meta(META_ARRAYS)
	var key := mesh.get_rid()
	if _arrays_cache.has(key):
		return _arrays_cache[key]
	if _arrays_cache.size() > 256:
		_arrays_cache.clear()
	var arr := mesh.surface_get_arrays(0)
	_arrays_cache[key] = arr
	return arr

## A texture's mip-0 image, decompressed, kept.
static var _image_cache := {}
## Meta a texture may carry with its decoded image, read before a readback.
const META_IMAGE := "opensro_texel_image"
static func _alpha_image(tex: Texture2D) -> Image:
	if tex.has_meta(META_IMAGE):
		return tex.get_meta(META_IMAGE)
	var key := tex.get_rid()
	if _image_cache.has(key):
		return _image_cache[key]
	if _image_cache.size() > 64:
		_image_cache.clear()
	var img := tex.get_image()
	if img != null:
		img = img.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
	_image_cache[key] = img
	return img

## The alpha-tested pieces the last occluder() ray passed through (the QA
## log, round 722).
static var last_passed: Array[String] = []

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

## For the QA log (round 722): each effect's world position, its distance
## from the camera and where it lands on the screen (off when behind the eye
## or outside the frustum), and the camera's own position.
func describe_screen(camera: Camera3D, space: PhysicsDirectSpaceState3D = null) -> String:
	if camera == null:
		return ""
	var parts: Array[String] = ["camera %s" % str(camera.global_position.round())]
	var keep: Array = []
	for pair in _effects:
		var fx = pair[0]
		if not is_instance_valid(fx) or not (fx as Node).is_inside_tree():
			continue
		keep.append(pair)
		var at: Vector3 = (fx as EfpEffect).placed_at()
		var where := "off"
		if not camera.is_position_behind(at) and camera.is_position_in_frustum(at):
			where = str(camera.unproject_position(at).round())
		var box: AABB = (fx as EfpEffect).particle_extent()
		var first_hit := ""
		if space != null:
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(camera.global_position, at, OCCLUDER_MASK))
			if not hit.is_empty():
				first_hit = " ray hits %s at d%.1f" % [_blocker_name(hit), camera.global_position.distance_to(hit["position"])]
		parts.append("%s[%d] at %s d%.0f screen %s particles %s..%s" % [(fx as EfpEffect).path.get_file(), int(pair[1]),
			str(at.round()), camera.global_position.distance_to(at), where, str(box.position.round()), str(box.end.round())] + first_hit)
	_effects = keep
	return ", ".join(parts)

func glow_count() -> int:
	return _glows.size()

## For the QA log: each glow's alpha and visibility.
func describe() -> String:
	var parts: Array[String] = []
	for g in _glows:
		if is_instance_valid(g.fx):
			parts.append("%s a%d %s" % [g.fx.path.get_file(), g.alpha, ("vis " + g.blocker) if g.visible else "hid by " + g.blocker])
	return ", ".join(parts)
