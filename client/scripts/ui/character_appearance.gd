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
##   is the only table naming group 37, `Bone01`, which only the women's
##   skeleton has (MEASURED: all 52 Figures name europeman_skel.bsk or
##   europewoman_skel.bsk, China bodies too; europewoman_skel holds
##   Bone01/Bone02, europeman_skel does not), and the same
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
## **The body's own pieces under worn items (round 687, READ):** every body
## and item `.bsr` ends with an attachable block (BsrReader.Attachable). The
## body's maps each piece key (0 hair, 1 face, 2/3 torso, 5/6 arms, 11
## pelvis, 12 thigh, 13 calf -- MEASURED) to one of its meshes; an item's lists
## the keys it covers, and when its flag is 1 the client switches those body
## meshes off (`CCompChar::FUN_00c1f790`). Taking a part off shows every body
## mesh again and re-applies the hides of what is left (`FUN_00c1f890`).
## build() and unequip() do the same (apply_hides, through
## SkinnedBsrAssembler.apply_body_hides). Default wear (`clothes_00_*`) and
## avatars carry blocks too and hide as their flag says; a light gauntlet's
## flag is 2, so it hides nothing (MEASURED).
##
## **Plus** drives the weapon and shield glow (round 734, EquipGlow): the
## select screen installs each item with its plus (READ, PSCharacterSelect
## 0x85a580 -> InstallEquipVisual(slot, id, plus, 0)), and the weapon and
## shield (`FUN_00a60a90`'s kind-1 attachments) get the glow row and the
## particle rows of their code name at that plus (ItemGlowTables). The
## tables come from Media.pk2 and the effects from Particles.pk2; with
## either missing that part is not drawn.
##
## **Caching (OURS):** each body is assembled once into a detached template
## and each item once per skeleton layout; a build duplicates them, so meshes,
## textures and materials are shared between every character built here. A
## caller that wants one character translucent (a pending deletion's 0xcc)
## must use the instance's GeometryInstance3D.transparency, not the shared
## materials. free_templates() releases the cache.
##
## **One skin per body (round 738, A2; OURS).** Every piece skinned to the
## body's skeleton -- the body's own and the worn ones weighted onto it --
## shares one Skin naming every bone (Skeleton3DBuilder.canonical_skin), its
## vertices remapped from their palette to the skeleton's bones at template
## time; the matrices, and so the vertices, are the ones the per-piece skins
## gave. Godot writes every registered skin on each pose, so a body wrote 14
## and writes 1. Volume is a variant of that skin per scale (volume_skin),
## shared by every body of the same skeleton and Volume, instead of a copy of
## every skin per body. `canonical` false (QA: OPENSRO_QA_CROWD_SKINS=own)
## builds the old way, a skin per piece copied per body. An item with its own
## skeleton (a weapon, a shoulder piece) keeps its own skins, shared between
## bodies: that skeleton is never posed.
##
## Each body's skeleton also carries MonsterCrowd.META_LAYOUT, its skeleton
## file and bone count, so the world's clip tick finds a clip's bone indices
## once per layout (CrowdAnim, round 738). That reaches every body built here:
## other players, and also the character window's doll, which the world's
## clip tick poses through MonsterCrowd.pose_at's indexed path (round 738's
## review, F4: the same values, the bone globals left to the end-of-frame
## update). The local player carries it too but is posed by its own tick
## (apply_ban_pose_at), and the screens pose theirs through Body.pose.

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

## A held weapon's TypeID4 -> the body's animation group: BodyAnimations
## (round 689; READ FUN_00a5a7d0, the fortress weapon by race), the one table
## the world and the screens share.

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
	## What was put on, in install order: {id, plus, slot, models: [paths],
	## nodes: [Node3D], drawn: [paths], attachables: [BsrReader.Attachable or
	## null, one per drawn path]}.
	var worn: Array = []
	## How many body meshes the worn items hide now (apply_hides); a mesh's
	## front-pass twin is not counted again.
	var hidden_body_meshes: int = 0
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
## Round 738: the shared skin of each skeleton layout ("skeleton path|bone
## count" -> Skin): see share_template.
var _canonical_by_layout: Dictionary = {}
## item path (lower case) -> its BsrReader.Attachable, or null when its block
## did not parse; filled as the item templates are made.
var _item_attachables: Dictionary = {}
## Round 685's review: the default wear table (charactervisualchange.txt),
## and CGame+0x129 -- the per-server flag that takes it off (READ 0xa5e010).
## OURS: false, the flag the customize screen's Protector minimum assumes.
var default_wear: DefaultWear = null
var default_wear_flag := false
## Round 734: the glow tables (null: no glow drawn) and the Particles.pk2 the
## glow's effects come from -- opened from Pk2Config on the first item that
## needs one when nobody handed one over. `glow_enabled` false draws neither.
var glow_tables: ItemGlowTables = null
var particles: Pk2Reader = null
var glow_enabled := true
var _particles_tried := false
## Round 738 (A2): one shared skin per body skeleton (see the header). QA:
## OPENSRO_QA_CROWD_SKINS=own turns it off for an A/B.
var canonical := OS.get_environment("OPENSRO_QA_CROWD_SKINS") != "own"
## Timings, microseconds: the last build, and the running totals.
var last_build_usec: int = 0
var stats := {"builds": 0, "body_assemblies": 0, "item_assemblies": 0, "build_usec": 0, "item_table_usec": 0, "item_table_rows": 0}

## The cached templates are detached nodes, which a RefCounted's death would
## otherwise leak; they go with it.
## (Inline, not through free_templates(): a RefCounted's script methods cannot
## be called while it is being deleted -- MEASURED, the call errors with "base
## 'null instance'".)
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# A template task holds this object through its Callable, so none runs
	# by now; whatever finished unadopted is freed here (round 748).
	for path in _prep_done:
		_free_prepared(_prep_done[path])
	_prep_done.clear()
	for q in _prep_queue:
		if q[1] != null and is_instance_valid(q[1]):
			(q[1] as Node).free()
	_prep_queue.clear()
	for path in _body_templates:
		var t: SkinnedBsrAssembler.AssembledCharacter = _body_templates[path]
		if t != null and is_instance_valid(t.skeleton):
			t.skeleton.free()
	for key in _item_templates:
		var n = _item_templates[key]
		if n != null and is_instance_valid(n):
			(n as Node).free()
	_canonical_by_layout.clear()

## An appearance over the player's archives. `items`, when given, is a table
## already parsed (item id -> ItemTableReader.Item, World3D's `_item_rows`), so
## the world does not parse it twice.
static func from_archives(data_pk2: Pk2Reader, media_pk2: Pk2Reader, items: Dictionary = {}) -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a._data = data_pk2
	a._media = media_pk2
	a._catalog = CharCatalog.from_archive(media_pk2)
	a.default_wear = DefaultWear.from_archive(media_pk2)
	for id in a._catalog.entries:
		var e: CharCatalog.Entry = a._catalog.entries[id]
		if not e.is_body:
			a._items[id] = {"models": PackedStringArray([e.model_path]) if e.model_path != "" else PackedStringArray(), "type_ids": e.type_ids, "code": e.code}
	# The glow tables first: add_item_rows hands them the rows to inherit
	# through (round 740).
	a.glow_tables = ItemGlowTables.for_archive(media_pk2)
	if not items.is_empty():
		a.add_item_rows(items)
	return a

## An appearance over a catalogue already built (round 689: the world builds
## its bodies-only catalogue from the characterdata parts it reads anyway, and
## hands its parsed item table), so nothing is parsed twice.
static func from_catalog(data_pk2: Pk2Reader, media_pk2: Pk2Reader, catalog: CharCatalog, items: Dictionary = {}) -> CharacterAppearance:
	var a := CharacterAppearance.new()
	a._data = data_pk2
	a._media = media_pk2
	a._catalog = catalog
	a.default_wear = DefaultWear.from_archive(media_pk2) if media_pk2 != null else null
	# The glow tables first: add_item_rows hands them the rows to inherit
	# through (round 740).
	a.glow_tables = ItemGlowTables.for_archive(media_pk2)
	if not items.is_empty():
		a.add_item_rows(items)
	return a

## The catalogue this appearance resolves bodies through.
func catalog() -> CharCatalog:
	return _catalog

## The body's assembled template (shared, detached): its parsed `.bsr` names
## the body's animations (BodyAnimations), its skeleton the bones. Null for an
## unknown id.
func template_for(ref_obj_id: int) -> SkinnedBsrAssembler.AssembledCharacter:
	var path := body_path(ref_obj_id)
	return _body_template(path) if path != "" else null

## Whether the body is a woman's (characterdata column 58 through the
## catalogue); false for an id the catalogue does not hold.
func is_woman(ref_obj_id: int) -> bool:
	var e := _catalog.get_entry(ref_obj_id) if _catalog != null else null
	return e != null and e.sex == CharCatalog.SEX_WOMAN

## The body's race (0 China, 1 Europe) by the catalogue's Country, else by its
## `.bsr` path, as body_race.
func race_of(ref_obj_id: int) -> int:
	var e := _catalog.get_entry(ref_obj_id) if _catalog != null else null
	if e != null and e.is_body:
		return e.race
	return CharCatalog.RACE_EUROPE if body_path(ref_obj_id).to_lower().contains("europe") else CharCatalog.RACE_CHINA

## Adds item rows (id -> ItemTableReader.Item) so build() can resolve them.
func add_item_rows(rows: Dictionary) -> void:
	for id in rows:
		var item: ItemTableReader.Item = rows[id]
		_items[int(id)] = {"models": item.model_paths, "type_ids": item.type_ids, "code": item.code_name}
	_full_items_loaded = true
	_inherit_glow(rows)

## The glow tables' OrgObjCodeName inheritance over item rows this appearance
## was given or parsed (round 740, ItemGlowTables.inherit).
func _inherit_glow(rows: Dictionary) -> void:
	if glow_tables != null:
		glow_tables.inherit(rows)

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
	# 0xFF is stored and changes nothing (READ 0xa5b960): the body keeps the
	# Height and Volume it had.
	if scale == 0xff:
		return
	body.height_factor = height_factor(scale)
	body.scale = Vector3.ONE * body.height_factor
	body.volume_scales = volume_bone_scales(scale, body.is_woman)
	apply_volume(body.skeleton, body.volume_scales)

## Sets every bind of every skin bound to `skeleton` to its bone's rest
## inverse, pre-multiplied by `scale(1, f, f)` for a bone in `scales` (the
## bone's own Y and Z, READ RTSkeleton::FUN_00c4a180). A bone not in `scales`
## gets its plain bind back, so this can be re-applied. A piece on the
## body's shared skin (round 738) is given the shared variant for `scales`
## (volume_skin) instead of an edit.
static func apply_volume(skeleton: Skeleton3D, scales: Dictionary) -> void:
	if skeleton == null:
		return
	for mi in _skinned_to(skeleton):
		var skin: Skin = mi.skin
		var base := canonical_base(skin)
		if base != null:
			var want := volume_skin(base, skeleton, scales)
			if mi.skin != want:
				mi.skin = want
			continue
		for i in range(skin.get_bind_count()):
			var bone := skin.get_bind_bone(i)
			if bone < 0 or bone >= skeleton.get_bone_count():
				continue
			var bind := skeleton.get_bone_global_rest(bone).affine_inverse()
			var f: float = float(scales.get(skeleton.get_bone_name(bone), 1.0))
			if f != 1.0:
				bind = Transform3D(Basis.from_scale(Vector3(1.0, f, f)), Vector3.ZERO) * bind
			skin.set_bind_pose(i, bind)

## Meta on a body's shared skin (Skeleton3DBuilder.canonical_skin, round
## 738): its Volume variants, scale signature -> WeakRef to the Skin. And on a
## variant: the shared skin it was made from. Only the variant holds its base:
## the base's references to its variants are weak, so the two make no cycle
## and go when no mesh wears them (round 738's review, F3).
const VOLUME_VARIANTS_META := "opensro_volume_variants"
const VOLUME_BASE_META := "opensro_volume_base"

## The shared skin `skin` is, or was made from; null for a per-piece skin.
static func canonical_base(skin: Skin) -> Skin:
	if skin == null:
		return null
	if skin.has_meta(VOLUME_BASE_META):
		return skin.get_meta(VOLUME_BASE_META)
	if skin.has_meta(VOLUME_VARIANTS_META):
		return skin
	return null

## Marks a body template's shared skin, so apply_volume knows it.
static func _mark_canonical(skin: Skin) -> void:
	if skin != null and not skin.has_meta(VOLUME_VARIANTS_META):
		skin.set_meta(VOLUME_VARIANTS_META, {})

## What a new body template shares with the ones before it (round 738): its
## shared skin, per skeleton layout. Worn items are made once per layout
## (_item_instance), on whichever body of that layout wore them first, so a
## body wearing them must be on that same Skin object -- two objects with
## equal binds are two skins to the skeleton. The 52 Figures name two
## skeleton files (MEASURED, round 683), so this is a handful of skins.
##
## Its clips are NOT shared (round 738's review, F1): a clip carries the entry
## its body found it as (BsrReader.CLIP_META), which AnimSounds looks the
## body's own sound set up by, and one file is a different entry in different
## Figures' `.bsr` (the review counted 169 body pairs that hear differently).
## What is shared is the baked poses, by file path and layout
## (CrowdAnim.frames_for, SkinnedBsrAssembler.CLIP_PATH_META).
static func share_template(t: SkinnedBsrAssembler.AssembledCharacter, by_layout: Dictionary) -> void:
	if t == null:
		return
	if t.canonical_skin == null or t.skeleton == null:
		return
	var key := "%s|%d" % [t.parsed.skeleton_path if t.parsed != null else "", t.skeleton.get_bone_count()]
	var shared: Skin = by_layout.get(key)
	if shared == null:
		_mark_canonical(t.canonical_skin)
		by_layout[key] = t.canonical_skin
		return
	for mi in _skinned_to(t.skeleton):
		if mi.skin == t.canonical_skin:
			mi.skin = shared
	t.canonical_skin = shared

## The shared skin `base` with Volume `scales` applied as apply_volume
## applies it (each bind of a bone in `scales` pre-multiplied by
## `scale(1, f, f)`), made once per signature and kept on `base`; `base`
## itself when no factor differs from 1.
static func volume_skin(base: Skin, skeleton: Skeleton3D, scales: Dictionary) -> Skin:
	var parts := PackedStringArray()
	var names := scales.keys()
	names.sort()
	for name in names:
		var f: float = float(scales[name])
		if f != 1.0 and skeleton.find_bone(String(name)) != -1:
			parts.append("%s=%.6f" % [name, f])
	if parts.is_empty():
		return base
	var key := ";".join(parts)
	var variants: Dictionary = base.get_meta(VOLUME_VARIANTS_META, {})
	var held = variants.get(key)
	if held != null:
		var got = (held as WeakRef).get_ref()
		if got != null:
			return got
	var skin := base.duplicate() as Skin
	for i in range(skin.get_bind_count()):
		var bone := skin.get_bind_bone(i)
		if bone < 0 or bone >= skeleton.get_bone_count():
			continue
		var f: float = float(scales.get(skeleton.get_bone_name(bone), 1.0))
		if f != 1.0:
			skin.set_bind_pose(i, Transform3D(Basis.from_scale(Vector3(1.0, f, f)), Vector3.ZERO) * skeleton.get_bone_global_rest(bone).affine_inverse())
	skin.set_meta(VOLUME_BASE_META, base)
	if skin.has_meta(VOLUME_VARIANTS_META):
		skin.remove_meta(VOLUME_VARIANTS_META)
	variants[key] = weakref(skin)
	base.set_meta(VOLUME_VARIANTS_META, variants)
	return skin

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
## 0x9db5e0, with its `IsShieldItem` 0x56fab0: TypeID 3/1/4 and TypeID4 1 or
## 2), or -1 when it draws no mesh: earrings, necklaces and rings (its slots
## 9..11) draw nothing. SLOT_AVATAR for TypeID3 13 (READ, the select screen's
## 0x680 test).
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
	if t3 == 4 and (t4 == 1 or t4 == 2):
		return SLOT_SHIELD
	if t3 == 7:
		return SLOT_SUIT
	if t3 == 13:
		return SLOT_AVATAR
	return -1

## The models an item is drawn from on a body (READ CObjCharacter 0xa5f4f0):
## a dual axe or dagger from `<path>_l.bsr` and `<path>_r.bsr`, a harp on a
## woman from `<path>_f.bsr`, anything else from its own path. When the `_r`
## or `_f` resource does not load the client loads the plain path instead
## (0xa5f4f0 -> LAB_00a5f851); build() does the same (_FALLBACK_SUFFIXES).
## The client's second-resource branch for a visual record that names its own
## `.bsr` (the record from 0x4ec9b0, charactervisualchange.txt's BsrName
## columns) is not modelled: OPEN.
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
	var resolved := _resolve_wears(items, body.is_woman, true)
	var wears: Array = resolved[0]
	body.weapon_kind = int(resolved[1])
	body.weapon_group = BodyAnimations.group_for_weapon(body.weapon_kind, body_race(body))
	for wear in wears:
		var drawn := PackedStringArray()
		var blocks: Array = []
		for path in wear["models"]:
			var node := _item_instance(bsr_path, tmpl, skel, path)
			if node == null and _fallback_of(path) != "":
				path = _fallback_of(path)
				node = _item_instance(bsr_path, tmpl, skel, path)
			if node != null:
				(wear["nodes"] as Array).append(node)
				drawn.append(path)
				blocks.append(_item_attachables.get(path.to_lower()))
		wear["drawn"] = drawn
		wear["attachables"] = blocks
		_apply_glow(wear)
		body.worn.append(wear)
	_note_glow_wears(body)

	_refresh_default_wear(body)
	apply_hides(body)
	_own_skins(skel)
	apply_scale(body, scale)
	skel.set_meta(MonsterCrowd.META_LAYOUT, "%s|%d" % [tmpl.parsed.skeleton_path if tmpl.parsed != null else bsr_path, skel.get_bone_count()])
	last_build_usec = Time.get_ticks_usec() - t0
	stats["builds"] += 1
	stats["build_usec"] += last_build_usec
	return body

## The worn entries a build of `items` makes (build's own rule): one visual
## per slot, the later replacing the earlier, in slot order, then the avatars
## on top; and the held weapon's TypeID4 (0 for none). `warn` logs an id no
## table holds (build), not a look-ahead's (template_paths).
func _resolve_wears(items: Array, woman: bool, warn: bool) -> Array:
	var by_slot := {}
	var avatars: Array = []
	var weapon_kind := 0
	for raw in items:
		var id := int(raw["id"]) if raw is Dictionary else int(raw)
		var plus := int(raw.get("plus", 0)) if raw is Dictionary else 0
		if id == 0:
			continue
		var info := _item_info(id)
		if info.is_empty():
			if warn:
				push_warning("CharacterAppearance: item %d is in no item table -- not drawn" % id)
			continue
		var slot := visual_slot(info["type_ids"])
		if slot < 0 or (slot > SLOT_SUIT and slot != SLOT_AVATAR):
			continue
		var models: PackedStringArray = info["models"]
		var wear := {"id": id, "plus": plus & 0xFF, "slot": slot, "type_ids": info["type_ids"], "code": String(info.get("code", "")),
			"models": item_models(models[0] if not models.is_empty() else "", info["type_ids"], woman),
			"nodes": []}
		if slot == SLOT_AVATAR:
			avatars.append(wear)
		else:
			by_slot[slot] = wear
		if slot == SLOT_WEAPON:
			weapon_kind = (info["type_ids"] as PackedInt32Array)[3]
	var order: Array = by_slot.keys()
	order.sort()
	var wears: Array = []
	for slot in order:
		wears.append(by_slot[slot])
	wears.append_array(avatars)
	return [wears, weapon_kind]

## Hides the body's own pieces under what it wears, as retail does: every
## body mesh shown, then each worn item's attachable block with flag 1 hides
## the pieces it covers (SkinnedBsrAssembler.apply_body_hides, READ
## CCompChar::FUN_00c1f890). Called by build() and unequip(); call it again
## after changing Body.worn by hand. Height and Volume (set_scale_byte) touch
## no visibility, so a slider keeps the hides.
static func apply_hides(body: Body) -> void:
	if body == null or body.skeleton == null:
		return
	var blocks: Array = []
	for wear in body.worn:
		blocks.append_array(wear.get("attachables", []))
	var parsed: BsrReader.ParsedObject = body.assembled.parsed if body.assembled != null else null
	body.hidden_body_meshes = SkinnedBsrAssembler.apply_body_hides(body.skeleton, parsed, blocks)

## Takes the item in visual `slot` off a built body (SLOT_AVATAR takes every
## avatar): its nodes are freed and the hides re-applied from what remains
## (READ, vslot_061 0x00c1fa00 -> FUN_00c1f890). Returns whether anything
## came off.
func unequip(body: Body, slot: int) -> bool:
	if body == null:
		return false
	var kept: Array = []
	var removed := false
	for wear in body.worn:
		if int(wear["slot"]) != slot:
			kept.append(wear)
			continue
		removed = true
		for n in wear["nodes"]:
			if is_instance_valid(n):
				(n as Node).free()
		if slot == SLOT_WEAPON:
			body.weapon_kind = 0
			body.weapon_group = "default"
	body.worn = kept
	if removed:
		_refresh_default_wear(body)
		apply_hides(body)
		_own_skins(body.skeleton)
		apply_volume(body.skeleton, body.volume_scales)
	return removed

## Round 685's review: the default wear on the empty chest and legs (READ,
## DefaultWear), re-decided from what the body wears now -- the client runs
## it after every armour change. A default is a worn entry with id 0 and
## "default" set. `default_wear_flag` stands for CGame+0x129 (set: none).
func _refresh_default_wear(body: Body) -> void:
	var kept: Array = []
	for wear in body.worn:
		if wear.get("default", false):
			for n in wear["nodes"]:
				if is_instance_valid(n):
					(n as Node).free()
		else:
			kept.append(wear)
	body.worn = kept
	if default_wear == null or body.skeleton == null or body.assembled == null:
		return
	var worn: Array = []
	for wear in body.worn:
		if int(wear["slot"]) != SLOT_AVATAR and wear.has("type_ids"):
			worn.append({"slot": wear["slot"], "type_ids": wear["type_ids"]})
	var bsr_path := body_path(body.ref_obj_id)
	for d in default_wear.wear_for(body_race(body), body.is_woman, worn, default_wear_flag):
		var node := _item_instance(bsr_path, body.assembled, body.skeleton, d["path"])
		var wear := {"id": 0, "plus": 0, "slot": d["slot"], "default": true, "type_ids": PackedInt32Array(),
			"models": PackedStringArray([d["path"]]), "nodes": [], "drawn": PackedStringArray(), "attachables": []}
		if node != null:
			wear["nodes"].append(node)
			wear["drawn"].append(d["path"])
			wear["attachables"].append(_item_attachables.get(String(d["path"]).to_lower()))
		body.worn.append(wear)

## A body's race for the default wear: the catalogue's Country (INFERRED to
## be the character data's +0x9c the client reads), else Europe when the
## body's .bsr lives under `europe`.
func body_race(body: Body) -> int:
	var e := _catalog.get_entry(body.ref_obj_id) if _catalog != null else null
	if e != null and e.is_body:
		return e.race
	return CharCatalog.RACE_EUROPE if body_path(body.ref_obj_id).to_lower().contains("europe") else CharCatalog.RACE_CHINA

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

## The variants whose failure falls back to the plain model (READ 0xa5f4f0).
const _FALLBACK_SUFFIXES := ["_r.bsr", "_f.bsr"]

## The plain model a `_r` / `_f` variant falls back to, "" for any other path.
static func _fallback_of(path: String) -> String:
	for suffix in _FALLBACK_SUFFIXES:
		if path.to_lower().ends_with(suffix):
			return path.substr(0, path.length() - suffix.length()) + ".bsr"
	return ""

## Frees the cached templates (a screen closing), the shared skins and the
## baked poses shared by clip path.
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
	_item_attachables.clear()
	_canonical_by_layout.clear()
	# The baked poses shared by path (round 738's review, F3).
	CrowdAnim.clear_shared_frames()
	# Round 748: template tasks still running are waited for and what they
	# made is freed, never adopted into the cleared caches.
	wait_prepared(false)

# --- templates made off the main thread (round 748) ---------------------------

## OURS (round 748, crowd_scale.md lane B, B4's open item): the first body of
## a new kind -- its `.bsr` assembled, each worn item assembled onto a scratch
## copy of it -- cost 250-500 ms on the main thread (MEASURED, the crowd
## probe's `QA DRESS` lines: build 220-378 ms of a 263-400 ms dressing, the
## rest under 45 ms). prepare() makes what a build of (body, items) still
## lacks on a WorkerThreadPool task, as the monsters' species templates are
## made since round 661; poll_prepared() adopts the finished ones on the main
## thread; build() itself is unchanged and, with everything cached, only
## duplicates. A caller that builds without asking still gets the synchronous
## path. Only the shared-skin bodies (`canonical`, the default) take it: an
## item template's key holds the skeleton's bone count, which a per-piece
## body (QA: OPENSRO_QA_CROWD_SKINS=own) may grow while it is dressed.
##
## The task reads `_data` and, for a body already assembled, a scratch copy of
## its template's skeleton made here on the main thread (the template itself
## stays the main thread's); it writes only its own result, under `_prep_lock`.
## Its item templates carry the skin they were made on: when adoption puts a
## new body template on its layout's shared skin (share_template), they are
## moved to it too, so a body still writes one skin a pose (round 738, A2).
## The glow's particle files are decoded on EfpEffect's own preload task.
var _prep_tasks := {}   # body .bsr path -> WorkerThreadPool task id, or -1 while queued
var _prep_done := {}    # body .bsr path -> the task's result (under _prep_lock)
## Requests waiting for a free slot, in the order they were made (the world
## asks nearest body first): [path, scratch, skin, items, group].
var _prep_queue: Array = []
## At most this many template tasks run at once (OURS). One body's assembly
## is 50-400 ms of GDScript reading the archives; 52 at once (the Figures'
## first arrival) took the main thread's share of the CPU and of the
## archive's lock (MEASURED, round 748: arrival frames of 1.5-2.2 s with every
## kind's task started together).
const PREP_MAX_RUNNING := 2
var _prep_running := 0
## Tests only: stand-ins for the task's two assemblies, so the async path runs
## on synthetic templates without an archive. body_assembler(path) ->
## AssembledCharacter or null; item_assembler(source skeleton, skin, path) ->
## [node or null, attachable or null], as _item_template_on.
var body_assembler := Callable()
var item_assembler := Callable()
var _prep_lock := Mutex.new()
## Bumped whenever poll_prepared adopts something, so a caller can cache a
## "not ready" answer until something new arrives.
var prep_generation := 0
## Counts for the log and the tests: tasks started, templates adopted, and
## the task time.
var prep_stats := {"tasks": 0, "bodies": 0, "items": 0, "task_usec": 0, "longest_usec": 0}

## The item `.bsr` paths a build of `items` on `ref_obj_id` hangs: every worn
## model, each `_r` / `_f` model's plain fallback (_FALLBACK_SUFFIXES), and
## the default wear the worn visuals leave uncovered (_refresh_default_wear's
## rule); the particle files the weapon's and shield's glow names at their
## plus; and the animation group the held weapon picks (build's rule).
## [items, efps, group].
func template_paths(ref_obj_id: int, items: Array) -> Array:
	var woman := is_woman(ref_obj_id)
	var resolved := _resolve_wears(items, woman, false)
	var paths := PackedStringArray()
	var efps := PackedStringArray()
	var worn: Array = []
	for wear in resolved[0]:
		for m in wear["models"]:
			if not paths.has(m):
				paths.append(m)
			var fb := _fallback_of(m)
			if fb != "" and not paths.has(fb):
				paths.append(fb)
		if int(wear["slot"]) != SLOT_AVATAR:
			worn.append({"slot": wear["slot"], "type_ids": wear["type_ids"]})
		var slot := int(wear["slot"])
		if glow_enabled and glow_tables != null and (slot == SLOT_WEAPON or slot == SLOT_SHIELD) and String(wear["code"]) != "":
			for r in glow_tables.particle_rows(String(wear["code"]), int(wear["plus"])):
				var efp := (r as ItemGlowTables.ParticleRow).efp
				if not efps.has(efp):
					efps.append(efp)
	if default_wear != null:
		for d in default_wear.wear_for(race_of(ref_obj_id), woman, worn, default_wear_flag):
			if not paths.has(String(d["path"])):
				paths.append(String(d["path"]))
	return [paths, efps, BodyAnimations.group_for_weapon(int(resolved[1]), race_of(ref_obj_id))]

## The item template key of `item_path` on a body template (_item_instance's).
static func _item_key(tmpl: SkinnedBsrAssembler.AssembledCharacter, body_bsr: String, item_path: String) -> String:
	return "%s|%d|%s" % [tmpl.parsed.skeleton_path if tmpl.parsed != null else body_bsr, tmpl.skeleton.get_bone_count(), item_path.to_lower()]

## The item paths of `paths` that a build on `tmpl` would still assemble: no
## template under its key yet, or a failed one whose fallback has none.
func _missing_items(tmpl: SkinnedBsrAssembler.AssembledCharacter, bsr_path: String, paths: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for p in paths:
		if not _item_templates.has(_item_key(tmpl, bsr_path, p)):
			out.append(p)
	return out

## Whether build(ref_obj_id, _, items) would assemble nothing on the main
## thread: the body's template and every item template are cached (or known
## to fail), the glow's particle files decoded, and no task for the body is
## still running. An unknown body, or a per-piece-skin appearance, answers
## true: build() takes them as before.
func templates_ready(ref_obj_id: int, items: Array) -> bool:
	return _prepare(ref_obj_id, items, false)

## Starts a task for whatever a build of (ref_obj_id, items) still lacks, and
## answers whether everything is ready already (templates_ready). A body whose
## task is running gets no second one; ask again after poll_prepared adopts it.
func prepare(ref_obj_id: int, items: Array) -> bool:
	return _prepare(ref_obj_id, items, true)

func _prepare(ref_obj_id: int, items: Array, start: bool) -> bool:
	if not canonical or (_data == null and not body_assembler.is_valid()):
		return true
	var bsr_path := body_path(ref_obj_id)
	if bsr_path == "":
		return true
	var wanted := template_paths(ref_obj_id, items)
	var efp_ready := _efps_ready(wanted[1], start)
	if _prep_tasks.has(bsr_path):
		return false
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = null
	var missing := PackedStringArray()
	if _body_templates.has(bsr_path):
		tmpl = _body_templates[bsr_path]
		if tmpl == null:
			return true
		missing = _missing_items(tmpl, bsr_path, wanted[0])
		# A failed template whose fallback has none: that one too.
		for p in wanted[0]:
			var key := _item_key(tmpl, bsr_path, p)
			if _item_templates.has(key) and _item_templates[key] == null:
				var fb := _fallback_of(p)
				if fb != "" and not missing.has(fb) and not _item_templates.has(_item_key(tmpl, bsr_path, fb)):
					missing.append(fb)
		if missing.is_empty():
			return efp_ready
	else:
		missing = wanted[0]
	if not start:
		return false
	# The task's own copy of an existing template's skeleton: the template
	# stays the main thread's (build() duplicates it).
	var scratch: Skeleton3D = tmpl.skeleton.duplicate() as Skeleton3D if tmpl != null else null
	var canon: Skin = tmpl.canonical_skin if tmpl != null else null
	_prep_tasks[bsr_path] = -1
	_prep_queue.append([bsr_path, scratch, canon, missing, String(wanted[2])])
	_start_queued()
	return false

## Starts queued requests while fewer than PREP_MAX_RUNNING run. Low
## priority: the world's own cell prepares (high) go first.
func _start_queued() -> void:
	while _prep_running < PREP_MAX_RUNNING and not _prep_queue.is_empty():
		var q: Array = _prep_queue.pop_front()
		var path: String = q[0]
		prep_stats["tasks"] += 1
		_prep_running += 1
		_prep_tasks[path] = WorkerThreadPool.add_task(_prep_task.bind(path, q[1], q[2], q[3], q[4]), false,
			"character template %s" % path.get_file())

## The task: the body's template if `scratch` is null (none yet), then each of
## `items` assembled onto it, each failed `_r` / `_f` model's fallback too.
## Plain results only; adopted on the main thread (_finish_prep).
func _prep_task(bsr_path: String, scratch: Skeleton3D, canon: Skin, items: PackedStringArray, group: String = "") -> void:
	var sw := Time.get_ticks_usec()
	var made_body: SkinnedBsrAssembler.AssembledCharacter = null
	var source := scratch
	if source == null:
		made_body = body_assembler.call(bsr_path) if body_assembler.is_valid() \
			else SkinnedBsrAssembler.assemble_from_archive(_data, bsr_path, false, canonical)
		if made_body != null:
			source = made_body.skeleton
			canon = made_body.canonical_skin
			# Its stand and run clips in the held weapon's group, into the
			# new template's own clip cache (nobody else holds it yet): the
			# first body's clip lookup read and parsed them on the main
			# thread (QA DRESS `clip`, up to 180 ms behind the workers).
			if _data != null:
				for action in [BsrReader.AnimationEntry.TYPE_STAND, BsrReader.AnimationEntry.TYPE_RUN]:
					SkinnedBsrAssembler.animation_for(_data, made_body, action, group if group != "" else "default")
	var made_items := {}
	if source != null:
		for p in items:
			var lower := p.to_lower()
			if made_items.has(lower):
				continue
			var pair: Array = item_assembler.call(source, canon, p) if item_assembler.is_valid() else _item_template_on(_data, source, canon, p, true)
			made_items[lower] = pair
			var fb := _fallback_of(p)
			if pair[0] == null and fb != "" and not made_items.has(fb.to_lower()):
				made_items[fb.to_lower()] = item_assembler.call(source, canon, fb) if item_assembler.is_valid() \
					else _item_template_on(_data, source, canon, fb, true)
	if scratch != null:
		scratch.free()
	var result := {"body": made_body, "assembled": made_body != null or scratch == null, "items": made_items, "canon": canon,
		"usec": Time.get_ticks_usec() - sw}
	_prep_lock.lock()
	_prep_done[bsr_path] = result
	_prep_lock.unlock()

## Whether the glow's particle files are decoded (EfpEffect's cache), the
## ones neither decoded nor on their way handed to EfpEffect's preload task
## when `start`. No Particles.pk2: nothing to wait for (EquipGlow draws none).
func _efps_ready(efps: PackedStringArray, start: bool) -> bool:
	if efps.is_empty():
		return true
	var arch := _particles_archive()
	if arch == null:
		return true
	var todo := PackedStringArray()
	for e in efps:
		if EfpEffect.has_template(e) and not EfpEffect.is_preloading(e):
			continue
		_efp_waiting[e] = true
		if not EfpEffect.is_preloading(e):
			todo.append(e)
	if not todo.is_empty() and start:
		EfpEffect.preload_paths(todo, arch)
	for e in efps:
		if not EfpEffect.has_template(e) or EfpEffect.is_preloading(e):
			return false
	return true

## Particle files a prepare waited on (path -> true); poll_prepared bumps
## prep_generation as they arrive.
var _efp_waiting := {}

## Adopts every finished task, then starts queued ones; answers how many
## were adopted. Main thread.
func poll_prepared() -> int:
	var n := 0
	for e in _efp_waiting.keys():
		if EfpEffect.has_template(e) and not EfpEffect.is_preloading(e):
			_efp_waiting.erase(e)
			prep_generation += 1
			n += 1
	for path in _prep_tasks.keys():
		var id: int = _prep_tasks[path]
		if id >= 0 and WorkerThreadPool.is_task_completed(id):
			_finish_prep(path, true)
			n += 1
	_start_queued()
	return n

## Waits for every task (a teardown, the tests); adopts what they made when
## `adopt`, else frees it. With `adopt`, queued requests run too, one after
## another; without, they are dropped.
func wait_prepared(adopt: bool = true) -> void:
	if not adopt:
		for q in _prep_queue:
			if q[1] != null and is_instance_valid(q[1]):
				(q[1] as Node).free()
			_prep_tasks.erase(q[0])
		_prep_queue.clear()
	while not _prep_tasks.is_empty():
		for path in _prep_tasks.keys():
			if int(_prep_tasks[path]) >= 0:
				_finish_prep(path, adopt)
		_start_queued()

## Whether a template task is still running.
func preparing() -> bool:
	return not _prep_tasks.is_empty()

func _finish_prep(bsr_path: String, adopt: bool) -> void:
	WorkerThreadPool.wait_for_task_completion(_prep_tasks[bsr_path])
	_prep_tasks.erase(bsr_path)
	_prep_running -= 1
	_prep_lock.lock()
	var r = _prep_done.get(bsr_path)
	_prep_done.erase(bsr_path)
	_prep_lock.unlock()
	if r == null:
		return
	if not adopt:
		_free_prepared(r)
		return
	var res: Dictionary = r
	prep_generation += 1
	prep_stats["task_usec"] += int(res["usec"])
	prep_stats["longest_usec"] = maxi(int(prep_stats["longest_usec"]), int(res["usec"]))
	var made: SkinnedBsrAssembler.AssembledCharacter = res["body"]
	if bool(res["assembled"]):
		if _body_templates.has(bsr_path):
			# Built meanwhile by a build() that did not wait: keep that one.
			if made != null and is_instance_valid(made.skeleton):
				made.skeleton.free()
		else:
			if made != null:
				share_template(made, _canonical_by_layout)
			stats["body_assemblies"] += 1
			prep_stats["bodies"] += 1
			_body_templates[bsr_path] = made
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = _body_templates.get(bsr_path)
	var items: Dictionary = res["items"]
	if tmpl == null:
		for lower in items:
			if items[lower][0] != null:
				(items[lower][0] as Node).free()
		return
	var task_skin: Skin = res["canon"]
	for lower in items:
		var pair: Array = items[lower]
		var node: Node3D = pair[0]
		var key := _item_key(tmpl, bsr_path, lower)
		if _item_templates.has(key):
			if node != null:
				node.free()
			continue
		if node != null and task_skin != null and tmpl.canonical_skin != null and task_skin != tmpl.canonical_skin:
			_reskin(node, task_skin, tmpl.canonical_skin)
		_item_templates[key] = node
		stats["item_assemblies"] += 1
		prep_stats["items"] += 1
		if node != null:
			_item_attachables[lower] = pair[1]

## Every mesh under `node` on skin `from` moved to `to` (the layout's shared
## skin: the same binds, Skeleton3DBuilder.canonical_skin of the same layout).
static func _reskin(node: Node, from: Skin, to: Skin) -> void:
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi != null and mi.skin == from:
			mi.skin = to

## Frees what a task made that will not be adopted.
static func _free_prepared(r) -> void:
	if r == null:
		return
	var made: SkinnedBsrAssembler.AssembledCharacter = r["body"]
	if made != null and is_instance_valid(made.skeleton):
		made.skeleton.free()
	var items: Dictionary = r["items"]
	for lower in items:
		if items[lower][0] != null and is_instance_valid(items[lower][0]):
			(items[lower][0] as Node).free()

func _body_template(bsr_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	if _body_templates.has(bsr_path):
		return _body_templates[bsr_path]
	if _data == null:
		return null
	var t := SkinnedBsrAssembler.assemble_from_archive(_data, bsr_path, false, canonical)
	if t != null:
		share_template(t, _canonical_by_layout)
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

## Round 734: the weapon or shield's glow and particles at its plus
## (EquipGlow), on the nodes just hung. Sets wear["glow"] to the row's plus
## (0: none) and wear["glow_fx"] to the effects attached.
func _apply_glow(wear: Dictionary) -> void:
	wear["glow"] = 0
	wear["glow_fx"] = 0
	var slot := int(wear["slot"])
	if not glow_enabled or glow_tables == null or (slot != SLOT_WEAPON and slot != SLOT_SHIELD):
		return
	var code := String(wear.get("code", ""))
	if code == "" or (wear["nodes"] as Array).is_empty():
		return
	var plus := int(wear["plus"])
	var row := glow_tables.glow_row(code, plus)
	var rows := glow_tables.particle_rows(code, plus)
	if row == null and rows.is_empty():
		return
	var made := EquipGlow.apply(wear["nodes"], row, rows, _data, _particles_archive() if not rows.is_empty() else null, code)
	wear["glow"] = row.plus if row != null else 0
	wear["glow_fx"] = int(made["particles"])

## On the body's skeleton (meta): the weapon and shield it wears, {slot, code,
## plus, nodes}, so reglow can redraw their glow once the skeleton has left
## its Body (World3D keeps only the skeleton).
const GLOW_WEARS_META := "opensro_glow_wears"

func _note_glow_wears(body: Body) -> void:
	var list: Array = []
	for wear in body.worn:
		var slot := int(wear["slot"])
		if slot == SLOT_WEAPON or slot == SLOT_SHIELD:
			list.append({"slot": slot, "code": wear.get("code", ""), "plus": int(wear["plus"]), "nodes": wear["nodes"]})
	body.skeleton.set_meta(GLOW_WEARS_META, list)

## Redraws the weapon and shield glow of a built body at new pluses (slot ->
## plus; a slot it lacks is +0): the old glow and its effects off
## (EquipGlow.clear), the new ones on -- what an equip-change broadcast that
## changes only a plus needs (round 734, the hook for 0x3038's OptLevel).
## Returns the wears redrawn.
func reglow(skel: Skeleton3D, pluses: Dictionary) -> int:
	if skel == null or not skel.has_meta(GLOW_WEARS_META):
		return 0
	var n := 0
	for w in skel.get_meta(GLOW_WEARS_META):
		var wear: Dictionary = w
		var nodes: Array = []
		for node in wear["nodes"]:
			if is_instance_valid(node):
				nodes.append(node)
				EquipGlow.clear(node)
		var plus := int(pluses.get(int(wear["slot"]), 0)) & 0xFF
		var redo := {"slot": wear["slot"], "code": wear["code"], "plus": plus, "nodes": nodes}
		_apply_glow(redo)
		wear["plus"] = plus
		wear["nodes"] = nodes
		n += 1
	return n

func _particles_archive() -> Pk2Reader:
	if particles == null and not _particles_tried:
		_particles_tried = true
		var path := Pk2Config.particles_path()
		if path != "":
			particles = Pk2Reader.open(path)
	return particles

func _make_item_template(tmpl: SkinnedBsrAssembler.AssembledCharacter, item_path: String) -> Node3D:
	var made := _item_template_on(_data, tmpl.skeleton, tmpl.canonical_skin, item_path)
	stats["item_assemblies"] += 1
	if made[0] != null:
		_item_attachables[item_path.to_lower()] = made[1]
	return made[0]

## An item's template (round 748: split out of _make_item_template so a
## WorkerThreadPool task can make one): `item_path` attached to a scratch copy
## of `source` (a body template's skeleton), lifted off and kept; [the node or
## null, its BsrReader.Attachable or null].
##
## `in_place` (the task's): attached to `source` itself and lifted off it --
## a skeleton only the caller holds (a new template not yet adopted, or a copy
## the main thread made for the task). Node.duplicate() reads every property
## through the Node3D getters, which Godot 4.2.2 refuses on a WorkerThreadPool
## thread whether or not the node is in a tree (READ: node.h, ERR_READ_THREAD_GUARD
## -> is_readable_from_caller_thread -> is_current_thread_safe_for_nodes, false
## on a pool thread): the copy's transforms came back as defaults, with an
## error per property (MEASURED in character_template_async_test's first
## version). Attaching adds the item's node and no bone: a shared-skin body's
## skeleton has the object-space bone already (Skeleton3DBuilder
## ._object_space_bone at assembly), the only bone build_skin adds. So the
## skeleton is as it was once the node is lifted off.
static func _item_template_on(data: Pk2Reader, source: Skeleton3D, canonical_skin: Skin, item_path: String, in_place: bool = false) -> Array:
	var scratch := source if in_place else source.duplicate() as Skeleton3D
	# The client's rule for a palette bone the body lacks (READ, see
	# Skeleton3DBuilder.build_skin): the Europe man's heavy legs need it.
	var attached := SkinnedBsrAssembler.attach_item_from_archive(data, scratch, item_path, true, canonical_skin)
	var node: Node3D = null
	var attachable = null
	if attached != null and attached.node != null:
		node = attached.node
		attachable = attached.attachable
		scratch.remove_child(node)
		node.set_meta("bone_count", scratch.get_bone_count())
	if not in_place:
		scratch.free()
	return [node, attachable]

## Gives every mesh skinned to the body's skeleton its own copy of its skin,
## so Volume (a bind pose edit) stays on this character. A mesh and its
## front-pass twin (ObjectLoader.add_front_pass) share one skin and keep
## sharing the copy. A piece on the shared skin (round 738) is left on it:
## Volume swaps it for a shared variant, never edits it. So is a piece skinned
## to an item's own skeleton, which Volume never touches (until round 738 it
## was copied too).
static func _own_skins(skel: Skeleton3D) -> void:
	var copies := {}
	for mi in _skinned_to(skel):
		if canonical_base(mi.skin) != null:
			continue
		if not copies.has(mi.skin):
			copies[mi.skin] = mi.skin.duplicate()
		mi.skin = copies[mi.skin]

func _item_info(id: int) -> Dictionary:
	if _items.has(id):
		return _items[id]
	if not _full_items_loaded and _media != null:
		_full_items_loaded = true
		var t0 := Time.get_ticks_usec()
		# Every part itemdata.txt names, in its order, so a later definition
		# of an id wins as it does in the client and in refdata/chargen.go;
		# shared with the world and the HUD (ItemTableReader.load_all, round
		# 741: the world's list had named 7 parts of the index's 63).
		var rows := ItemTableReader.load_all(_media)
		for rid in rows:
			var item: ItemTableReader.Item = rows[rid]
			_items[int(rid)] = {"models": item.model_paths, "type_ids": item.type_ids, "code": item.code_name}
		_inherit_glow(rows)
		stats["item_table_usec"] = Time.get_ticks_usec() - t0
		stats["item_table_rows"] = rows.size()
	return _items.get(id, {})
