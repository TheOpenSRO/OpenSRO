extends RefCounted
class_name TintProbe

## What colour a body is drawn with, measured on its meshes (round 855): the
## colour pulse of an abnormal state or of berserk (StateLook, BerserkLook)
## is the object shader's `object_tint`, w 1 while it runs (object.gdshaderinc).
## A body is "tinted" when a mesh of it draws a material whose object_tint is
## on -- whatever the pulse's books say. QA (OPENSRO_QA_TINT_PROBE, World3D)
## and the tests read it; nothing in the game does.

## {meshes: int, tinted: int, colour: Color or null} for `body`'s meshes
## (AppearFade.instances_of: an effect's meshes are not the body's).
static func measure(body: Node) -> Dictionary:
	var out := {"meshes": 0, "tinted": 0, "colour": null}
	if body == null or not is_instance_valid(body):
		return out
	for mi in AppearFade.instances_of(body):
		if mi.is_queued_for_deletion():
			continue
		out["meshes"] = int(out["meshes"]) + 1
		var c = tint_of(mi.material_override)
		if c == null and mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				c = tint_of(mi.get_active_material(s))
				if c != null:
					break
		if c != null:
			out["tinted"] = int(out["tinted"]) + 1
			if out["colour"] == null:
				out["colour"] = c
	return out

## The pulse colour `m` draws with, or null when its object_tint is off.
static func tint_of(m: Material):
	if not (m is ShaderMaterial):
		return null
	var t = (m as ShaderMaterial).get_shader_parameter("object_tint")
	if t is Vector4 and (t as Vector4).w > 0.5:
		return Color((t as Vector4).x, (t as Vector4).y, (t as Vector4).z)
	if t is Color and (t as Color).a > 0.5:
		return Color((t as Color).r, (t as Color).g, (t as Color).b)
	return null

## How many of ObjectLight's shared per-level copies draw a pulse colour --
## a material every body at that level shares, which no pulse may paint.
static func shared_tinted() -> int:
	var n := 0
	for key in ObjectLight._variants:
		var per: Dictionary = ObjectLight._variants[key]
		for level in per:
			var ref: WeakRef = per[level]
			var m = ref.get_ref() if ref != null else null
			if m is Material and tint_of(m) != null:
				n += 1
	return n
