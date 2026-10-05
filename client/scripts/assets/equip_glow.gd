extends RefCounted
class_name EquipGlow

## A weapon or shield's glow and its particles (round 734,
## docs/protocol/weapon_glow.md), put on an item already hung on a body.
##
## **What retail does (READ).** `CObjCharacter::FUN_00a60a90` runs for the
## kind-1 attachments (weapon and shield) with the slot's plus byte;
## `FUN_00a5f3e0` then
##   1. for plus != 0, picks the glow row (ItemGlowTables.glow_row) and puts a
##      CRTModProgEquipPow on the item's draw: the stage ops of
##      object.gdshaderinc's EQUIP_GLOW path, unlit, the option texture
##      scrolling over the item's own;
##   2. for every particle row with min <= plus <= max, attaches the row's
##      `.efp` at the row's bone of the item, kept (the `1`: IEasyFxEffect
##      slot 4), no start delay (the trailing `0`: CRTModParticle +0xc4, a
##      countdown in ms), at the row's scale (+0xc0 -> CEFEffect::vslot_010).
##      The first string is the efp, the second the bone, checked against
##      "none" (READ round 734, CRTModParticle::FUN_00c816c0).
## The mod's gate is the owner's colour word at full alpha (0xFF000000), so a
## fading or translucent character draws without it: AppearFade and the
## select screen's fade take plain_of(material) (OURS mechanism, READ rule).
##
## **Here.** Each mesh of the item gets a glow ShaderMaterial on the object
## include (EQUIP_GLOW), keeping the plain material it replaced in PLAIN_META;
## a material is shared per (row, cull, test, item texture). The particles
## are EfpEffects on the item's own Skeleton3D (its `.bsk` carries `ai_end`,
## `ai_start`, `Bone01`..`03`, MEASURED round 734), placed at the bone's full
## transform each frame.
##
## Labels as in the spec: READ, MEASURED, INFERRED, OURS, OPEN.

## On a glow material: the plain material it stands in for.
const PLAIN_META := "opensro_glow_plain"
## On an EfpEffect made here.
const FX_META := "opensro_glow_fx"

static var _shaders := {}
static var _option_textures := {}   # lower-case path -> Texture2D (null: missing)
static var _materials := {}         # key -> WeakRef(ShaderMaterial)
static var _lock := Mutex.new()
static var stats := {"items": 0, "meshes": 0, "particles": 0, "particles_failed": 0, "no_bone": 0}

## The glow shader for a cull mode ("back", "front", "disabled") and the row's
## alpha-test flag. Flag 0 turns the alpha test OFF and flag 1 tests alpha >=
## 1/255 (READ, vslot_004: RS 15/24/25), so a flag-0 item draws solid
## whatever its own layer did.
static func glow_shader(cull: String, alpha_test: bool) -> Shader:
	var key := "%s/%s" % [cull, alpha_test]
	_lock.lock()
	var cached: Shader = _shaders.get(key)
	_lock.unlock()
	if cached != null:
		return cached
	var sh := Shader.new()
	sh.code = "shader_type spatial;\n// An item's glow, cull %s%s (EquipGlow, round 734).\nrender_mode unshaded, cull_%s;\n#define EQUIP_GLOW\n%s#include \"res://scripts/assets/object.gdshaderinc\"\n" % [
		cull, ", alpha-tested" if alpha_test else "", cull, "" if alpha_test else "#define OBJECT_SOLID\n"]
	_lock.lock()
	if _shaders.has(key):
		sh = _shaders[key]
	else:
		_shaders[key] = sh
	_lock.unlock()
	return sh

## The cull mode `m` draws with: an object shader's kind, a mod shader's key,
## "back" otherwise.
static func cull_of(m: Material) -> String:
	if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
		var sh := (m as ShaderMaterial).shader
		if sh.has_meta(ObjectLoader.OBJECT_SHADER_KIND_META):
			return "disabled" if String(sh.get_meta(ObjectLoader.OBJECT_SHADER_KIND_META)) == "two" else "back"
		if sh.has_meta(ObjectLoader.MOD_SHADER_KEY_META):
			return String((sh.get_meta(ObjectLoader.MOD_SHADER_KEY_META) as Array)[0])
		if sh.code.contains("cull_disabled"):
			return "disabled"
		if sh.code.contains("cull_front"):
			return "front"
	elif m is BaseMaterial3D:
		match (m as BaseMaterial3D).cull_mode:
			BaseMaterial3D.CULL_DISABLED: return "disabled"
			BaseMaterial3D.CULL_FRONT: return "front"
	return "back"

## The item's own texture under `m`: the object shaders' albedo_texture.
static func item_texture(m: Material) -> Texture2D:
	if m is ShaderMaterial:
		return (m as ShaderMaterial).get_shader_parameter("albedo_texture") as Texture2D
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).albedo_texture
	return null

## The plain material behind `m`: the one a glow material replaced, else `m`.
static func plain_of(m: Material) -> Material:
	if m == null:
		return null
	return m.get_meta(PLAIN_META) if m.has_meta(PLAIN_META) else m

## Whether `m` is a glow material.
static func is_glow(m: Material) -> bool:
	return m != null and m.has_meta(PLAIN_META)

## The uniforms a row sets (the shader's names), for the material and the
## tests: speed uv x 50 a second, the period in seconds, op0's factor, op1's
## signed flag.
static func row_params(row: ItemGlowTables.GlowRow) -> Dictionary:
	return {
		"glow_uv_speed": row.uv_per_second(),
		"glow_c1": row.color1,
		"glow_c2": row.color2,
		"glow_period": maxf(float(row.period_ms), 1.0) / 1000.0,
		"glow_mul0": 2.0 if row.op0 == ItemGlowTables.OP_MODULATE2X else 1.0,
		"glow_signed2x": 1.0 if row.op1 == ItemGlowTables.OP_ADDSIGNED2X else 0.0,
		"alpha_scissor": 1.0 / 255.0 if row.alpha_test else 0.0,
	}

## The glow material standing in for `plain` under `row`, shared per (row,
## plain material, option texture): the items' plain materials are already
## shared by every body wearing the item (CharacterAppearance's templates).
static func material_for(plain: Material, row: ItemGlowTables.GlowRow, option_tex: Texture2D) -> ShaderMaterial:
	var cull := cull_of(plain)
	var tex := item_texture(plain)
	var key := "%d/%d/%s/%d/%d" % [row.type_number, row.plus, cull, plain.get_instance_id(),
		option_tex.get_instance_id() if option_tex != null else 0]
	_lock.lock()
	var ref: WeakRef = _materials.get(key)
	var mat: ShaderMaterial = ref.get_ref() as ShaderMaterial if ref != null else null
	_lock.unlock()
	if mat != null:
		return mat
	mat = ShaderMaterial.new()
	mat.resource_name = "glow+%d" % row.plus
	mat.shader = glow_shader(cull, row.alpha_test)
	if tex != null:
		mat.set_shader_parameter("albedo_texture", tex)
	if option_tex != null:
		mat.set_shader_parameter("glow_texture", option_tex)
	var p := row_params(row)
	for k in p:
		mat.set_shader_parameter(k, p[k])
	mat.set_meta(PLAIN_META, plain)
	_lock.lock()
	_materials[key] = weakref(mat)
	_lock.unlock()
	return mat

## The option texture at `path` in `data` (Data.pk2), decoded once.
static func option_texture(data: Pk2Reader, path: String) -> Texture2D:
	var key := path.to_lower()
	_lock.lock()
	var had := _option_textures.has(key)
	var tex: Texture2D = _option_textures.get(key)
	_lock.unlock()
	if had:
		return tex
	if data != null:
		var missing: Array = []
		var decoded := ObjectLoader._decode_texture(data, path, ItemGlowTables.TYPE_PATH, missing)
		if not decoded.is_empty():
			tex = ImageTexture.create_from_image(decoded["image"])
		for m in missing:
			push_warning("EquipGlow: %s" % m)
	_lock.lock()
	_option_textures[key] = tex
	_lock.unlock()
	return tex

## The meshes of an item node, not counting an effect's.
static func meshes_of(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is EfpEffect:
			continue
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

## Puts the glow of `row` (null: none) on every mesh under `nodes`, and the
## particles of `particle_rows` on the item's own skeleton. Returns
## {"meshes": n, "particles": n}.
static func apply(nodes: Array, row: ItemGlowTables.GlowRow, particle_rows: Array, data: Pk2Reader,
		particles: Pk2Reader, label: String = "") -> Dictionary:
	var out := {"meshes": 0, "particles": 0}
	if row != null:
		var option_tex := option_texture(data, row.texture)
		for node in nodes:
			if not is_instance_valid(node):
				continue
			for mi in meshes_of(node):
				var plain := plain_of(mi.material_override)
				if plain == null:
					continue
				mi.material_override = material_for(plain, row, option_tex)
				out["meshes"] += 1
	for pr in particle_rows:
		var r := pr as ItemGlowTables.ParticleRow
		var host := _bone_host(nodes, r.bone)
		if host == null:
			# READ: FUN_00c816c0 returns 0 when the bone is not found, and
			# FUN_00c77ca0 frees the mod -- no effect.
			stats["no_bone"] += 1
			print("EquipGlow %s: no bone '%s' for %s -- not attached" % [label, r.bone, r.efp])
			continue
		var fx := EfpEffect.create(r.efp, particles)
		if fx == null:
			stats["particles_failed"] += 1
			print("EquipGlow %s: %s did not build (%s)" % [label, r.efp, EfpEffect.last_error])
			continue
		fx.loop = true
		fx.auto_free = false
		fx.follow_bone_full = true
		fx.effect_scale = r.scale
		fx.set_meta(FX_META, true)
		SkillEffects.attach(fx, host, r.bone, r.offset)
		out["particles"] += 1
	stats["items"] += 1
	stats["meshes"] += out["meshes"]
	stats["particles"] += out["particles"]
	return out

## The item skeleton under `nodes` that has `bone`, or null.
static func _bone_host(nodes: Array, bone: String) -> Skeleton3D:
	if bone == "" or bone.to_lower() == "none":
		return null
	for node in nodes:
		if not is_instance_valid(node):
			continue
		var skels: Array = (node as Node).find_children("*", "Skeleton3D", true, false)
		if node is Skeleton3D:
			skels.push_front(node)
		for s in skels:
			if (s as Skeleton3D).find_bone(bone) >= 0:
				return s
	return null

## A QA loadout, "slot=item_id[+plus],..." (OPENSRO_QA_EQUIP, the lineup's
## kits): [slot -> item id, slot -> plus]. A malformed pair is skipped and
## named in `bad`.
static func parse_loadout(spec: String, bad: Array = []) -> Array:
	var eq := {}
	var pl := {}
	for pair in spec.split(",", false):
		var kv := String(pair).split("=")
		var idp := kv[1].split("+") if kv.size() == 2 else PackedStringArray()
		if kv.size() != 2 or not kv[0].strip_edges().is_valid_int() or idp.size() > 2 or not idp[0].strip_edges().is_valid_int() \
				or (idp.size() == 2 and not idp[1].strip_edges().is_valid_int()):
			bad.append(pair)
			continue
		var slot := int(kv[0].strip_edges())
		eq[slot] = int(idp[0].strip_edges())
		if idp.size() == 2:
			pl[slot] = int(idp[1].strip_edges()) & 0xFF
	return [eq, pl]

## Takes the glow off: every mesh under `root` back on its plain material,
## and every particle effect made here freed. Returns the meshes restored.
static func clear(root: Node) -> int:
	var n := 0
	if root == null:
		return 0
	for mi in meshes_of(root):
		if is_glow(mi.material_override):
			mi.material_override = plain_of(mi.material_override)
			n += 1
	strip_particles(root)
	return n

## Frees the particle effects made here under `root` (a copied body, as the
## portrait's, whose duplicated effects have no simulation). Returns how many.
static func strip_particles(root: Node) -> int:
	var n := 0
	if root == null:
		return 0
	var found: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is EfpEffect and c.has_meta(FX_META):
			found.append(c)
			continue
		for k in c.get_children():
			stack.append(k)
	for fx in found:
		fx.get_parent().remove_child(fx)
		fx.free()
		n += 1
	return n
