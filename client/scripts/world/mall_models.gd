extends RefCounted
class_name MallModels

## Round 837: the item mall preview's provider (MallPreview.setup). It holds a
## reference to the World3D node and calls the world's own builders, so the
## preview's body is the world's body and its pets are the world's pets: a new
## dressed copy of the player (World3D._build_assembled_character, the paper
## doll's builder), a COS model from the world's monster templates
## (World3D._cos_build_body's path), the stand clips from the same tables, and
## the player's facts the can-equip test reads. World3D itself is not changed.
##
## The contract MallPreview calls (any object with these methods will do; the
## test hands it a synthetic one):
##
##   item(ref_id) -> ItemTableReader.Item         the item row, or null
##   char_ref(code) -> Dictionary                 {"id", "type_word", "scale"} of a
##                                                characterdata row by CodeName, or {}
##   player_facts() -> Dictionary                 {"ref", "sex", "country", "level",
##                                                "str", "int"}
##   worn_avatars() -> Array                      the five avatar slots' RefItemIDs
##                                                (0 = empty), slot 0..4
##   build_body(avatars: Array) -> Dictionary     {"node": Skeleton3D, "stand": clip}:
##                                                a new copy of the player's dressed
##                                                body wearing these avatars
##   build_cos(cos_ref: int) -> Dictionary        {"node": Skeleton3D, "stand": clip}
##   ref_scale(ref_id) -> float                   characterdata Scale / 100 (+0x110)
##   mastery_level(id) -> int                     the player's mastery level, -1 unknown
##   zone_light() -> Array                        [diffuse channel, ambient channel] or []
##
## Labels as the codebase uses them: READ (address), MEASURED, INFERRED, OURS.

var world: Node = null

## code -> {"id", "type_word", "scale"} for every characterdata row whose code
## starts CHAR_ or COS_ (the two kinds the preview makes, 0x561780: a PC or a
## COS), parsed once on a worker thread (OURS: CosTable keeps neither the
## Scale column nor the CashItem / Bionic bits the COS test reads).
static var _refs: Dictionary = {}
static var _refs_key := ""
static var _refs_task := -1
static var _refs_box: Array = [{}]

## characterdata columns (0-based, the indices CharCatalog / CosTable use):
## 1 ID, 2 CodeName, 7 CashItem, 8 Bionic, 9..12 TypeID1..4, 48 Scale
## (docs/protocol/characterdata.md: +0x110, "CICMonster uses it as scale /
## 100"; READ for the preview at 0x55e550).
const COL_ID := 1
const COL_CODE := 2
const COL_CASH := 7
const COL_BIONIC := 8
const COL_TYPE1 := 9
const COL_SCALE := 48

func _init(world_node: Node = null) -> void:
	world = world_node
	_start_refs()

# --- items and refs -----------------------------------------------------------

func item(ref_id: int) -> ItemTableReader.Item:
	if world == null:
		return null
	var rows = world.get("_item_rows")
	return (rows as Dictionary).get(ref_id) if rows is Dictionary else null

## A characterdata row by CodeName -- what 0x9461a0 looks up for a COS item's
## string at ref +0x304. That string is the item's Desc1 (itemdata column
## 119): MEASURED on this archive, every 3/2/1/1 (37 ids) and 3/2/1/2 (21 ids)
## row names a `COS_` code there (ITEM_COS_P_FLUTE_SILK -> COS_P_WOLF_001,
## ITEM_COS_P_SEOWON_SCROLL -> COS_P_SEOWON); INFERRED that +0x304 is that
## column (the only string column holding a COS code).
func char_ref(code: String) -> Dictionary:
	if code == "":
		return {}
	var refs := _wait_refs()
	if refs.has(code):
		return refs[code]
	# No characterdata parse (no archive path): the world's COS rows, whose
	# Bionic bit is taken as set (MEASURED: all 5,040 + 14 pet ids carry
	# Bionic 1) and whose Scale is unknown (1.0).
	var table = world.get("_cos_table") if world != null else null
	if table is CosTable:
		var row: CosTable.Row = (table as CosTable).by_code.get(code)
		if row != null:
			return {"id": row.id, "type_word": 2 | (1 << 2) | (2 << 5) | (3 << 7) | (row.type4 << 11), "scale": 1.0}
	return {}

## ref +0x110 / 100, exactly 1.0 when the column is 100 (READ 0x55e550: the
## 100 test at 0x55e560 skips the division).
func ref_scale(ref_id: int) -> float:
	var refs := _wait_refs()
	for code in refs:
		var r: Dictionary = refs[code]
		if int(r["id"]) == ref_id:
			return float(r["scale"])
	return 1.0

# --- the player ------------------------------------------------------------------

## The facts 0x8bb570 compares an item with. READ (0x8bb570 disassembly):
## gender and race are the player's own characterdata row's +0x1c4 (column 58)
## and +0x9c (column 14, Country); the level is the player's byte +0x868, Str
## and Int its words +0x87c / +0x87e (the stat panel's, player_mini_info.md).
func player_facts() -> Dictionary:
	var out := {"ref": 0, "sex": CharCatalog.SEX_MAN, "country": CharCatalog.RACE_CHINA, "level": 0, "str": 0, "int": 0}
	if world == null:
		return out
	var body := String(world.get("_player_body"))
	var assets: Dictionary = world.call("_body_assets", body) if body != "" else {}
	var ref := int(assets.get("ref", 0))
	out["ref"] = ref
	out["sex"] = CharCatalog.SEX_WOMAN if bool(assets.get("woman", false)) else CharCatalog.SEX_MAN
	var countries = world.get("_country_by_code")
	if countries is Dictionary and (countries as Dictionary).has(body):
		out["country"] = int(countries[body])
	else:
		out["country"] = int(assets.get("race", CharCatalog.RACE_CHINA))
	out["level"] = int(world.get("_player_level"))
	var info = world.get("_hud_player_info")
	if info != null and is_instance_valid(info):
		out["str"] = String(info.call("stat_value", "GDR_PMI_TXT_STRDAT")).to_int()
		out["int"] = String(info.call("stat_value", "GDR_PMI_TXT_INTDAT")).to_int()
	return out

## The equipment window's five avatar slots (pEquip + 0x5f8 + i * 0x1d0,
## READ 0x6ab800, i < 5): the avatar inventory's slots 0..4, which World3D
## keeps under CharacterAppearance.AVATAR_KEY_BASE + slot.
func worn_avatars() -> Array:
	var out := [0, 0, 0, 0, 0]
	if world == null:
		return out
	var avatars = world.get("_player_avatars")
	if avatars is Dictionary:
		for key in avatars:
			var slot := int(key) - CharacterAppearance.AVATAR_KEY_BASE
			if slot >= 0 and slot < 5:
				out[slot] = int(avatars[key])
	return out

## The player's masteries for 0x8bb570 bit 0x100 (SkillStructureByServer::
## FUN_009c1180). OPEN here: the preview does not mirror the client's skill
## structure, so -1 ("not found"), which the client's loop skips -- no avatar
## row asks for one (MEASURED by mall_preview_test.gd: no ReqLevelType over 10
## on any avatar or devil-spirit row of this archive).
func mastery_level(_id: int) -> int:
	return -1

func zone_light() -> Array:
	var z = world.get("_portrait_zone_light") if world != null else null
	return (z as Array).duplicate() if z is Array else []

# --- the models -------------------------------------------------------------------

## A new copy of the player's dressed body (0x561930: a new body from the
## player's RefObj, dressed from the equipment window's avatar by 0xa617d0
## mode 0) wearing `avatars` (RefItemIDs). The nine equipment slots carry
## their plus (InstallEquipVisual(slot, id, plus, 0)); the avatars none
## (0xa60ef0(ref) takes no plus, READ 0xa617d0 / 0x9daf80). Scale byte, body
## and equipment are the world's own (the paper doll's). The STAND clip is the
## body's action 0 in the held weapon's group (BodyAnimations, as the doll).
func build_body(avatars: Array) -> Dictionary:
	if world == null:
		return {}
	var body := String(world.get("_player_body"))
	# Round 843: the worn items as the world and the equipment window draw
	# them -- a model switcher's choice as its row (World3D._display_equipped),
	# with the item's own glow and seal where that row has none (_player_fx).
	var equipped: Dictionary = (world.call("_display_equipped", (world.get("_player_equipped_last") as Dictionary).duplicate()) as Dictionary).duplicate()
	for key in equipped.keys():
		if CharacterAppearance.is_avatar_key(int(key)):
			equipped.erase(key)
	var pluses := {}
	var world_pluses = world.get("_player_pluses_last")
	if world_pluses is Dictionary:
		for key in world_pluses:
			if not CharacterAppearance.is_avatar_key(int(key)):
				pluses[key] = world_pluses[key]
	var dressed := equipped.duplicate()
	var k := 0
	for ref in avatars:
		if int(ref) != 0:
			# OURS keys: build() reads an avatar from its type, never its key.
			dressed[CharacterAppearance.AVATAR_KEY_BASE + k] = int(ref)
			k += 1
	var skel = world.call("_build_assembled_character", dressed, body, int(world.get("_player_scale")), pluses, world.call("_player_fx"))
	if skel == null:
		return {}
	var b := String((skel as Node).get_meta("body", body))
	var group := String(world.call("_weapon_group_for", equipped, b))
	var stand = world.call("_body_animation_for", b, BsrReader.AnimationEntry.TYPE_STAND, group)
	return {"node": skel, "stand": stand}

## A COS model (the world's own: _cos_build_body's template path, its material
## slot by the COS rule, its ambient particle set) and its action 0 (STAND).
func build_cos(cos_ref: int) -> Dictionary:
	if world == null:
		return {}
	var table = world.get("_cos_table")
	var row: CosTable.Row = (table as CosTable).row(cos_ref) if table is CosTable else null
	if row == null or row.model == "":
		return {}
	world.call("_monster_model_path", "", "")
	var textures = world.get("_monster_texture_by_code")
	var tex := int((textures as Dictionary).get(row.code, 0)) if textures is Dictionary else 0
	var model := MonsterDraw.template_key(row.model, NpcTableReader.texture_slot(tex, 0, true))
	var templates = world.get("_monster_templates")
	if not (templates is MonsterDraw.Templates):
		return {}
	var hook = world.get("_monster_assemble")
	var assemble: Callable = hook if hook is Callable and (hook as Callable).is_valid() else Callable(world, "_assemble_monster_model")
	var assembled: SkinnedBsrAssembler.AssembledCharacter = (templates as MonsterDraw.Templates).instance(model, assemble)
	if assembled == null or assembled.skeleton == null:
		return {}
	var data = world.get("_data_pk2")
	if data == null:
		data = world.call("_open_pk2_if_set")
	var stand: BanReader.ParsedAnimation = null
	if data != null:
		stand = SkinnedBsrAssembler.animation_for(data, assembled, BsrReader.AnimationEntry.TYPE_STAND)
	var particles = world.call("_open_particles_pk2_if_set")
	if particles != null:
		BodyFx.attach_ambient(assembled.skeleton, assembled.parsed, particles)
	return {"node": assembled.skeleton, "stand": stand}

# --- the characterdata refs (worker thread) ----------------------------------------

func _media() -> Pk2Reader:
	if world == null:
		return null
	var m = world.get("_media_pk2")
	if m == null:
		m = world.call("_open_media_pk2_if_set")
	return m as Pk2Reader

func _start_refs() -> void:
	var media := _media()
	if media == null:
		return
	var key := media.source_path if "source_path" in media else str(media.get_instance_id())
	if key == _refs_key and (_refs_task >= 0 or not _refs.is_empty()):
		return
	_refs_key = key
	_refs = {}
	_refs_box = [{}]
	_refs_task = WorkerThreadPool.add_task(_parse_task.bind(media, CharTables.table_paths(media), _refs_box),
		true, "mall preview refs")

static func _parse_task(media: Pk2Reader, paths: PackedStringArray, box: Array) -> void:
	var out := {}
	for path in paths:
		var entry := ObjectLoader.find_file(media, path)
		if entry == null:
			continue
		parse_refs(media.read_file(entry), out)
	box[0] = out

func _wait_refs() -> Dictionary:
	if _refs_task >= 0:
		PoolWait.task(_refs_task)
		_refs_task = -1
		_refs = _refs_box[0]
	return _refs

## One characterdata part's CHAR_ and COS_ rows into `into` (a later row
## replaces an earlier one, as the client keeps the last).
static func parse_refs(data: PackedByteArray, into: Dictionary) -> void:
	for line in NpcTableReader._lines(data):
		if not (line.contains("\tCOS_") or line.contains("\tCHAR_")):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_SCALE:
			continue
		var code := cols[COL_CODE].strip_edges()
		if not (code.begins_with("COS_") or code.begins_with("CHAR_")):
			continue
		var tw := (cols[COL_CASH].to_int() & 1) | ((cols[COL_BIONIC].to_int() & 1) << 1) \
			| ((cols[COL_TYPE1].to_int() & 7) << 2) | ((cols[COL_TYPE1 + 1].to_int() & 3) << 5) \
			| ((cols[COL_TYPE1 + 2].to_int() & 15) << 7) | ((cols[COL_TYPE1 + 3].to_int() & 31) << 11)
		var pct := cols[COL_SCALE].to_int()
		into[code] = {"id": cols[COL_ID].to_int(), "type_word": tw,
			"scale": 1.0 if pct == 100 else float(pct) / 100.0}
