extends RefCounted
class_name BodyPulse

## A body's colour pulse (round 855): the one colour slot a character's
## drawing has, shared by an abnormal state's pulse (StateLook) and berserk's
## SCT_MAT pulse (BerserkLook). Labels: READ (sro_client.exe, `c:`), MEASURED,
## INFERRED, OURS, OPEN.
##
## THE ORIGINAL (READ). The pulse lives on the character's compound object
## ([obj+0x9c]+4, CCompChar), not on any material:
## - start, vtable +0x48 (CObjRendererVS::FUN_00c25800): the flag +0x1ec = 1,
##   the two colours at +0x238 / +0x244, the ms at +0x250, the elapsed +0x254
##   = 0 rising (+0x258 = 1), the current colour (+0x1f4) = colour 1. A second
##   start overwrites the same fields: one slot, the last start wins.
## - each frame the compound's update (CCompChar::FUN_00c33430) steps it while
##   +0x1ec is set (FUN_00c26ff0: the elapsed up to the ms and back down, the
##   colour lerped between the two -- `pulse`);
## - every part drawn reads its compound's flag (CObjRendererVS::vslot_038,
##   c:0xbf5830: param_1[0x38] = [compound+0x1ec]) and, while it is set, draws
##   with the pulse colour in place of the material's and the object's
##   (FUN_00c27180: c10, c11, c14);
## - end, vtable +0x4c (FUN_00c258b0): +0x1ec = 0, nothing else. The next draw
##   of every part is its own material again.
## - Who ends it: a state's tinted bit going off (FUN_009cd5e0, c:0x9cdb5d and
##   the FB case) and berserk's decoration end when its row has SCT_MAT
##   (CIDecoSkill::FUN_00a53dd0, flag 0x800) -- each calls +0x4c whoever set
##   the colour last. So a berserk body poisoned draws the poison's colour,
##   and either end leaves the body uncoloured while the other still runs.
## So the colour is never written into a material: a part added or rebuilt
## mid-pulse draws it, and at the end nothing has to be put back.
##
## HERE (OURS method): Godot has no per-draw state of that kind for these
## materials (a per-instance uniform overflowed the instance buffer, round
## 706), so each mesh of the body draws a private copy of its own material
## while the slot is on, and the copy is painted (the object shader's
## `object_tint`, w 1 -- c10 and c11 -- or a plain material's albedo). The rule
## that keeps the original's "no material is touched":
## - only a copy made here is ever painted. Each frame every mesh is checked:
##   one drawing its copy is painted; one whose material something else
##   replaced (an equipment glow, a level copy, a fade's end) has that new
##   material taken as its own and a fresh copy made of it; one drawing a fade
##   twin keeps the twin, and the copy is what the fade gives back
##   (AppearFade.ORIGINAL_META); a twin made from the copy (a fade begun
##   mid-pulse) is the mesh's alone and is painted too;
## - CharacterLight leaves a mesh this holds alone (its level copies are
##   shared by every body at the level); while the slot is on, the level does
##   not show (the pulse stands in for the object colour, READ above), and at
##   the end the mesh gets its own material at the body's level now.
## Before (round 785-854) StateLook painted whatever the mesh drew: once
## CharacterLight swapped the copy for its shared level copy (every 8 visits),
## the pulse painted that shared material, and its last colour stayed on this
## body and every body at that level after the state ended (MEASURED, round
## 855).

## On a mesh this holds: the material it draws with outside the pulse.
## CharacterLight.PULSE_META is the same string.
const ORIGINAL_META := "body_pulse_original_material"

## host instance id -> {host, c1, c2, ms, t0, who, meshes: {mesh id -> entry}}
## entry: {mi, orig, copy, foreign_twin}
static var _slots: Dictionary = {}
static var _clock := 0.0

## The colour `elapsed_ms` after a start (CCompChar::FUN_00c26ff0): colour 1
## at 0, colour 2 at `ms`, colour 1 again at 2 x `ms`; colour 1 for ms 0.
static func pulse(elapsed_ms: float, c1: Color, c2: Color, ms: float) -> Color:
	if ms <= 0.0:
		return c1
	var cycle := fposmod(maxf(elapsed_ms, 0.0), 2.0 * ms)
	var f := cycle / ms if cycle <= ms else (2.0 * ms - cycle) / ms
	return c1.lerp(c2, f)

## +0x48: `host` pulses from `c1` to `c2` and back every 2 x `ms`, from colour
## 1 now. `who` names the setter ("state", "berserk") for the books and logs.
static func start(host: Node3D, c1: Color, c2: Color, ms: float, who: String) -> void:
	if host == null or not is_instance_valid(host):
		return
	var key := host.get_instance_id()
	var s: Dictionary = _slots.get(key, {"host": host, "meshes": {}})
	s["c1"] = c1
	s["c2"] = c2
	s["ms"] = ms
	s["t0"] = _clock
	s["who"] = who
	_slots[key] = s
	_step(s)

## +0x4c: `host`'s colour ends, whoever set it. Every mesh draws its own
## material again, at the body's level now. Whether a pulse was on.
static func stop(host: Node3D) -> bool:
	if host == null:
		return false
	var key := host.get_instance_id()
	if not _slots.has(key):
		return false
	_release(_slots[key])
	_slots.erase(key)
	return true

static func on(host: Node3D) -> bool:
	return host != null and is_instance_valid(host) and _slots.has(host.get_instance_id())

## Who set `host`'s colour last ("" when it has none).
static func who(host: Node3D) -> String:
	if not on(host):
		return ""
	return String((_slots[host.get_instance_id()] as Dictionary)["who"])

## The colour `host` is drawn with now, or null.
static func colour_of(host: Node3D):
	if not on(host):
		return null
	return _colour(_slots[host.get_instance_id()])

## Bodies with a colour on (tests).
static func count() -> int:
	return _slots.size()

## Every frame (World3D): each slot steps and paints; a freed body's slot goes.
static func tick(delta: float) -> void:
	_clock += maxf(delta, 0.0)
	for key in _slots.keys():
		var s: Dictionary = _slots[key]
		if not is_instance_valid(s["host"]):
			_slots.erase(key)
			continue
		_step(s)

## Every colour off (a world unload).
static func clear() -> void:
	for key in _slots.keys():
		_release(_slots[key])
	_slots.clear()

static func _colour(s: Dictionary) -> Color:
	return pulse((_clock - float(s["t0"])) * 1000.0, s["c1"], s["c2"], float(s["ms"]))

## The body's meshes, not an effect's.
static func _meshes_of(host: Node3D) -> Array:
	var skel := SkillEffects.skeleton_of(host)
	if skel == null:
		return []
	var out: Array = []
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.is_queued_for_deletion() or _in_effect(mi, skel):
			continue
		out.append(mi)
	return out

static func _in_effect(n: Node, stop_at: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != stop_at:
		if p is EfpEffect:
			return true
		p = p.get_parent()
	return false

static func _paintable(m: Material) -> bool:
	return m is StandardMaterial3D or (m is ShaderMaterial and (m as ShaderMaterial).shader != null)

static func _is_twin(m: Material) -> bool:
	return m != null and m.has_meta(AppearFade.TWIN_META)

## A private copy of `m` to paint: an object material copied by parameter
## (ObjectLight.copy_material, round 706's review), any other duplicated.
static func _copy(m: Material) -> Material:
	if m is ShaderMaterial:
		return ObjectLight.copy_material(m as ShaderMaterial)
	return m.duplicate()

## Takes every mesh of the slot's body that is not taken (or whose material
## was replaced since), then paints the copies -- and only them.
static func _step(s: Dictionary) -> void:
	var host: Node3D = s["host"]
	var meshes: Dictionary = s["meshes"]
	var live := {}
	for mi in _meshes_of(host):
		var id: int = mi.get_instance_id()
		live[id] = true
		var e: Dictionary = meshes.get(id, {})
		var now: Material = mi.material_override
		if not e.is_empty() and now == e["copy"]:
			continue
		if _is_twin(now) and mi.has_meta(AppearFade.ORIGINAL_META):
			# A fade draws the mesh: the fade gives back its ORIGINAL_META.
			var back: Material = mi.get_meta(AppearFade.ORIGINAL_META)
			if not e.is_empty() and back == e["copy"]:
				continue
			if back == null or not _paintable(back):
				_forget(mi, e)
				meshes.erase(id)
				continue
			# The fade began before the pulse (or its own material changed
			# under it): its twin is the cohort's, never painted here; the
			# copy waits to be given back.
			e = {"mi": mi, "orig": back, "copy": _copy(back), "foreign_twin": now}
			mi.set_meta(AppearFade.ORIGINAL_META, e["copy"])
			mi.set_meta(ORIGINAL_META, back)
			meshes[id] = e
			continue
		if now == null or not _paintable(now):
			_forget(mi, e)
			meshes.erase(id)
			continue
		# First seen, or its material was replaced (EquipGlow, a fade's end,
		# another writer): that material is its own now.
		e = {"mi": mi, "orig": now, "copy": _copy(now), "foreign_twin": null}
		mi.set_meta(ORIGINAL_META, now)
		mi.material_override = e["copy"]
		meshes[id] = e
	for id in meshes.keys():
		if not live.has(id):
			var gone: Dictionary = meshes[id]
			var mi = gone["mi"]
			if mi != null and is_instance_valid(mi):
				_put_back(mi as MeshInstance3D, gone, host)
			meshes.erase(id)
	var c := _colour(s)
	for id in meshes:
		var e: Dictionary = meshes[id]
		paint(e["copy"], c)
		var mi := e["mi"] as MeshInstance3D
		var now := mi.material_override
		# A fade begun mid-pulse twins the copy: that twin is this mesh's alone.
		if _is_twin(now) and now != e["foreign_twin"]:
			paint(now, c)

## A mesh that left the slot without being put back (its material is not
## paintable now): its mark goes.
static func _forget(mi: MeshInstance3D, e: Dictionary) -> void:
	if mi.has_meta(ORIGINAL_META):
		mi.remove_meta(ORIGINAL_META)

static func _release(s: Dictionary) -> void:
	var host = s["host"]
	for id in (s["meshes"] as Dictionary).keys():
		var e: Dictionary = s["meshes"][id]
		var mi = e["mi"]
		if mi != null and is_instance_valid(mi):
			_put_back(mi as MeshInstance3D, e, host if host != null and is_instance_valid(host) else null)
	(s["meshes"] as Dictionary).clear()

## The mesh draws its own material again: where it draws the copy, or where a
## fade will give the copy back, the material it had -- at its body's level
## now (CharacterLight left it alone meanwhile). A twin made from the copy is
## unpainted. Anything else drawing on it now is left as it is.
static func _put_back(mi: MeshInstance3D, e: Dictionary, host) -> void:
	var own: Material = _at_level(e["orig"], mi)
	var now := mi.material_override
	if now == e["copy"]:
		mi.material_override = own
	elif _is_twin(now) and mi.has_meta(AppearFade.ORIGINAL_META) and mi.get_meta(AppearFade.ORIGINAL_META) == e["copy"]:
		mi.set_meta(AppearFade.ORIGINAL_META, own)
		if now != e["foreign_twin"]:
			unpaint(now, e["orig"])
	if mi.has_meta(ORIGINAL_META):
		mi.remove_meta(ORIGINAL_META)

## `orig` at the level CharacterLight last set on the body `mi` belongs to.
static func _at_level(orig: Material, mi: Node) -> Material:
	if not ObjectLight.is_object_material(orig):
		return orig
	var n := mi.get_parent()
	while n != null:
		if n.has_meta(CharacterLight.META_VALUE):
			return ObjectLight.with_object_color(orig, float(n.get_meta(CharacterLight.META_VALUE)))
		n = n.get_parent()
	return orig

## Draws `m` (a copy made here) in pulse colour `c`.
static func paint(m: Material, c: Color) -> void:
	if m is StandardMaterial3D:
		var sm := m as StandardMaterial3D
		sm.albedo_color = Color(c.r, c.g, c.b, sm.albedo_color.a)
	elif m is ShaderMaterial:
		var sh := m as ShaderMaterial
		if _object_lit(sh.shader):
			# The object shaders (round 706, ObjectLight): the pulse stands in
			# for both the material's and the object's colour (c11 and c10),
			# as the original's does. A Vector4: as given in both renderers.
			sh.set_shader_parameter("object_tint", Vector4(c.r, c.g, c.b, 1.0))
			return
		var was = sh.get_shader_parameter("albedo")
		if was is Color:
			sh.set_shader_parameter("albedo", Color(c.r, c.g, c.b, (was as Color).a))

## Takes the pulse colour off a twin made from a copy of `orig` (the copy
## itself is dropped): an object shader's tint goes off, a plain twin's albedo
## is `orig`'s again.
static func unpaint(m: Material, orig: Material) -> void:
	if not (m is ShaderMaterial):
		return
	var sh := m as ShaderMaterial
	if _object_lit(sh.shader):
		sh.set_shader_parameter("object_tint", Vector4(0.0, 0.0, 0.0, 0.0))
		return
	var was = sh.get_shader_parameter("albedo")
	var own = null
	if orig is StandardMaterial3D:
		own = (orig as StandardMaterial3D).albedo_color
	elif orig is ShaderMaterial:
		own = (orig as ShaderMaterial).get_shader_parameter("albedo")
	if was is Color and own is Color:
		sh.set_shader_parameter("albedo", Color((own as Color).r, (own as Color).g, (own as Color).b, (was as Color).a))

## Whether a shader is one of the object shaders (its code names the object
## lighting include, or is generated with srr_obj_od0).
static func _object_lit(shader: Shader) -> bool:
	return shader != null and (shader.code.contains("srr_obj_od0") or shader.code.contains("object.gdshaderinc"))
