extends RefCounted
class_name CharacterAppearance

## Builds a player character's body from what it looks like (CharacterLook,
## round 847): a model id (any of the 52 Figures, China or Europe, man or
## woman), the scale byte (Height and Volume), and the worn items with their
## plus. The character select screen, the customize preview and the world's
## bodies all use it, so it knows nothing of World3D, Login or the screens.
##
##   var appearance := CharacterAppearance.from_archives(data_pk2, media_pk2)
##   var body := appearance.build_look(CharacterLook.from_lobby(record))
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
## (`FUN_00a60ef0`).
##
## **Avatars over armour (round 789, CharacterVisualChange, READ
## AVATAR_RESEARCH.md 6):** every worn visual is walked through the
## charactervisualchange arbitration -- an avatar is drawn only when a
## ConditionID-2 row matches its TypeID word and Param7, its Slot mask hides
## the armour (and lower-ranked avatars) it covers, a flag is hidden under an
## attachment, a devil's spirit draws nothing -- and the default wear is
## decided from what is drawn. The same rule serves every body built here:
## the world's own player and others, the paper doll, the select screen.
## The world's slot -> item maps keep avatars under OURS keys,
## AVATAR_KEY_BASE.
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
static var HEIGHT_FACTORS := [0.94, 0.97, 1.00, 1.03, 1.06]
## READ, table 0xec64c8: {group, min, max}. Men's (INFERRED, see above).
static var VOLUME_TABLE_MEN := [
	[2, 0.88, 1.10], [3, 0.95, 1.11], [8, 0.92, 1.20], [19, 0.92, 1.20],
	[29, 0.90, 1.15], [33, 0.90, 1.15], [1, 0.90, 1.00],
]
## READ, table 0xec6528. Women's (INFERRED, see above).
static var VOLUME_TABLE_WOMEN := [
	[2, 0.95, 1.10], [3, 0.95, 1.00], [8, 0.95, 1.15], [19, 0.95, 1.15],
	[29, 0.90, 1.15], [33, 0.90, 1.15], [1, 0.90, 1.08], [37, 0.80, 1.18],
]
## READ: the 38 names `FUN_00d79e00` assigns to the strings at 0xed9b68 +
## i * 0x1c, in order; a Volume group number indexes it (0xc2ca90 refuses 38
## and above, and 38 = '&' ends each table).
static var BONE_GROUP_NAMES := [
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
## Round 796: meta on each worn item's node naming its equip visual slot
## (visual_slot), so a rider's weapon and shield can be hidden
## (World3D._set_held_items_shown, READ CharacterVisualChange::CObjItem::
## vslot_003).
const VISUAL_SLOT_META := &"opensro_visual_slot"
const SLOT_SUIT := 8
const SLOT_EARRING := 9
const SLOT_NECKLACE := 10
const SLOT_RING := 11
## Not a client slot: an avatar item, attached on top (FUN_00a60ef0).
const SLOT_AVATAR := 100
## OURS (round 789): the keys the world's slot -> item maps (World3D's
## equipped dictionaries, a spawn snapshot's) hold avatars under: this + the
## avatar's storage slot (own character) or its order in the spawn block
## (others). build() reads an avatar from its item type, never its key.
const AVATAR_KEY_BASE := 200
const AVATAR_KEYS := 5

## QA only (round 789): OPENSRO_QA_AVATAR_ARBITRATION=0 builds every
## appearance without the arbitration (the "before" of a render: every worn
## visual drawn, the default wear decided by the armour alone).
static func _qa_arbitration_off() -> bool:
	return OS.get_environment("OPENSRO_QA_AVATAR_ARBITRATION") == "0"

## Whether a key of the world's equipped maps is an avatar's (AVATAR_KEY_BASE).
static func is_avatar_key(key: int) -> bool:
	return key >= AVATAR_KEY_BASE and key < AVATAR_KEY_BASE + AVATAR_KEYS

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
## Round 789: the arbitration's table (CharacterVisualChange); null or empty
## draws every visual as before (a test, an archive without the file).
var visual_change: CharacterVisualChange = null
## Round 789 (INFERRED, AVATAR_RESEARCH.md OPEN 6): an avatar whose drawn
## Slot covers the hair bit (0x0800, a hat's 0x0A01) hides the body's hair
## piece (its attachable key 0, MEASURED in round 687), as the mask says the
## hair is taken. How retail removes the hair is not READ; false keeps only
## the item's own attachable block.
var hide_hair_by_mask := true
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
	# A task's Callable holds this object's id, not a reference (round 748's
	# review, F3; READ core/variant/callable.cpp:331-343), so a task may still
	# be running: wait for each before freeing what they share (the object is
	# whole during PREDELETE), then free whatever finished unadopted.
	# Round 762: the queue emptied first, under the lock, so each runner stops
	# after the request it is making.
	_prep_lock.lock()
	var queued := _prep_queue.duplicate()
	_prep_queue.clear()
	_prep_lock.unlock()
	for id in _runners:
		PoolWait.task(int(id))
	_runners.clear()
	_prep_tasks.clear()
	for path in _prep_done:
		_free_prepared(_prep_done[path])
	_prep_done.clear()
	for q in queued:
		if q[1] != null and is_instance_valid(q[1]):
			(q[1] as Node).free()
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
	a.visual_change = CharacterVisualChange.from_archive(media_pk2) if not _qa_arbitration_off() else null
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
	a.visual_change = CharacterVisualChange.from_archive(media_pk2) if media_pk2 != null and not _qa_arbitration_off() else null
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
		_items[int(id)] = _info_of(item)
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
## (0xa5f4f0 -> LAB_00a5f851); build() does the same (_fallback_of).
## The pairing keys on TypeID 3/1/6 and TypeID4 9 or 13 alone, never the
## folder: the Egyptian set axes and daggers under item\etc\weapon pair too
## (READ, the same test in 0xa5f4f0, icscriptobj 0x9e3890 and 0x80b980;
## round 758's census: 0 weapons or shields whose files exist miss a model).
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

## Round 847: builds `look` (CharacterLook), the one input every site that
## draws a character hands this builder -- the select screen, the create
## preview, the world's own body and the others', the doll, the portraits, the
## previews. `ref` (>= 0) draws it on that body instead of the look's own (the
## world resolves its body keys, with their fallback, itself); `drawable`
## (an id -> bool Callable) leaves out the worn ids it refuses, with a log line
## when `log_misses` (CharacterLook.items).
func build_look(look: CharacterLook, ref: int = -1, drawable: Callable = Callable(), log_misses: bool = false) -> Body:
	return build(ref if ref >= 0 else look.ref_obj_id, look.scale, look.items(drawable, log_misses))

## The far recipe of `look` (far_recipe; round 756's crowd ghosts), on `ref`
## when >= 0, without `drawable`'s refusals.
func far_recipe_look(look: CharacterLook, ref: int = -1, drawable: Callable = Callable()) -> FarRecipe:
	return far_recipe(ref if ref >= 0 else look.ref_obj_id, look.scale, look.items(drawable))

## kind_ready for `look` (round 762: the crowd's template readiness, kept
## under `kind`, CharacterLook.kind).
func kind_ready_look(kind: String, look: CharacterLook, ref: int = -1, drawable: Callable = Callable()) -> bool:
	return kind_ready(kind, ref if ref >= 0 else look.ref_obj_id, look.items(drawable))

## Builds the character from its raw build list: `items`, each {"id":
## RefItemID, "plus": u8, ["fx": the item's own RefItemID for a model
## switcher's row]} (a bare int is read as plus 0). The sites that draw a
## character call build_look (round 847: CharacterLook.items is the one place
## the list is made); this stays for the probes and tests that feed a list.
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
				node.set_meta(VISUAL_SLOT_META, int(wear["slot"]))
				(wear["nodes"] as Array).append(node)
				drawn.append(path)
				blocks.append(_item_attachables.get(path.to_lower()))
		var hair := hair_block_for(wear)
		if hair != null and not drawn.is_empty():
			blocks.append(hair)
		wear["drawn"] = drawn
		wear["attachables"] = blocks
		_apply_glow(wear)
		# Round 794: the item's own particles and clips (WornItemFx).
		wear["ambient_fx"] = WornItemFx.apply(wear["nodes"], skel, _particles_archive(), String(wear.get("code", "")))
		body.worn.append(wear)
	_note_glow_wears(body)

	_refresh_default_wear(body)
	apply_hides(body)
	_own_skins(skel)
	apply_scale(body, scale)
	# Round 794: a body wearing cloth joins the Dynamic Animation driver.
	ClothDriver.enlist(skel)
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
		var code := String(info.get("code", ""))
		var fx := int(raw.get("fx", 0)) if raw is Dictionary else 0
		var sources := glow_sources(code, fx)
		var wear := {"id": id, "plus": plus & 0xFF, "slot": slot, "type_ids": info["type_ids"], "code": code,
			"glow_code": sources[0], "fx_code": sources[1],
			"models": item_models(models[0] if not models.is_empty() else "", info["type_ids"], woman),
			"nodes": [], "word": int(info.get("word", CharacterVisualChange.type_word(info["type_ids"]))),
			"param7": int(info.get("param7", 0))}
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
	return [arbitrate_wears(wears), weapon_kind]

## Round 843 (OURS): the code names a worn weapon or shield's glow type and
## its effects (the seal's and the +8 sparkle) are looked up by, [glow, fx].
## `code` is the row it is drawn as; `fx` the item's own RefItemID when that
## row is a model switcher's (World3D passes it as the item dict's "fx"), else
## 0. docs/protocol/item_switchers.md section 3a has the census:
## - the drawn row's own rows stand when the tables give it any: the
##   archive's _SWITCHnn twins of the plain D11 A rows and of the Egyptian
##   sets carry a glow type and effects of their own (MEASURED);
## - a row with none -- the twins of the locked Seal of Nova rows, which an
##   unlocked (_ACTIVE) item is drawn with -- takes the item's own effects
##   (its seal and sparkle), and the glow type of the plain twin of the same
##   model (`..._A_RARE_SWITCHnn` -> `..._A_SWITCHnn`, the same .bsr), else
##   the item's own. A glow type is mostly the option texture's scroll
##   (itemtypenumber.txt: types 1-4 share colours and periods; they differ in
##   the scroll, the alpha-test flag and type 1's +9 texture, MEASURED), which
##   the archive sets per mesh:
##   the plain and the unlocked base rows share it on all 22 bases, and the
##   twins of one model agree in 310 of 330 (MEASURED).
func glow_sources(code: String, fx: int) -> Array:
	if fx <= 0 or glow_tables == null or glow_tables.has_rows(code):
		return [code, code]
	var own := String(_item_info(fx).get("code", ""))
	if own == "" or not glow_tables.has_rows(own):
		return [code, code]
	var mesh_twin := code.replace("_RARE_SWITCH", "_SWITCH")
	if mesh_twin != code and glow_tables.type_of(mesh_twin) != 0:
		return [mesh_twin, own]
	return [own, own]

## The code name `wear`'s glow type is looked up by (glow_sources; its own
## code for a wear made before round 843).
static func glow_code_of(wear: Dictionary) -> String:
	return String(wear.get("glow_code", wear.get("code", "")))

## The code name `wear`'s particle effects are looked up by (glow_sources).
static func fx_code_of(wear: Dictionary) -> String:
	return String(wear.get("fx_code", wear.get("glow_code", wear.get("code", ""))))

## Round 789: the wears CharacterVisualChange's arbitration draws, in attach
## order (AVATAR_RESEARCH.md 6.2): each gets its row's "vis_slot" /
## "vis_overlap" (0 when it has none), an avatar whose row is missing is
## dropped (READ: not attached), and a wear the walk hides is dropped (not
## drawn). A wing dress's AddAttach mesh joins its models (READ c:0xa5f4f0).
## Without the table every wear is kept, as before. The held weapon's kind
## stays the caller's: no avatar row covers 0x0040 (MEASURED).
func arbitrate_wears(wears: Array) -> Array:
	if visual_change == null or visual_change.is_empty():
		return wears
	var kept: Array = []
	var visuals: Array = []
	for w in wears:
		var v := visual_change.visual_for(int(w.get("word", 0)), int(w.get("param7", 0)))
		if v.is_empty() or (int(w["slot"]) == SLOT_AVATAR and v.get("row") == null):
			continue
		w["vis_slot"] = int(v["slot"])
		w["vis_overlap"] = int(v["overlap"])
		w["vis_priority"] = int(v["priority"])
		if int(w["slot"]) == SLOT_AVATAR:
			var extra := CharacterVisualChange.add_attach_path(visual_change.add_attach_row(String(w.get("code", ""))))
			if extra != "" and not (w["models"] as PackedStringArray).has(extra):
				var models: PackedStringArray = w["models"]
				models.append(extra)
				w["models"] = models
		kept.append(w)
		visuals.append(v)
	var walk := CharacterVisualChange.arbitrate(visuals)
	var drawn := {}
	for i in walk["drawn"]:
		drawn[int(i)] = true
	var out: Array = []
	for i in kept.size():
		if drawn.has(i):
			out.append(kept[i])
	return out

## The Slot bits the drawn avatars cover (round 789): what FUN_00a5e010's
## default wear test reads besides the armour, as every loaded visual's Slot.
static func avatar_cover_mask(wears: Array) -> int:
	var m := 0
	for w in wears:
		if int(w["slot"]) == SLOT_AVATAR:
			m |= int(w.get("vis_slot", 0))
	return m

## The body piece key the hair is (round 687, MEASURED: a body's attachable
## block maps key 0 to its hair mesh).
const HAIR_PIECE_KEY := 0

## Round 789 (INFERRED, hide_hair_by_mask): a stand-in attachable block that
## hides the hair, for an avatar whose drawn Slot takes it (0x0800 outside its
## OverlapSlot); null otherwise.
func hair_block_for(wear: Dictionary) -> BsrReader.Attachable:
	if not hide_hair_by_mask or int(wear["slot"]) != SLOT_AVATAR:
		return null
	if (int(wear.get("vis_slot", 0)) & ~int(wear.get("vis_overlap", 0)) & CharacterVisualChange.MASK_HAIR) == 0:
		return null
	var b := BsrReader.Attachable.new()
	b.flag = BsrReader.HIDE_FLAG
	b.entries = [[HAIR_PIECE_KEY, 0]]
	return b

# --- far recipes (round 756) ------------------------------------------------------

## Round 756 (OURS): what build() would draw for (ref_obj_id, scale, items),
## read off the cached templates without building a node -- so an arriving
## body can be drawn far at once (CrowdGpu.add_ghost: its kind's meshes as
## GPU instances) and dressed later. Each piece is a template's own
## MeshInstance3D with what build() would leave on that mesh's copy: the
## material (the glow at the item's plus, EquipGlow.material_for, as
## _apply_glow puts it), the skin (the shared skin's Volume variant for the
## scale byte, apply_volume's), and the place it hangs (skinned to the body,
## or from a body bone through a BoneAttachment3D). The body's own meshes the
## worn items hide are left out (SkinnedBsrAssembler.hidden_body_nodes, the
## rule apply_body_hides applies). CrowdGpu turns pieces into instances by the
## rules it reads a built body with (_part_for), and its test and the
## `arrival_bench` / crowd probe's parity check hold a recipe's parts to a
## built body's.
class FarRecipe:
	var key := ""
	var layout_key := ""
	## The body template's skeleton: the bones and rests the layout is read
	## from (detached; never in a tree).
	var skeleton: Skeleton3D
	var bsr_path := ""
	var height := 1.0
	var scale := 0
	var weapon_kind := 0
	var weapon_group := "default"
	var hidden_body_meshes := 0
	## One per drawn mesh: [MeshInstance3D (a template's), Material, overridden
	## (the material is the copy's material_override, which CharacterLight
	## swaps for its level), Skin or null, attach bone name ("" when skinned to
	## the body), chain (the transforms from the mesh up to its
	## BoneAttachment3D, or to the skeleton), top node (the template subtree it
	## came from)].
	var pieces: Array = []
	## Round 762's review, F1: the particle rows build()'s glow would attach
	## (EquipGlow.apply -> EquipFx), each {efp, scale, skel (the item's
	## template skeleton), bone (its index there), pose (its global pose),
	## att_bone (the body bone the item hangs from), chain (the item
	## skeleton's transform under that attachment), wear (the wear's slot: a
## weapon's rows show together)}:
	## EquipFx.add_ghost_host draws them on a ghost.
	var fx: Array = []

## key -> FarRecipe, or null for a kind build() would grow (a bone the body
## template lacks) or cannot build. Dropped with the templates.
var _far_recipes := {}
## "shared skin id|scale byte" -> its Volume variant (held: the recipes draw
## with it).
var _far_volume := {}
## Counts (QA, tests): recipes made, cache hits, refusals by reason.
var far_stats := {"made": 0, "hits": 0, "not_ready": 0, "refused": 0}

## The recipe of (ref_obj_id, scale, items), or null: not ready (a template
## is still to be made: ask prepare() / templates_ready() first) or refused
## (build() would add a bone; an unknown body). Main thread only.
func far_recipe(ref_obj_id: int, scale: int, items: Array) -> FarRecipe:
	var key := "%d|%d|%s" % [ref_obj_id, scale, str(items)]
	if _far_recipes.has(key):
		far_stats["hits"] += 1
		return _far_recipes[key]
	if not canonical:
		return null
	var bsr_path := body_path(ref_obj_id)
	if bsr_path == "" or not _body_templates.has(bsr_path) or _prep_tasks.has(bsr_path):
		far_stats["not_ready"] += 1
		return null
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = _body_templates[bsr_path]
	if tmpl == null or tmpl.skeleton == null:
		_far_recipes[key] = null
		far_stats["refused"] += 1
		return null
	var skel := tmpl.skeleton
	var woman := is_woman(ref_obj_id)
	var race := race_of(ref_obj_id)
	var resolved := _resolve_wears(items, woman, false)
	var r := FarRecipe.new()
	r.key = key
	r.scale = scale
	r.bsr_path = bsr_path
	r.skeleton = skel
	r.weapon_kind = int(resolved[1])
	r.weapon_group = BodyAnimations.group_for_weapon(r.weapon_kind, race)
	r.layout_key = "%s|%d" % [tmpl.parsed.skeleton_path if tmpl.parsed != null else bsr_path, skel.get_bone_count()]
	# What build() hangs, in its order: [template node, glow material by mesh].
	var hung: Array = []
	var blocks: Array = []
	var worn: Array = []
	for wear in resolved[0]:
		var nodes: Array = []
		for path in wear["models"]:
			var got := _far_item(tmpl, bsr_path, skel, path)
			if got.is_empty():
				far_stats["not_ready"] += 1
				return null
			if not (got[0] is bool) and got[0] == null and _fallback_of(path) != "":
				path = _fallback_of(path)
				got = _far_item(tmpl, bsr_path, skel, path)
				if got.is_empty():
					far_stats["not_ready"] += 1
					return null
			if got[0] is bool:
				_far_recipes[key] = null
				far_stats["refused"] += 1
				return null
			if got[0] != null:
				nodes.append(got[0])
				blocks.append(_item_attachables.get(String(path).to_lower()))
		var glow := _far_glow(wear, nodes)
		_far_fx(wear, nodes, skel, r, int(wear["slot"]))
		for n in nodes:
			hung.append([n, glow])
		# Round 789: build()'s hair block for a hat (hair_block_for).
		var hair := hair_block_for(wear)
		if hair != null and not nodes.is_empty():
			blocks.append(hair)
		if int(wear["slot"]) != SLOT_AVATAR and wear.has("type_ids"):
			worn.append({"slot": wear["slot"], "type_ids": wear["type_ids"]})
	# The default wear the worn visuals leave uncovered (_refresh_default_wear).
	if default_wear != null:
		for d in default_wear.wear_for(race, woman, worn, default_wear_flag, avatar_cover_mask(resolved[0])):
			var got := _far_item(tmpl, bsr_path, skel, String(d["path"]))
			if got.is_empty():
				far_stats["not_ready"] += 1
				return null
			if got[0] is bool:
				_far_recipes[key] = null
				far_stats["refused"] += 1
				return null
			if got[0] != null:
				hung.append([got[0], {}])
				blocks.append(_item_attachables.get(String(d["path"]).to_lower()))
	var hides := SkinnedBsrAssembler.hidden_body_nodes(skel, tmpl.parsed, blocks)
	r.hidden_body_meshes = int(hides[1])
	# apply_scale's Height and Volume (0xFF changes nothing: a new Body's 1.0
	# and no factors).
	var scales := {}
	if scale != 0xff:
		r.height = height_factor(scale)
		scales = volume_bone_scales(scale, woman)
	for c in skel.get_children():
		if (hides[0] as Dictionary).has(c):
			continue
		_far_pieces(c, skel, {}, scales, r)
	for h in hung:
		_far_pieces(h[0], skel, h[1], scales, r)
	far_stats["made"] += 1
	_far_recipes[key] = r
	return r

## An item template as _item_instance would hang it: [node], [null] (none:
## build() skips it, or tries the fallback), [false] (build() would add a
## bone the body template lacks: no recipe), or [] (not made yet).
func _far_item(tmpl: SkinnedBsrAssembler.AssembledCharacter, body_bsr: String, skel: Skeleton3D, item_path: String) -> Array:
	var key := _item_key(tmpl, body_bsr, item_path)
	if not _item_templates.has(key):
		return []
	var t: Node3D = _item_templates[key]
	if t == null:
		return [null]
	if int(t.get_meta("bone_count", skel.get_bone_count())) > skel.get_bone_count():
		return [false]
	return [t]

## _apply_glow's materials for a wear's template nodes, without touching
## them: mesh -> its glow material, {} for no glow.
func _far_glow(wear: Dictionary, nodes: Array) -> Dictionary:
	var out := {}
	var slot := int(wear["slot"])
	if not glow_enabled or glow_tables == null or (slot != SLOT_WEAPON and slot != SLOT_SHIELD):
		return out
	var code := glow_code_of(wear)
	if code == "" or nodes.is_empty():
		return out
	var row := glow_tables.glow_row(code, int(wear["plus"]))
	if row == null:
		return out
	var option_tex := EquipGlow.option_texture(_data, row.texture)
	for node in nodes:
		for mi in EquipGlow.meshes_of(node):
			var plain := EquipGlow.plain_of(AppearFade.original_material(mi))
			if plain != null:
				out[mi] = EquipGlow.material_for(plain, row, option_tex)
	return out

## Round 762's review, F1 (OURS): the particle rows _apply_glow would attach
## to a wear's template nodes (EquipGlow.apply's rule: a row whose bone no item
## skeleton has, or whose effect does not build, makes none), as FarRecipe.fx
## holds them. A row on an item skeleton not hung through a BoneAttachment3D
## of a body bone is left out (none is, among the weapons and shields).
func _far_fx(wear: Dictionary, nodes: Array, skel: Skeleton3D, r: FarRecipe, wear_key: int) -> void:
	var slot := int(wear["slot"])
	if nodes.is_empty():
		return
	var code := fx_code_of(wear)
	# [row, the models it goes on]: a glow-table row on every model that has
	# its bone (round 828, EquipGlow.apply's rule: each part of a dual weapon).
	var rows: Array = []
	if glow_enabled and glow_tables != null and (slot == SLOT_WEAPON or slot == SLOT_SHIELD) and code != "":
		for pr in glow_tables.particle_rows(code, int(wear["plus"])):
			rows.append([pr, nodes])
	# Round 794: the item's own always-on particles (WornItemFx), any slot --
	# a talisman's glow -- on its own skeleton's bones.
	for node in nodes:
		if is_instance_valid(node) and (node as Node).has_meta(WornItemFx.AMBIENT_META):
			for pr in WornItemFx.ambient_rows(node, WornItemFx.item_skeleton(node)):
				rows.append([pr, [node]])
	if rows.is_empty():
		return
	var archive := _particles_archive()
	if archive == null:
		return
	for pair in rows:
		var row := pair[0] as ItemGlowTables.ParticleRow
		if EfpEffect.template_for(row.efp, archive) == null:
			continue
		for isk in EquipGlow.bone_hosts(pair[1], row.bone):
			_far_fx_row(r, row, isk, skel, wear_key)

## One FarRecipe.fx entry: `row` on the item skeleton `isk`, hung (through a
## BoneAttachment3D) from a bone of `skel`.
func _far_fx_row(r: FarRecipe, row: ItemGlowTables.ParticleRow, isk: Skeleton3D, skel: Skeleton3D, wear_key: int) -> void:
	var chain := Transform3D.IDENTITY
	var at: Node = isk
	var att: BoneAttachment3D = null
	while at != null:
		if at is BoneAttachment3D:
			att = at
			break
		if at is Node3D:
			chain = (at as Node3D).transform * chain
		at = at.get_parent()
	var body_bone := skel.find_bone(att.bone_name) if att != null else -1
	if body_bone < 0:
		far_stats["fx_unhung"] = int(far_stats.get("fx_unhung", 0)) + 1
		return
	# A template's item skeleton is never in a tree: its globals composed
	# here, at rest, as a built body's never-posed item skeleton has them.
	if not isk.is_inside_tree():
		isk.force_update_all_bone_transforms()
	var b := isk.find_bone(row.bone)
	r.fx.append({"efp": row.efp, "scale": row.scale, "skel": isk, "bone": b, "pose": isk.get_bone_global_pose(b),
		"att_bone": body_bone, "chain": chain, "wear": wear_key, "model": isk.get_instance_id()})

## The pieces under `top` (a child build() leaves on the skeleton, or an item
## template it would hang there), each as FarRecipe.pieces holds them.
func _far_pieces(top: Node, skel: Skeleton3D, glow: Dictionary, scales: Dictionary, r: FarRecipe) -> void:
	var stack: Array[Node] = [top]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is EfpEffect:
			continue
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null:
			continue
		var mat: Material = glow.get(mi, mi.get_active_material(0))
		var overridden := glow.has(mi) or mi.material_override != null
		var skin: Skin = mi.skin
		var bone_name := ""
		var chain := Transform3D.IDENTITY
		var at: Node = mi
		var to_body := false
		while at != null:
			if at is BoneAttachment3D and (at == top or at.get_parent() == skel):
				bone_name = (at as BoneAttachment3D).bone_name
				break
			if at == skel:
				break
			if at is Node3D:
				chain = (at as Node3D).transform * chain
			if at == top:
				break
			at = at.get_parent()
		if bone_name == "" and skin != null and _far_skinned_to_body(mi, top, skel):
			to_body = true
			var base := canonical_base(skin)
			if base != null:
				# One variant per shared skin and scale byte (volume_skin
				# builds its key from every factor: cached here by the byte).
				var vk := "%d|%d" % [base.get_instance_id(), r.scale]
				var got = _far_volume.get(vk)
				if got == null:
					got = volume_skin(base, skel, scales)
					_far_volume[vk] = got
				skin = got
		r.pieces.append([mi, mat, overridden, skin, bone_name, chain, top, to_body])

## Whether `mi` (under `top`) would be skinned to the body skeleton once `top`
## hangs on it: its skeleton path, walked from `mi`, leaves `top` upward into
## the skeleton (a body template's piece already sits under it).
static func _far_skinned_to_body(mi: MeshInstance3D, top: Node, skel: Skeleton3D) -> bool:
	var path := mi.skeleton
	if path.is_empty():
		return false
	if top.get_parent() == skel or top == skel:
		return mi.get_node_or_null(path) == skel
	var at: Node = mi
	for i in range(path.get_name_count()):
		var name := String(path.get_name(i))
		if name == "..":
			at = skel if at == top else at.get_parent()
			if at == null:
				return false
		elif at == skel:
			return false
		else:
			at = at.get_node_or_null(name)
			if at == null:
				return false
	return at == skel

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
	for d in default_wear.wear_for(body_race(body), body.is_woman, worn, default_wear_flag, avatar_cover_mask(body.worn)):
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

## The plain model a `_r` / `_f` variant falls back to, "" for any other path
## (the variants whose failure falls back to the plain model: READ 0xa5f4f0).
##
## Round 748's review, F1: no `const` Array here. A GDScript `const` Array is
## read-only, and Godot 4.2.2 reads a read-only Array's element through ONE
## Variant slot the array shares with every reader (`core/variant/array.cpp:
## 84-98`, `*_p->read_only = _p->array[p_idx]`; the VM's `for` loop and
## `CONST[i]` both go through it). The template task (_prep_task) and the
## main thread both called this: two threads swapped Strings through that
## slot unlocked and corrupted the heap (the review's stress: 18 of 19 runs
## crashed; none once this read no constant). `ConstArrayLint` keeps such
## reads out of the scripts worker tasks run.
static func _fallback_of(path: String) -> String:
	var low := path.to_lower()
	if low.ends_with("_r.bsr") or low.ends_with("_f.bsr"):
		return path.substr(0, path.length() - 6) + ".bsr"
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
	# Round 756: the recipes name the templates' meshes.
	_far_recipes.clear()
	_far_volume.clear()
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
## Round 762: a request's key (a body .bsr path, or an item task's) -> -1 while
## it is queued or being made (the runners take requests off the queue).
var _prep_tasks := {}
var _prep_done := {}    # body .bsr path -> the task's result (under _prep_lock)
## Requests waiting for a free slot, in the order they were made (the world
## asks nearest body first): [path, scratch, skin, items, group].
var _prep_queue: Array = []
## At most this many template tasks run at once (OURS). One body's assembly
## is 50-400 ms of GDScript reading the archives; 52 at once (the Figures'
## first arrival) took the main thread's share of the CPU and of the
## archive's lock (MEASURED, round 748: arrival frames of 1.5-2.2 s with every
## kind's task started together).
##
## Round 762: 1 (was 2). MEASURED (the swarm lineup at 1,000, cold): one
## runner revealed the page at 7.37 s against 7.60 s with two, in 9.5 s of
## task time against 14.1 (the two contend), and the main thread's worst
## frame while they ran was 126 ms against 220.
const PREP_MAX_RUNNING := 1
## Round 756 (QA only): OPENSRO_QA_PREP_RUNNING=<n> runs n at once instead, to
## measure what the cap costs a cold crowd's arrival (r756.md).
var prep_max_running := int(OS.get_environment("OPENSRO_QA_PREP_RUNNING")) if OS.get_environment("OPENSRO_QA_PREP_RUNNING").is_valid_int() else PREP_MAX_RUNNING
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
## model and the default wear the worn visuals leave uncovered
## (_refresh_default_wear's rule); the particle files the weapon's and
## shield's glow names at their plus; and the animation group the held
## weapon picks (build's rule). [items, efps, group].
##
## Not a `_r` / `_f` model's plain fallback (_fallback_of): that is wanted
## only when the `_r` / `_f` fails, as in the client (0xa5f4f0 ->
## LAB_00a5f851), and _prep_task and _prepare ask for it then. Until round
## 758 it was listed always, and every dual axe and dagger -- whose plain
## `.bsr` the archive does not have (MEASURED: Data.pk2 holds axe_NN_l/_r and
## eu_dagger_11_set_a_l/_r, no axe_NN.bsr) -- logged a "not found in archive"
## error for a weapon that drew in full (census_weapon_models.gd: 522 asks
## for a missing file before, 64 after: items with no file at all, and a
## woman's `_f` of a harp that has only the plain model, which the client
## tries first too).
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
		if int(wear["slot"]) != SLOT_AVATAR:
			worn.append({"slot": wear["slot"], "type_ids": wear["type_ids"]})
		var slot := int(wear["slot"])
		if glow_enabled and glow_tables != null and (slot == SLOT_WEAPON or slot == SLOT_SHIELD) and fx_code_of(wear) != "":
			for r in glow_tables.particle_rows(fx_code_of(wear), int(wear["plus"])):
				var efp := (r as ItemGlowTables.ParticleRow).efp
				if not efps.has(efp):
					efps.append(efp)
	if default_wear != null:
		for d in default_wear.wear_for(race_of(ref_obj_id), woman, worn, default_wear_flag, avatar_cover_mask(resolved[0])):
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
	# stays the main thread's (build() duplicates it). Its bones only
	# (_bare_skeleton): a duplicate carries the body's mesh nodes, which
	# share the template's meshes, and freeing those on the worker
	# disconnected them from the shared meshes' `changed` signal while the
	# main thread connected new bodies to it -- Godot 4.2.2's Object signal
	# map has no lock (READ: core/object/object.h has no signal mutex;
	# MeshInstance3D::set_mesh connects unconditionally). MEASURED: a
	# 200-body arrival crashed with a corrupted CowData ("Index p_index = 0
	# is out of bounds (size() = -995350686)") on the main thread.
	var scratch: Skeleton3D = _bare_skeleton(tmpl.skeleton) if tmpl != null else null
	var canon: Skin = tmpl.canonical_skin if tmpl != null else null
	_prep_tasks[bsr_path] = -1
	_enqueue([bsr_path, scratch, canon, missing, String(wanted[2]), bsr_path, false])
	_start_queued()
	return false

# --- round 762: kinds ready by events, items made a layout at a time -----------------

## Round 762 (OURS; docs/rounds/r762.md). A crowd in the swarm's gear is
## thousands of kinds (body, worn items, pluses) over a few dozen bodies and a
## few thousand items. Until now each kind was asked again (prepare(): its
## wears resolved, every path looked up) whenever anything was adopted, which
## during a cold arrival was every frame: 80-100 ms frames that drew nothing
## (MEASURED, the swarm lineup at 1,000). And a body's task made the items of
## the first kind that asked, one task a body at a time, so the items of the
## other kinds of that body waited for it, and the bodies of one skeleton
## layout made the same items over again.
##
## Now a kind (kind_ready) keeps what it wants and what it still lacks, and is
## looked at again only when something it can use arrived: its body's template
## (_bsr_gen), an item on its layout (_layout_gen), a glow's particle file
## (_efp_gen). A body's template is its own task (no items); items are made
## by layout -- any body template of the layout serves (_item_key) -- in
## chunks of ITEM_CHUNK, each item asked once however many kinds and bodies
## want it (_items_inflight).
class KindPrep:
	var bsr := ""
	var paths := PackedStringArray()
	var efps := PackedStringArray()
	var group := ""
	var missing := PackedStringArray()
	var seen := Vector3i(-1, -1, -1)
	var ready := false
	## Its body template's item layout (_layout_key), once the body is made.
	var layout := ""

var _kind_preps := {}
## Body .bsr -> the kinds waiting for its template; the prewarm requests moved
## up already (once a body).
var _kinds_on_body := {}
var _promoted := {}
var _bsr_gen := {}
var _layout_gen := {}
var _efp_gen := 0
## Item task key -> [the paths it was asked for, its body .bsr]; and the item
## keys asked for and not adopted yet.
var _item_tasks := {}
var _items_inflight := {}
var _item_task_n := 0
const ITEM_TASK_PREFIX := "items#"
## Items a task makes (OURS): small enough that a layout's items spread over
## the running tasks, big enough that the task's scratch skeleton is worth it.
const ITEM_CHUNK := 6
## Adoption's time a call (poll_prepared), one at least (OURS).
const ADOPT_BUDGET_USEC := 4000

## A body template's item layout key (_item_key without the item).
static func _layout_key(tmpl: SkinnedBsrAssembler.AssembledCharacter, body_bsr: String) -> String:
	if tmpl == null:
		return body_bsr
	return "%s|%d" % [tmpl.parsed.skeleton_path if tmpl.parsed != null else body_bsr, tmpl.skeleton.get_bone_count()]

## The paths a request asked for (a dropped request: none of them in flight).
func _forget_asked(paths, body_bsr: String) -> void:
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = _body_templates.get(body_bsr)
	if tmpl == null:
		return
	for p in paths:
		_items_inflight.erase(_item_key(tmpl, body_bsr, String(p)))

## Whether `kind` (the caller's key for a (body, items) pair) is known here:
## 1 ready, 0 not yet, -1 never asked (call kind_ready with its spec).
func kind_state(kind: String) -> int:
	var kp: KindPrep = _kind_preps.get(kind)
	if kp == null:
		return -1
	if kp.ready:
		return 1
	if _kind_gen(kp) == kp.seen:
		return 0
	return 1 if _kind_check(kp) else 0

## Whether build(ref_obj_id, _, items) -- or its far recipe -- would make
## nothing on the main thread, asking for what it lacks when it would.
## Remembered under `kind`.
func kind_ready(kind: String, ref_obj_id: int, items: Array) -> bool:
	var kp: KindPrep = _kind_preps.get(kind)
	if kp == null:
		kp = KindPrep.new()
		_kind_preps[kind] = kp
		kp.bsr = body_path(ref_obj_id)
		if not canonical or (_data == null and not body_assembler.is_valid()) or kp.bsr == "":
			kp.ready = true
			return true
		var kt := Time.get_ticks_usec() if FrameSplit.on else 0
		var wanted := template_paths(ref_obj_id, items)
		if FrameSplit.on:
			FrameSplit.add("k_paths", Time.get_ticks_usec() - kt)
		kp.paths = wanted[0]
		kp.efps = wanted[1]
		kp.group = String(wanted[2])
		kp.missing = kp.paths.duplicate()
	if kp.ready:
		return true
	if _kind_gen(kp) == kp.seen:
		return false
	return _kind_check(kp)

func _kind_gen(kp: KindPrep) -> Vector3i:
	if kp.layout == "":
		var tmpl = _body_templates.get(kp.bsr)
		if tmpl != null:
			kp.layout = _layout_key(tmpl, kp.bsr)
	return Vector3i(int(_bsr_gen.get(kp.bsr, 0)), int(_layout_gen.get(kp.layout, 0)) if kp.layout != "" else 0, _efp_gen)

func _kind_check(kp: KindPrep) -> bool:
	kp.seen = _kind_gen(kp)
	var et := Time.get_ticks_usec() if FrameSplit.on else 0
	var efp_ok := _efps_ready(kp.efps, true)
	if FrameSplit.on:
		FrameSplit.add("k_efps", Time.get_ticks_usec() - et)
	if not _body_templates.has(kp.bsr):
		if not _prep_tasks.has(kp.bsr):
			_prep_tasks[kp.bsr] = -1
			_enqueue([kp.bsr, null, null, PackedStringArray(), kp.group, kp.bsr, false])
			_start_queued()
		elif not _promoted.has(kp.bsr):
			_promoted[kp.bsr] = true
			_promote(kp.bsr)
		# Asked again the moment its body is adopted (_finish_prep), so its
		# items are asked for in that frame.
		var waiting: Array = _kinds_on_body.get(kp.bsr, [])
		if not waiting.has(kp):
			waiting.append(kp)
		_kinds_on_body[kp.bsr] = waiting
		return false
	if _prep_tasks.has(kp.bsr):
		return false
	var tmpl: SkinnedBsrAssembler.AssembledCharacter = _body_templates[kp.bsr]
	if tmpl == null:
		kp.ready = true
		return true
	var still := PackedStringArray()
	if kp.layout == "":
		kp.layout = _layout_key(tmpl, kp.bsr)
	for p in kp.missing:
		# _item_key's, from the kind's layout.
		var key := kp.layout + "|" + p.to_lower()
		if _item_templates.has(key):
			# A failed template whose fallback has none: that one too.
			if _item_templates[key] == null:
				var fb := _fallback_of(p)
				if fb != "" and not _item_templates.has(kp.layout + "|" + fb.to_lower()) and not still.has(fb):
					still.append(fb)
			continue
		still.append(p)
	kp.missing = still
	if still.is_empty():
		kp.ready = efp_ok
		return efp_ok
	_request_items(kp.bsr, tmpl, still)
	return false

## Asks for `paths` on `tmpl`'s layout: those not made nor asked yet, in
## chunks of ITEM_CHUNK, each a task on its own scratch copy of the bones.
func _request_items(body_bsr: String, tmpl: SkinnedBsrAssembler.AssembledCharacter, paths: PackedStringArray) -> void:
	var todo := PackedStringArray()
	for p in paths:
		var key := _item_key(tmpl, body_bsr, p)
		if _items_inflight.has(key) or _item_templates.has(key):
			continue
		_items_inflight[key] = true
		todo.append(p)
	var i := 0
	while i < todo.size():
		var chunk := todo.slice(i, i + ITEM_CHUNK)
		i += ITEM_CHUNK
		_item_task_n += 1
		var key := "%s%d" % [ITEM_TASK_PREFIX, _item_task_n]
		_prep_tasks[key] = -1
		_item_tasks[key] = [chunk, body_bsr]
		_enqueue([key, _bare_skeleton(tmpl.skeleton), tmpl.canonical_skin, chunk, "", body_bsr, false])
	if not todo.is_empty():
		_start_queued()

## A queued request for body `bsr` that a prewarm put at the back moves up
## (a crowd wants it now).
func _promote(bsr: String) -> void:
	_prep_lock.lock()
	var found: Array = []
	for i in _prep_queue.size():
		var q: Array = _prep_queue[i]
		if String(q[0]) == bsr and bool(q[6]):
			_prep_queue.remove_at(i)
			q[6] = false
			found = q
			break
	_prep_lock.unlock()
	if not found.is_empty():
		_enqueue(found)

## Round 762 (OURS): every body in `refs` has its template made in the
## background, after any request a world makes (low priority in the queue),
## so a crowd that comes later finds its bodies made. Returns how many were
## asked for.
func prewarm_bodies(refs: Array) -> int:
	if not canonical or _data == null:
		return 0
	var n := 0
	for ref in refs:
		var bsr := body_path(int(ref))
		if bsr == "" or _body_templates.has(bsr) or _prep_tasks.has(bsr):
			continue
		_prep_tasks[bsr] = -1
		_enqueue([bsr, null, null, PackedStringArray(), "default", bsr, true])
		n += 1
	_start_queued()
	return n

## A skeleton with `src`'s bones -- names, parents, rests, poses at rest --
## and nothing else: what attaching an item reads (bone indices, rests, the
## object-space bone a shared-skin body has).
static func _bare_skeleton(src: Skeleton3D) -> Skeleton3D:
	var s := Skeleton3D.new()
	# No name (round 748's review, F2): a template's skeleton is unnamed, and
	# setting an empty one is an engine ERROR in the log; nothing reads it.
	s.transform = src.transform
	for i in range(src.get_bone_count()):
		s.add_bone(src.get_bone_name(i))
	for i in range(src.get_bone_count()):
		s.set_bone_parent(i, src.get_bone_parent(i))
		s.set_bone_rest(i, src.get_bone_rest(i))
		s.reset_bone_pose(i)
	return s

## Starts queued requests while fewer than PREP_MAX_RUNNING run. Low
## priority: the world's own cell prepares (high) go first.
##
## Round 762: a running task is a runner (_prep_runner) that takes request
## after request off the queue until it is empty. A task a request was one task
## a frame a slot, since only the main thread's poll started the next: the
## crowd's 514 requests took 19 s of wall time for 11 s of work on two
## threads (MEASURED r762.md).
func _start_queued() -> void:
	_prep_lock.lock()
	var queued := _prep_queue.size()
	_prep_lock.unlock()
	while _runners.size() < prep_max_running and queued > 0:
		_runner_n += 1
		var id := WorkerThreadPool.add_task(_prep_runner.bind(_runner_n), false, "character templates")
		_runners[id] = _runner_n
		queued -= 1
	_prep_running = _runners.size()

## Runner task ids -> their number; the request each runner is making (by
## number, under _prep_lock), so one a script error stopped is not waited on.
var _runners := {}
var _runner_n := 0
var _runner_current := {}

func _prep_runner(n: int) -> void:
	while true:
		_prep_lock.lock()
		if _prep_queue.is_empty():
			_runner_current.erase(n)
			_prep_lock.unlock()
			return
		var q: Array = _prep_queue.pop_front()
		_runner_current[n] = String(q[0])
		_prep_lock.unlock()
		_prep_task(String(q[0]), q[1], q[2], q[3], String(q[4]), String(q[5]))
		_prep_lock.lock()
		_runner_current.erase(n)
		_prep_lock.unlock()

## Round 762: a request in the queue -- before every prewarm request (`low`,
## q[6]) unless it is one itself.
func _enqueue(q: Array) -> void:
	prep_stats["tasks"] += 1
	_prep_lock.lock()
	var at := -1
	if not bool(q[6]):
		for i in _prep_queue.size():
			if bool((_prep_queue[i] as Array)[6]):
				at = i
				break
	if at >= 0:
		_prep_queue.insert(at, q)
	else:
		_prep_queue.append(q)
	_prep_lock.unlock()

## The task: the body's template if `scratch` is null (none yet), then each of
## `items` assembled onto it, each failed `_r` / `_f` model's fallback too.
## Plain results only; adopted on the main thread (_finish_prep).
func _prep_task(key: String, scratch: Skeleton3D, canon: Skin, items: PackedStringArray, group: String = "", bsr_path: String = "") -> void:
	if bsr_path == "":
		bsr_path = key
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
		"usec": Time.get_ticks_usec() - sw, "bsr": bsr_path, "asked": items}
	_prep_lock.lock()
	_prep_done[key] = result
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
			_efp_gen += 1
			n += 1
		elif not EfpEffect.is_preloading(e):
			# Neither decoded nor on its way: evicted before it was seen (the
			# review's F4). Dropped, and the generation bumped, so the next
			# ask preloads it again.
			_efp_waiting.erase(e)
			prep_generation += 1
			_efp_gen += 1
	# Round 762: adopted ADOPT_BUDGET_USEC a call at most (one at least): more
	# requests finish together now that a crowd's items are made in chunks.
	var t0 := Time.get_ticks_usec()
	_prep_lock.lock()
	var done := _prep_done.keys()
	_prep_lock.unlock()
	for key in done:
		if n > 0 and Time.get_ticks_usec() - t0 >= ADOPT_BUDGET_USEC:
			break
		_finish_prep(String(key), true)
		n += 1
	_reap_runners()
	_start_queued()
	return n

## The runners that ended, waited for; a request one was making when a script
## error stopped it is finished with no result (asked again by its kinds).
func _reap_runners(wait: bool = false) -> void:
	for id in _runners.keys():
		if not wait and not WorkerThreadPool.is_task_completed(int(id)):
			continue
		PoolWait.task(int(id))
		var n: int = _runners[id]
		_runners.erase(id)
		_prep_lock.lock()
		var lost = _runner_current.get(n)
		_runner_current.erase(n)
		var has_result := lost != null and _prep_done.has(lost)
		_prep_lock.unlock()
		if lost != null and not has_result and _prep_tasks.has(lost):
			_finish_prep(String(lost), true)
	_prep_running = _runners.size()

## Waits for every task (a teardown, the tests); adopts what they made when
## `adopt`, else frees it. With `adopt`, queued requests run too, one after
## another; without, they are dropped.
func wait_prepared(adopt: bool = true) -> void:
	if not adopt:
		_prep_lock.lock()
		var queued := _prep_queue.duplicate()
		_prep_queue.clear()
		_prep_lock.unlock()
		for q in queued:
			if q[1] != null and is_instance_valid(q[1]):
				(q[1] as Node).free()
			_prep_tasks.erase(q[0])
			_forget_asked(q[3], String(q[5]))
	while true:
		_reap_runners(true)
		_prep_lock.lock()
		var done := _prep_done.keys()
		_prep_lock.unlock()
		for key in done:
			_finish_prep(String(key), adopt)
		_prep_lock.lock()
		var left := _prep_queue.size()
		_prep_lock.unlock()
		if left == 0 and _runners.is_empty():
			break
		_start_queued()
	# Anything still listed has no request behind it any more.
	_prep_tasks.clear()

## Whether a template task is still running.
func preparing() -> bool:
	return not _prep_tasks.is_empty()

## QA (round 762): the requests' state, and one kind's.
func prep_debug() -> String:
	_prep_lock.lock()
	var q := _prep_queue.size()
	var d := _prep_done.size()
	_prep_lock.unlock()
	return "tasks %d queued %d done-unadopted %d runners %d efp_waiting %d inflight %d kinds %d stats %s" % [_prep_tasks.size(), q, d,
		_runners.size(), _efp_waiting.size(), _items_inflight.size(), _kind_preps.size(), str(prep_stats)]

func kind_debug(kind: String) -> String:
	var kp: KindPrep = _kind_preps.get(kind)
	if kp == null:
		return "-"
	return "bsr %s built %s task %s missing %s efps %s seen %s gen %s" % [kp.bsr.get_file(), str(_body_templates.has(kp.bsr)),
		str(_prep_tasks.has(kp.bsr)), str(kp.missing), str(kp.efps), str(kp.seen), str(_kind_gen(kp))]

## Round 762: whether anything is on its way that poll_prepared adopts or
## notices: a template request, or a glow's particle file being decoded.
func awaiting() -> bool:
	return not _prep_tasks.is_empty() or not _efp_waiting.is_empty()

## Round 762: called with each template adopted on the main thread (a body's
## skeleton, an item's node): World3D has CrowdGpu make the far twins'
## shaders of its materials then (CrowdGpu.prewarm_node), not with the first
## ghost that draws them.
var adopted_hook := Callable()

func _finish_prep(key: String, adopt: bool) -> void:
	_prep_tasks.erase(key)
	_prep_lock.lock()
	var r = _prep_done.get(key)
	_prep_done.erase(key)
	_prep_lock.unlock()
	# Every finish, a result or none (a task that hit a script error writes
	# none), is news to a caller that cached "not ready" (round 748's review,
	# F4): asked again, the kind gets a new task instead of waiting for an
	# unrelated adoption.
	prep_generation += 1
	var bsr_path := String(r["bsr"]) if r != null else (key if not key.begins_with(ITEM_TASK_PREFIX) else "")
	_bsr_gen[bsr_path] = int(_bsr_gen.get(bsr_path, 0)) + 1
	var asked = _item_tasks.get(key)
	_item_tasks.erase(key)
	if asked != null:
		_forget_asked(asked[0], String(asked[1]))
	if r == null:
		return
	if not adopt:
		_free_prepared(r)
		return
	var res: Dictionary = r
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
			if made != null and adopted_hook.is_valid():
				adopted_hook.call(made.skeleton)
		# Round 762: the kinds that waited for it ask for their items now.
		var waiting = _kinds_on_body.get(bsr_path)
		_kinds_on_body.erase(bsr_path)
		if waiting != null:
			for kp in waiting:
				if not (kp as KindPrep).ready:
					_kind_check(kp)
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
		var ikey := _item_key(tmpl, bsr_path, lower)
		if _item_templates.has(ikey):
			if node != null:
				node.free()
			continue
		if node != null and task_skin != null and tmpl.canonical_skin != null and task_skin != tmpl.canonical_skin:
			_reskin(node, task_skin, tmpl.canonical_skin)
		_item_templates[ikey] = node
		stats["item_assemblies"] += 1
		prep_stats["items"] += 1
		if node != null and adopted_hook.is_valid():
			adopted_hook.call(node)
		if node != null:
			_item_attachables[lower] = pair[1]
	var lk := _layout_key(tmpl, bsr_path)
	_layout_gen[lk] = int(_layout_gen.get(lk, 0)) + 1

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

## The reinforced items already logged as drawn plain (round 786), "code+plus".
static var _plain_logged := {}

## Round 734: the weapon or shield's glow and particles at its plus
## (EquipGlow), on the nodes just hung. Sets wear["glow"] to the row's plus
## (0: none) and wear["glow_fx"] to the effects attached.
func _apply_glow(wear: Dictionary) -> void:
	wear["glow"] = 0
	wear["glow_fx"] = 0
	var slot := int(wear["slot"])
	if not glow_enabled or glow_tables == null or (slot != SLOT_WEAPON and slot != SLOT_SHIELD):
		return
	var code := glow_code_of(wear)
	if code == "" or (wear["nodes"] as Array).is_empty():
		return
	var plus := int(wear["plus"])
	var row := glow_tables.glow_row(code, plus)
	var rows := glow_tables.particle_rows(fx_code_of(wear), plus)
	if row == null and rows.is_empty():
		# Round 786: say why a reinforced weapon or shield is drawn plain, once
		# per item and plus (the user's +12 Test Items gear was the archive's
		# locked Seal of Nova rows, which no table lists).
		if plus != 0 and not _plain_logged.has("%s+%d" % [code, plus]):
			_plain_logged["%s+%d" % [code, plus]] = true
			print("CharacterAppearance: " + glow_tables.describe(code, plus))
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
			list.append({"slot": slot, "code": wear.get("code", ""), "glow_code": glow_code_of(wear), "fx_code": fx_code_of(wear), "plus": int(wear["plus"]), "nodes": wear["nodes"]})
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
		var redo := {"slot": wear["slot"], "code": wear["code"], "glow_code": glow_code_of(wear), "fx_code": fx_code_of(wear), "plus": plus, "nodes": nodes}
		_apply_glow(redo)
		# EquipGlow.clear took the item's own particles too (round 794).
		WornItemFx.apply(nodes, skel, _particles_archive(), String(wear["code"]))
		wear["plus"] = plus
		wear["nodes"] = nodes
		n += 1
	return n

func _particles_archive() -> Pk2Reader:
	if particles == null and not _particles_tried:
		_particles_tried = true
		particles = AssetArchives.particles()
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
		# Round 794: its particles and clips, on every copy (WornItemFx).
		WornItemFx.note_template(node, attached)
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
	# Round 789: a catalogue entry has no TypeID word or Param7, which an
	# avatar's visual row is found by: the full table is read for one.
	if _items.has(id) and ((_items[id] as Dictionary).has("word") or _full_items_loaded or _media == null
			or not _is_avatar_type((_items[id] as Dictionary).get("type_ids", PackedInt32Array()))):
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
			_items[int(rid)] = _info_of(item)
		_inherit_glow(rows)
		stats["item_table_usec"] = Time.get_ticks_usec() - t0
		stats["item_table_rows"] = rows.size()
	return _items.get(id, {})

## What build() keeps of an item row (round 789: its TypeID word and Param7
## for the visual arbitration).
static func _info_of(item: ItemTableReader.Item) -> Dictionary:
	return {"models": item.model_paths, "type_ids": item.type_ids, "code": item.code_name,
		"word": item.type_word(), "param7": item.param7}

static func _is_avatar_type(t: PackedInt32Array) -> bool:
	return t.size() >= 3 and t[0] == 3 and t[1] == 1 and t[2] == 13
