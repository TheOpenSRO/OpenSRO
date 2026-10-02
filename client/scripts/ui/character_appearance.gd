extends RefCounted
class_name CharacterAppearance

## Builds a player character's body as the lobby list describes it: a model id
## (any of the 52 Figures, China or Europe, man or woman), the scale byte
## (Height and Volume), and the worn items with their plus. The character
## select screen, the customize preview and later the world's bodies all use
## it, so it knows nothing of World3D, Login or the screens.
##
##   var appearance := CharacterAppearance.from_archives(data_pk2, media_pk2)
##   var body := appearance.build(1907, 0x22, [{"id": 3643, "plus": 0}, ...])
##   add_child(body)                                   # a Node3D
##   var idle := appearance.animation_for(body, BsrReader.AnimationEntry.TYPE_STAND)
##   body.pose(idle, seconds)                          # each frame, if wanted
##   body.set_scale_byte(0x40)                         # a slider moved
##
## Everything comes from the player's own Data.pk2 / Media.pk2 at runtime.
##
## **What the scale byte does (READ, sro_client.exe):**
## - `FUN_00a5b960` splits it: the low nibble is Height (above 4 reads 0), the
##   high nibble Volume (above 7 reads 0, then `FUN_00a5b7e0` clamps it to
##   0..4). 0xFF changes nothing.
## - **Height** scales the whole model uniformly by HEIGHT_FACTORS (table
##   0xec64b0), through `CCompChar` vslot 9 (0xc25460).
## - **Volume** scales bone groups by VOLUME_TABLE_* (0xec64c8, 0xec6528):
##   for v < 2 `min + (1 - min) * v / 2`, for v >= 2 `1 + (max - 1) * (v - 2) / 2`.
##   Each group number goes to `CCompChar` vslot 49 (0xc2ca90), which takes it
##   as an index into the 38 bone names `FUN_00d79e00` builds at 0xed9b68
##   (BONE_GROUP_NAMES), finds that bone (0xc2c890) and stores the factor in it
##   (0xc4aaf0: CRTBone +0x88, flag 2 in +0x84). `RTSkeleton::FUN_00c4a180`
##   then copies the bone's world matrix, multiplies its rows 1 and 2 -- the
##   bone's own Y and Z axes -- by the factor (row 0, the axis along the bone,
##   is left), and multiplies the inverse bind in front of it into +0x8c; the
##   renderer (`CObjRendererVS::FUN_00bf0310`) uses +0x8c as that bone's
##   skinning matrix whenever flag 2 is set. So Volume thickens or thins the
##   vertices weighted to the group's bones across the bone, never along it,
##   and moves no child bone. Here that is the bone's Skin bind pose
##   pre-multiplied by `scale(1, f, f)`, on every mesh skinned to the body.
## - Which table is whose: `FUN_00a5b7e0` picks 0xec6528 when the model's
##   vslot 0x34 is non-zero. INFERRED to mean "a woman" twice over: 0xec6528
##   is the only table naming group 37, `Bone01`, which only the two women's
##   skeletons have (MEASURED: chinawoman_skel and europewoman_skel hold
##   Bone01/Bone02, chinaman_skel and europeman_skel do not), and the same
##   vslot picks the harp's `_f.bsr` model (CObjCharacter 0xa5f4f0). The sex
##   itself comes from the body's characterdata column 58 (CharCatalog).
##
## **What is worn (READ):** the select screen (`PSCharacterSelect` 0x85a580)
## gives each of the up-to-9 equipped items its visual slot
## (`GlobalDataManager::ResolveVisualSlotForItem` 0x9db5e0, visual_slot below)
## and installs it with its plus; one visual per slot, a later item replacing
## an earlier (`InstallEquipVisual` 0xa61010). Slots 9..11 (earring, necklace,
## ring) have no mesh. Avatars (TypeID3 13) are attached on top
## (`FUN_00a60ef0`); whether an avatar hides the armour under it is OPEN.
## Weapons whose TypeID4 is 9 (dual axe) or 13 (dagger) are drawn from the
## model path's `_l.bsr` and `_r.bsr`, and the harp (14) on a woman from
## `_f.bsr` (READ, `CObjCharacter::FUN_00a5f4f0`); each `.bsr` names the bone
## it hangs from (SkinnedBsrAssembler.attach_item_from_archive).
##
## **Plus** is kept on the body (Body.worn) for the weapon glow; the glow
## itself is not drawn (INFERRED in charselect.md that plus drives it; OPEN).
##
## **Caching (OURS):** each body is assembled once into a detached template
## and each item once per skeleton layout; a build duplicates them, so meshes,
## textures and materials are shared between every character built here. The
## skins are copied per character so Volume stays per character. A caller that
## wants one character translucent (a pending deletion's 0xcc) must use the
## instance's GeometryInstance3D.transparency, not the shared materials.
## free_templates() releases the cache.

## READ, table 0xec64b0.
const HEIGHT_FACTORS := [0.94, 0.97, 1.00, 1.03, 1.06]
## READ, table 0xec64c8: {group, min, max}. Men's (INFERRED, see above).
const VOLUME_TABLE_MEN := [
	[2, 0.88, 1.10], [3, 0.95, 1.11], [8, 0.92, 1.20], [19, 0.92, 1.20],
	[29, 0.90, 1.15], [33, 0.90, 1.15], [1, 0.90, 1.00],
]
## READ, table 0xec6528. Women's (INFERRED, see above).
const VOLUME_TABLE_WOMEN := [
	[2, 0.95, 1.10], [3, 0.95, 1.00], [8, 0.95, 1.15], [19, 0.95, 1.15],
	[29, 0.90, 1.15], [33, 0.90, 1.15], [1, 0.90, 1.08], [37, 0.80, 1.18],
]
## READ: the 38 names `FUN_00d79e00` assigns to the strings at 0xed9b68 +
## i * 0x1c, in order; a Volume group number indexes it (0xc2ca90 refuses 38
## and above, and 38 = '&' ends each table).
const BONE_GROUP_NAMES := [
	"Bip01", "Bip01 Pelvis", "Bip01 Spine", "Bip01 Spine1", "Bip01 Neck",
	"Bip01 Neck1", "Bip01 Head", "Bip01 L Clavicle", "Bip01 L UpperArm",
	"Bip01 L Forearm", "Bip01 L Hand", "Bip01 L Finger0", "Bip01 L Finger01",
	"Bip01 L Finger1", "Bip01 L Finger11", "Bip01 L Finger2", "Bip01 L Finger21",
	"Bip01 L HandMid", "Bip01 R Clavicle", "Bip01 R UpperArm", "Bip01 R Forearm",
	"Bip01 R Hand", "Bip01 R Finger0", "Bip01 R Finger01", "Bip01 R Finger1",
	"Bip01 R Finger11", "Bip01 R Finger2", "Bip01 R Finger21", "Bip01 R HandMid",
	"Bip01 L Thigh", "Bip01 L Calf", "Bip01 L Foot", "Bip01 L Toe0",
	"Bip01 R Thigh", "Bip01 R Calf", "Bip01 R Foot", "Bip01 R Toe0", "Bone01",
]
const DEFAULT_SCALE := 0x22

## A held weapon's TypeID4 -> the body's animation group. The same table as
## World3D.WEAPON_ANIMATION_GROUP (round 318, READ); character_appearance_test
## holds the two equal so they cannot drift.
const WEAPON_ANIMATION_GROUP := {
	2: "sword", 3: "sword",
	4: "spear", 5: "spear",
	6: "bow", 12: "bow",
	7: "onehand_sword",
	8: "twohand_sword",
	9: "dual_axe",
	10: "onehand_staff", 15: "onehand_staff",
	11: "twohand_staff",
	13: "dagger",
	14: "harf",
	16: "sword",
}

## Visual slots (READ, ResolveVisualSlotForItem 0x9db5e0). 0..8 draw a mesh.
const SLOT_HEAD := 0
const SLOT_CHEST := 1
const SLOT_SHOULDER := 2
const SLOT_HANDS := 3
const SLOT_LEGS := 4
const SLOT_FEET := 5
const SLOT_WEAPON := 6
const SLOT_SHIELD := 7
const SLOT_SUIT := 8
const SLOT_EARRING := 9
const SLOT_NECKLACE := 10
const SLOT_RING := 11
## Not a client slot: an avatar item, attached on top (FUN_00a60ef0).
const SLOT_AVATAR := 100

## One built character. Its child is the body's Skeleton3D; it faces its own
## local -Z, as every assembled body does (World3D turns its player's by PI).
class Body extends Node3D:
	var skeleton: Skeleton3D
	var ref_obj_id: int = 0
	var scale_byte: int = DEFAULT_SCALE
	## From the body's characterdata column 58 through CharCatalog; false (the men's
	## Volume table) for a body the catalogue does not hold.
	var is_woman: bool = false
	## The held weapon's TypeID4 (0 for none) and the animation group it picks.
	var weapon_kind: int = 0
	var weapon_group: String = "default"
	## What was put on, in install order: {id, plus, slot, models: [paths], nodes: [Node3D]}.
	var worn: Array = []
	## The body's assembled template (shared): its parsed `.bsr` names the animations.
	var assembled: SkinnedBsrAssembler.AssembledCharacter
	## Height's factor as applied (Body.scale is this, uniformly).
	var height_factor: float = 1.0
	## Volume's factor per bone name as applied (empty when neutral).
	var volume_scales: Dictionary = {}

	## Re-applies Height and Volume without rebuilding (a customize slider).
	func set_scale_byte(scale: int) -> void:
		CharacterAppearance.apply_scale(self, scale)

	## Poses the skeleton `seconds` into `anim` on its own clock (a hook for
	## the screens' idles; which clip each screen plays is theirs to pick).
	func pose(anim: BanReader.ParsedAnimation, seconds: float, loop: bool = true) -> void:
		if anim != null and skeleton != null:
			Skeleton3DBuilder.apply_ban_pose_at(skeleton, anim, seconds, loop)

var _data: Pk2Reader
var _media: Pk2Reader
var _catalog: CharCatalog
## item id -> {"models": PackedStringArray, "type_ids": PackedInt32Array}, filled
## from the catalogue and, on the first id it lacks, the full item table.
var _items: Dictionary = {}
var _full_items_loaded := false
## ref_obj_id -> body .bsr path for ids the catalogue does not hold.
var _extra_bodies: Dictionary = {}
var _body_templates: Dictionary = {}  # bsr path -> AssembledCharacter (detached)
var _item_templates: Dictionary = {}  # "skeleton|bones|item path" -> Node3D (detached) or null
## Timings, microseconds: the last build, and the running totals.
var last_build_usec: int = 0
var stats := {"builds": 0, "body_assemblies": 0, "item_assemblies": 0, "build_usec": 0}

## An appearance over the player's archives. `items`, when given, is a table
## already parsed (item id -> ItemTableReader.Item, World3D's `_item_rows`), so
## the world does not parse it twice.
static func from_archives(data_pk2: Pk2Reader, media_pk2: Pk2Reader, items: Dictionary = {}) -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a._data = data_pk2
	a._media = media_pk2
	a._catalog = CharCatalog.from_archive(media_pk2)
	for id in a._catalog.entries:
		var e: CharCatalog.Entry = a._catalog.entries[id]
		if not e.is_body:
			a._items[id] = {"models": PackedStringArray([e.model_path]) if e.model_path != "" else PackedStringArray(), "type_ids": e.type_ids}
	if not items.is_empty():
		a.add_item_rows(items)
	return a

## The catalogue this appearance resolves bodies through.
func catalog() -> CharCatalog:
	return _catalog

## Adds item rows (id -> ItemTableReader.Item) so build() can resolve them.
func add_item_rows(rows: Dictionary) -> void:
	for id in rows:
		var item: ItemTableReader.Item = rows[id]
		_items[int(id)] = {"models": item.model_paths, "type_ids": item.type_ids}
	_full_items_loaded = true

## A body for an id the catalogue does not hold (an NPC body, a test).
func add_body(ref_obj_id: int, bsr_path: String) -> void:
	_extra_bodies[ref_obj_id] = bsr_path

# --- the scale byte -----------------------------------------------------------

## Height's index from the scale byte (READ 0xa5b960): the low nibble, 0 if above 4.
static func height_index(scale: int) -> int:
	var h := scale & 0x0f
	return 0 if h > 4 else h

## Volume's level from the scale byte (READ 0xa5b960 then 0xa5b7e0): the high
## nibble, 0 if above 7, then clamped to 0..4.
static func volume_level(scale: int) -> int:
	var v := (scale >> 4) & 0x0f
	if v > 7:
		v = 0
	return clampi(v, 0, 4)

static func height_factor(scale: int) -> float:
	if scale == 0xff:
		return 1.0
	return float(HEIGHT_FACTORS[height_index(scale)])

## One group's factor at a Volume level (READ 0xa5b7e0).
static func volume_factor(level: float, min_f: float, max_f: float) -> float:
	if level >= 2.0:
		return 1.0 + (max_f - 1.0) * (level - 2.0) * 0.5
	return min_f + (1.0 - min_f) * level * 0.5

## Bone name -> Volume factor for a scale byte and sex; empty at 0xFF.
static func volume_bone_scales(scale: int, woman: bool) -> Dictionary:
	var out := {}
	if scale == 0xff:
		return out
	var level := float(volume_level(scale))
	for row in (VOLUME_TABLE_WOMEN if woman else VOLUME_TABLE_MEN):
		var group: int = row[0]
		if group < 0 or group >= BONE_GROUP_NAMES.size():
			continue
		out[BONE_GROUP_NAMES[group]] = volume_factor(level, float(row[1]), float(row[2]))
	return out

## Applies a scale byte to a built body: Height to the node's uniform scale,
## Volume to the bind poses of every skin bound to the body's skeleton.
static func apply_scale(body: Body, scale: int) -> void:
	body.scale_byte = scale
	body.height_factor = height_factor(scale)
	body.scale = Vector3.ONE * body.height_factor
	body.volume_scales = volume_bone_scales(scale, body.is_woman)
	apply_volume(body.skeleton, body.volume_scales)

## Sets every bind of every skin bound to `skeleton` to its bone's rest
## inverse, pre-multiplied by `scale(1, f, f)` for a bone in `scales` (the
## bone's own Y and Z, READ RTSkeleton::FUN_00c4a180). A bone not in `scales`
## gets its plain bind back, so this can be re-applied.
static func apply_volume(skeleton: Skeleton3D, scales: Dictionary) -> void:
	if skeleton == null:
		return
	for mi in _skinned_to(skeleton):
		var skin: Skin = mi.skin
		for i in range(skin.get_bind_count()):
			var bone := skin.get_bind_bone(i)
			if bone < 0 or bone >= skeleton.get_bone_count():
				continue
			var bind := skeleton.get_bone_global_rest(bone).affine_inverse()
			var f: float = float(scales.get(skeleton.get_bone_name(bone), 1.0))
			if f != 1.0:
				bind = Transform3D(Basis.from_scale(Vector3(1.0, f, f)), Vector3.ZERO) * bind
			skin.set_bind_pose(i, bind)

## Every MeshInstance3D under `skeleton` skinned to it (not to an item's own
## skeleton hung from one of its bones).
static func _skinned_to(skeleton: Skeleton3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [skeleton]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.skin == null:
			continue
		var target := mi.get_node_or_null(mi.skeleton)
		if target == skeleton:
			out.append(mi)
	return out

# --- worn items -----------------------------------------------------------------

## The visual slot of an item by its TypeID1..4 (READ, ResolveVisualSlotForItem
## 0x9db5e0), or -1 when it draws no mesh. The function's shield test is its
## `IsShieldItem` helper, taken here as TypeID3 4 (INFERRED: both catalogue
## shields are 3/1/4/x, MEASURED); earrings, necklaces and rings (its slots
## 9..11) draw nothing and read -1. SLOT_AVATAR for TypeID3 13 (READ, the
## select screen's 0x680 test).
static func visual_slot(type_ids: PackedInt32Array) -> int:
	if type_ids.size() < 4 or type_ids[0] != 3 or type_ids[1] != 1:
		return -1
	var t3 := type_ids[2]
	var t4 := type_ids[3]
	if t3 in [1, 2, 3, 9, 10, 11]:
		match t4:
			1: return SLOT_HEAD
			2: return SLOT_SHOULDER
			3: return SLOT_CHEST
			4: return SLOT_LEGS
			5: return SLOT_HANDS
			6: return SLOT_FEET
	if t3 == 6:
		return SLOT_WEAPON
	if t3 == 4:
		return SLOT_SHIELD
	if t3 == 7:
		return SLOT_SUIT
	if t3 == 13:
		return SLOT_AVATAR
	return -1

## The models an item is drawn from on a body (READ CObjCharacter 0xa5f4f0):
## a dual axe or dagger from `<path>_l.bsr` and `<path>_r.bsr`, a harp on a
## woman from `<path>_f.bsr`, anything else from its own path.
static func item_models(model_path: String, type_ids: PackedInt32Array, woman: bool) -> PackedStringArray:
	if model_path == "":
		return PackedStringArray()
	var weapon := type_ids.size() >= 4 and type_ids[0] == 3 and type_ids[1] == 1 and type_ids[2] == 6
	var base := model_path.substr(0, model_path.length() - 4) if model_path.to_lower().ends_with(".bsr") else model_path
	if weapon and (type_ids[3] == 9 or type_ids[3] == 13):
		return PackedStringArray([base + "_l.bsr", base + "_r.bsr"])
	if weapon and type_ids[3] == 14 and woman:
		return PackedStringArray([base + "_f.bsr"])
	return PackedStringArray([model_path])

# --- building -------------------------------------------------------------------

## Builds the character. `items` is the lobby record's equipped items and
## avatars, each {"id": RefItemID, "plus": u8} (a bare int is read as plus 0).
## Returns null when the body cannot be assembled (no archive, an unknown id).
func build(ref_obj_id: int, scale: int = DEFAULT_SCALE, items: Array = []) -> Body:
	var t0 := Time.get_ticks_usec()
	var bsr_path := body_path(ref_obj_id)
	if bsr_path == "":
		return null
	var tmpl := _body_template(bsr_path)
	if tmpl == null:
		return null
	var body := Body.new()
	body.name = "Character_%d" % ref_obj_id
	body.ref_obj_id = ref_obj_id
	body.assembled = tmpl
	var e := _catalog.get_entry(ref_obj_id) if _catalog != null else null
	body.is_woman = e != null and e.sex == CharCatalog.SEX_WOMAN
	var skel := tmpl.skeleton.duplicate() as Skeleton3D
	skel.name = "Skeleton"
	body.skeleton = skel
	body.add_child(skel)

	# One visual per slot, the later replacing the earlier; avatars on top.
	var by_slot := {}
	var avatars: Array = []
	for raw in items:
		var id := int(raw["id"]) if raw is Dictionary else int(raw)
		var plus := int(raw.get("plus", 0)) if raw is Dictionary else 0
		if id == 0:
			continue
		var info := _item_info(id)
		if info.is_empty():
			push_warning("CharacterAppearance: item %d is in no item table -- not drawn" % id)
			continue
		var slot := visual_slot(info["type_ids"])
		if slot < 0 or (slot > SLOT_SUIT and slot != SLOT_AVATAR):
			continue
		var models: PackedStringArray = info["models"]
		var wear := {"id": id, "plus": plus, "slot": slot,
			"models": item_models(models[0] if not models.is_empty() else "", info["type_ids"], body.is_woman),
			"nodes": []}
		if slot == SLOT_AVATAR:
			avatars.append(wear)
		else:
			by_slot[slot] = wear
		if slot == SLOT_WEAPON:
			body.weapon_kind = (info["type_ids"] as PackedInt32Array)[3]
	body.weapon_group = WEAPON_ANIMATION_GROUP.get(body.weapon_kind, "default")
	var order: Array = by_slot.keys()
	order.sort()
	var wears: Array = []
	for slot in order:
		wears.append(by_slot[slot])
	wears.append_array(avatars)
	for wear in wears:
		for path in wear["models"]:
			var node := _item_instance(bsr_path, tmpl, skel, path)
			if node != null:
				(wear["nodes"] as Array).append(node)
		body.worn.append(wear)

	_own_skins(skel)
	apply_scale(body, scale)
	last_build_usec = Time.get_ticks_usec() - t0
	stats["builds"] += 1
	stats["build_usec"] += last_build_usec
	return body

## The animation `action_type` (BsrReader.AnimationEntry.TYPE_*) of the body's
## own `.bsr`, in the group its weapon picks (falling back to `default`), parsed
## once and shared. Null when the body names none.
func animation_for(body: Body, action_type: int) -> BanReader.ParsedAnimation:
	if body == null or body.assembled == null:
		return null
	return SkinnedBsrAssembler.animation_for(_data, body.assembled, action_type, body.weapon_group)

## The body `.bsr` a model id is drawn from, "" when unknown.
func body_path(ref_obj_id: int) -> String:
	var e := _catalog.get_entry(ref_obj_id) if _catalog != null else null
	if e != null and e.is_body and e.model_path != "":
		return e.model_path
	return String(_extra_bodies.get(ref_obj_id, ""))

## Frees the cached templates (a screen closing).
func free_templates() -> void:
	for path in _body_templates:
		var t: SkinnedBsrAssembler.AssembledCharacter = _body_templates[path]
		if t != null and is_instance_valid(t.skeleton):
			t.skeleton.free()
	_body_templates.clear()
	for key in _item_templates:
		var n: Node = _item_templates[key]
		if n != null and is_instance_valid(n):
			n.free()
	_item_templates.clear()

func _body_template(bsr_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	if _body_templates.has(bsr_path):
		return _body_templates[bsr_path]
	if _data == null:
		return null
	var t := SkinnedBsrAssembler.assemble_from_archive(_data, bsr_path, false)
	stats["body_assemblies"] += 1
	_body_templates[bsr_path] = t
	return t

## A fresh copy of `item_path` hung on `skel`, from a template built once per
## skeleton layout: the item is attached to a scratch copy of the body, lifted
## off, and kept. Its skins name bones by index, so a template is only reused
## on a skeleton of the same file and the same bone count.
func _item_instance(body_bsr: String, tmpl: SkinnedBsrAssembler.AssembledCharacter, skel: Skeleton3D, item_path: String) -> Node3D:
	var layout := "%s|%d" % [tmpl.parsed.skeleton_path if tmpl.parsed != null else body_bsr, skel.get_bone_count()]
	var key := "%s|%s" % [layout, item_path.to_lower()]
	if not _item_templates.has(key):
		_item_templates[key] = _make_item_template(tmpl, item_path) if _data != null else null
	var t: Node3D = _item_templates[key]
	if t == null:
		return null
	var needed: int = int(t.get_meta("bone_count", skel.get_bone_count()))
	if needed > skel.get_bone_count():
		# The item's own palette entry 0 added the object-space bone on the
		# scratch copy (Skeleton3DBuilder.build_skin); add it here at the
		# same index.
		if skel.find_bone(Skeleton3DBuilder.OBJECT_SPACE_BONE) == -1 and needed == skel.get_bone_count() + 1:
			var idx := skel.get_bone_count()
			skel.add_bone(Skeleton3DBuilder.OBJECT_SPACE_BONE)
			skel.set_bone_rest(idx, Transform3D.IDENTITY)
			skel.reset_bone_pose(idx)
		else:
			push_warning("CharacterAppearance: %s needs %d bones, the body has %d -- not drawn" % [item_path, needed, skel.get_bone_count()])
			return null
	var node := t.duplicate() as Node3D
	skel.add_child(node)
	return node

func _make_item_template(tmpl: SkinnedBsrAssembler.AssembledCharacter, item_path: String) -> Node3D:
	var scratch := tmpl.skeleton.duplicate() as Skeleton3D
	# The client's rule for a palette bone the body lacks (READ, see
	# Skeleton3DBuilder.build_skin): the Europe man's heavy legs need it.
	var attached := SkinnedBsrAssembler.attach_item_from_archive(_data, scratch, item_path, true)
	stats["item_assemblies"] += 1
	var node: Node3D = null
	if attached != null and attached.node != null:
		node = attached.node
		scratch.remove_child(node)
		node.set_meta("bone_count", scratch.get_bone_count())
	scratch.free()
	return node

## Gives every skinned mesh on the body its own copy of its skin, so Volume
## (a bind pose edit) stays on this character. A mesh and its front-pass twin
## (ObjectLoader.add_front_pass) share one skin and keep sharing the copy.
static func _own_skins(skel: Skeleton3D) -> void:
	var copies := {}
	var stack: Array[Node] = [skel]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.skin == null:
			continue
		if not copies.has(mi.skin):
			copies[mi.skin] = mi.skin.duplicate()
		mi.skin = copies[mi.skin]

func _item_info(id: int) -> Dictionary:
	if _items.has(id):
		return _items[id]
	if not _full_items_loaded and _media != null:
		_full_items_loaded = true
		for path in ItemTableReader.TABLE_PATHS:
			var entry := ObjectLoader.find_file(_media, path)
			if entry == null:
				continue
			var rows := ItemTableReader.parse(_media.read_file(entry))
			for rid in rows:
				if not _items.has(int(rid)):
					var item: ItemTableReader.Item = rows[rid]
					_items[int(rid)] = {"models": item.model_paths, "type_ids": item.type_ids}
	return _items.get(id, {})
