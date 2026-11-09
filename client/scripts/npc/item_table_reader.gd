extends RefCounted
class_name ItemTableReader

## Reads the item tables in the player's own Media.pk2: an item's name and
## inventory icon, **the model it is worn as**, and who may wear it.
##
## `server_dep\silkroad\textdata\itemdata*.txt` is UTF-16LE, tab separated,
## ~160 columns wide and split across numbered parts. The icon is found by
## content (the one `.ddj` in a row); everything else is by column, and
## the columns are the game's own `_RefObjCommon`/`_RefObjItem` layout,
## checked against real rows -- see docs/protocol/ITEM_FORMAT.md:
##
##   1 id   2 code name   3 display name   9-12 type ids
##   14 country   32/33 required level type and level (+ three more pairs)
##   52 worn model `.bsr`   53 drop model `.bsr`   54 icon `.ddj`
##   58 required gender
##
## The worn model is the whole reason this project can dress a character
## from the id the server sends: `4842 Cotton Suit` reads
## `item\china\man_item\clothes_01_ba.bsr`, and that file names the mesh,
## the material and -- for a weapon or a shoulder piece -- its own skeleton
## and the body bone it hangs from. The models live under `res\` in
## Data.pk2, the prefix the tables omit (see SkinnedBsrAssembler._read).
##
## The icon path is stored relative to `icon\`: a row reads
## `item\china\man_item\clothes_01_ba.ddj` and the file lives at
## `icon\item\china\man_item\clothes_01_ba.ddj`. A real archive holds 5,370
## of them.

## **Which parts** (round 741). The client loads the parts its index file
## `textdata\itemdata.txt` names, in that order (MEASURED on the retail
## Media.pk2: ItemData_1000.txt .. ItemData_63000.txt, 63 names; the archive
## also holds itemdata_55500.txt, which no index line names and which is not
## read). Until round 741 this reader had a hand-kept list of seven paths --
## the index itself and 5000..30000 -- so every item defined in another part
## (the Seal of Nova spear 62607 lives in itemdata_45000.txt) had no name, no
## icon and no model: invisible in the inventory and in the hand.
## `table_paths` reads the index (CharCatalog.index_part_names, the same
## reading the character catalogue uses); `load_all` parses every part once
## per archive and every consumer shares the result.
##
## LEGACY_TABLE_PATHS is only the fallback for an archive with no index file
## (the old list, kept so a partial or repacked archive still yields rows).
static var LEGACY_TABLE_PATHS := [
	"server_dep\\silkroad\\textdata\\itemdata_5000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_10000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_15000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_20000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_25000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_30000.txt",
]

## Every itemdata part `media` holds, as full archive paths, in the order the
## index names them; the legacy list when the archive has no index.
static func table_paths(media: Pk2Reader) -> PackedStringArray:
	var out := PackedStringArray()
	for name in CharCatalog.index_part_names(media, CharCatalog.ITEM_INDEX):
		out.append(CharCatalog.TEXTDATA_DIR + name)
	if out.is_empty():
		out = PackedStringArray(LEGACY_TABLE_PATHS)
	return out

## The archive whose rows `_shared` holds, by its file path (two handles on
## one Media.pk2 -- the world's and the UI builder's -- share one parse).
static var _shared_key := ""
static var _shared: Dictionary = {}
## How long the last fresh `load_all` took, and how many parts it read
## (the world's boot log line).
static var last_load_usec := 0
static var last_load_parts := 0

## Every item row of `media`, {id -> Item}, parsed once per archive and
## shared: callers must treat it as read-only. Later parts replace earlier
## definitions of an id, as `parse` merges.
static func load_all(media: Pk2Reader) -> Dictionary:
	if media == null:
		return {}
	var key := _key_of(media)
	last_wait_usec = 0
	if key == _shared_key:
		last_source = "shared"
		return _shared
	if _pending_task >= 0 and _pending_key == key:
		# Started by preload_async: wait for it rather than parse twice.
		var tw := Time.get_ticks_usec()
		PoolWait.task(_pending_task)
		_pending_task = -1
		last_wait_usec = Time.get_ticks_usec() - tw
		_shared_key = key
		_shared = _pending_box[0]
		_pending_box = [{}]
		last_source = "preload"
		return _shared
	# A preload for ANOTHER archive is still under way: let it finish first,
	# so its result is not lost (the review's finding 5).
	wait_pending()
	var rows := _read_all(media)
	_shared_key = key
	_shared = rows
	last_source = "parsed"
	return rows

## Waits for a preload under way and keeps its rows as the shared ones (round
## 746, the review's finding 5): a world that leaves the tree before it asks
## for the rows (World3D._exit_tree) or a load of another archive. A no-op
## when none is pending.
static func wait_pending() -> void:
	if _pending_task < 0:
		return
	PoolWait.task(_pending_task)
	_pending_task = -1
	_shared_key = _pending_key
	_shared = _pending_box[0]
	_pending_box = [{}]

## Starts parsing every part of `media` on a worker thread (round 741: 63
## parts cost ~1.7 s of GDScript on the render box, MEASURED), so the world
## can overlap it with its other boot work; `load_all` then waits for it. A
## no-op when the rows are already shared or a parse is under way.
static func preload_async(media: Pk2Reader) -> void:
	if media == null:
		return
	var key := _key_of(media)
	if key == _shared_key or _pending_task >= 0:
		return
	_pending_key = key
	var box: Array = [{}]
	_pending_box = box
	_pending_task = WorkerThreadPool.add_task(func() -> void:
		box[0] = ItemTableReader._read_all(media), false, "itemdata parts")

static var _pending_task := -1
static var _pending_key := ""
## The worker's result: [rows], filled when the task ends.
static var _pending_box: Array = [{}]
## How long the last `load_all` waited for a preload, microseconds.
static var last_wait_usec := 0
## Where the last `load_all`'s rows came from: "shared" (parsed by an earlier
## call; no parse now), "preload" (the worker's parse) or "parsed" (now, on
## the caller's thread). The boot log line says which (the review's finding 6).
static var last_source := ""

## Round 789: Pk2Reader.cache_key -- the file, plus the AssetArchives set's
## generation when packs overlay it, so a reload with new packs parses again.
static func _key_of(media: Pk2Reader) -> String:
	return media.cache_key()

static func _read_all(media: Pk2Reader) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var rows := {}
	var parts := 0
	for path in table_paths(media):
		var entry := ObjectLoader.find_file(media, path)
		if entry == null:
			continue
		parse(media.read_file(entry), rows)
		parts += 1
	last_load_usec = Time.get_ticks_usec() - t0
	last_load_parts = parts
	return rows

## Drops the shared rows (tests).
static func clear_shared() -> void:
	if _pending_task >= 0:
		PoolWait.task(_pending_task)
		_pending_task = -1
	_pending_box = [{}]
	_shared_key = ""
	_shared = {}

## Icon paths in the table are relative to this directory in Media.pk2.
const ICON_PREFIX := "icon\\"

## Column 1 is the id, column 2 the code name, column 3 an internal object
## name and column 5 the name **string id** (`SN_ITEM_*`). Column 3 is written
## in mixed languages -- English for weapons ("Copper Sword"), Korean for many
## consumables -- so the display name comes from column 5 resolved through
## textdata_object.txt (English), with column 3 the fallback. Confirmed against
## real rows: HP_POTION_05's col3 is Korean while col5 is SN_ITEM_ETC_HP_POTION_05,
## which textdata_object gives as "HP Recovery Potion (X-Large)".
const COL_ID := 1
const COL_CODE_NAME := 2
const COL_NAME := 3
const COL_NAME_STRID := 5
## OrgObjCodeName (column 4): the code name of the item this one is a variant
## of, `xxx` for none (read as "", as the client's wide reader stores it:
## docs/protocol/characterdata.md). The glow tables inherit through it (round
## 740, ItemGlowTables.inherit).
const COL_ORG_CODE_NAME := 4
## SellPrice (column 31): what the NPC pays to buy an item back -- real, and
## under the buy price on every row (Copper Sword 890 buy / 427 sell). Shown as
## the estimate in the sell confirm; the server's result carries the true gold.
const COL_SELL_PRICE := 31
## KeepingFee (round 728): the warehouse fee a unit. The column is READ on the
## server (RefObjCommon_ExtractData gs:0x6a3090 -> ref +0xac; round 728
## review); the client's deposit box reads its reference's +0xcc (0x6b1002),
## not separately mapped.
const COL_KEEPING_FEE := 30
## Round 834: CanTrade, a permission -- 0 forbids (docs/protocol/
## item_capability_flags.md; the client's SOItem::FUN_008baf10 reads ref
## +0xa4 before an exchange offer).
const COL_CAN_TRADE := 16
## Round 838: CanUse, the byte at ref +0xac (READ, GlobalDataManager::
## FUN_00972910 0x972b76). A right-click on a 3/3/13 tool whose byte has 0x81
## set picks a target item first (IFSlotWithHelp::FUN_00676570, 0x6769a5).
const COL_CAN_USE := 24
## MaxStack (column 57): 1 for equipment, the real per-item cap for stackables
## (a potion 5000, arrows 2500) -- so the shop can offer buying a stack.
const COL_MAX_STACK := 57
const COL_TYPE_ID1 := 9
## CashItem and Bionic: bits 0 and 1 of the type word the TypeIDs pack into
## (docs/protocol/characterdata.md, cols 7-12 -> +0x00).
const COL_CASH_ITEM := 7
const COL_BIONIC := 8
const COL_TYPE_ID4 := 12
## `Country`: 0 for the China race's items, 1 for Europe's.
const COL_COUNTRY := 14
## Four (type, level) requirement pairs. Type 1 with level 1 is what every
## starter item carries; what the other type values ask for is
## characterised in ITEM_FORMAT.md rather than assumed here.
const COL_REQ_LEVEL_TYPE1 := 32
const COL_REQ_LEVEL1 := 33
const COL_MODEL := 52
const COL_DROP_MODEL := 53
## `ReqGender`: 1 for a man's item, 0 for a woman's, 2 for either.
const COL_REQ_GENDER := 58

## Weapon stat columns, each read as a group of four where the item's own
## value is [0] and its upper bound [2] -- the display is `[0] ~ [2]`.
## Anchored against a real Copper Sword (+5) tooltip: its physical attack
## base is 15~16 (columns below) and grows 2.4 a plus, so +5 shows 27~28;
## its magical attack base 25~28 grows 4.1, so +5 shows 45~48; and the
## reinforce, rate and critical columns read 306/342 (30.6~34.2%),
## 519/591 (51.9~59.1%), 24 and 3 -- every figure the tooltip showed, in
## these columns, with no fudge. See ITEM_FORMAT.md and WORLD_ISSUES.md.
## Durability is common to every equippable item; the rest are weapons.
const COL_DURABILITY := 63
## Range: a weapon's reach in world units (tenths of a metre) -- the item
## ref's u16 at +0x224, which Char_PublishCombatStats publishes as param 33
## and the attack tick adds to the two BCRadius values
## (CGCharAutoCommandActor::Tick_Attack 0x004ad8e0; round 247). Retail rows
## read sword/blade 6, spear/glaive 18, bow/crossbow 180, dagger 3. The same
## column the server's exporter reads (export-refdata fRange = 94).
const COL_RANGE := 94
## Param1, itemdata column 118 (the export's fParam1).
const COL_PARAM1 := 118
## Round 768, the alchemy window's checks (alchemy_window.gd): Desc128_1 (a
## magic stone's MATTR_ name, an attribute stone's NATTR_ name), Desc128_4 (an
## attribute stone's class list, "armor,shield") and Param5 (an elixir's
## second TypeID3 set, gs CEnchant_Reinforce slot 4 0x505cb0).
const COL_DESC1 := 119
const COL_DESC4 := 125
const COL_PARAM5 := 126
const COL_PHYS_ATK_MIN := 95
const COL_PHYS_ATK_MAX := 97
const COL_MAG_ATK_MIN := 100
const COL_MAG_ATK_MAX := 102
const COL_PHYS_REINFORCE_MIN := 105
const COL_PHYS_REINFORCE_MAX := 107
const COL_MAG_REINFORCE_MIN := 109
const COL_MAG_REINFORCE_MAX := 111
const COL_ATTACK_RATE := 113
const COL_CRITICAL := 116

## Armour defence columns, a separate block from the weapon attack columns
## above (weapons leave these 0; armour leaves the attack columns 0). Grounded
## from the real DB _RefObjItem column order documented in
## docs/protocol/refdata_schema.md -- PD (physical defence), ER, PAR, BR (block,
## shields), MD (magical defence) -- which lines up with these positions in the
## data, and is confirmed by the cloth-vs-heavy relationship (cloth armour has
## more magical defence, heavy armour more physical). Each defence is a min/max
## pair (the +0 range, like the weapon block); the values are floats (2 ~ 2.5).
const COL_PHYS_DEF_MIN := 65
const COL_PHYS_DEF_MAX := 66
const COL_BLOCK_MIN := 74
const COL_BLOCK_MAX := 75
const COL_MAG_DEF_MIN := 76
const COL_MAG_DEF_MAX := 77

## Round 731 (the item tooltip, docs/protocol/item_tooltip.md): the columns the
## original's tooltip reads that this reader did not, MEASURED against real
## rows (a Pearl Necklace reads 17.4 ~ 18.0, 0.3 in 71-73 and 79-81; a D11
## spear 31 in 61, 9 in 158; a heavy armour 21 ~ 63 in 68-69). Rarity is
## _RefObjCommon's column 15 (2 the seal items, 3 the set items, 6 seal).
const COL_RARITY := 15
const COL_REQ_STR := 59
const COL_REQ_INT := 60
const COL_ITEM_CLASS := 61
const COL_SET_ID := 62
const COL_DURABILITY_MAX := 64
const COL_PARRY_MIN := 68
const COL_PARRY_MAX := 69
const COL_PHYS_ABSORB_MIN := 71
const COL_PHYS_ABSORB_MAX := 72
const COL_MAG_ABSORB_MIN := 79
const COL_MAG_ABSORB_MAX := 80
const COL_MAX_MAGIC_OPTIONS := 158
## Round 789 (avatars; /root/opensro-pk3av789/AVATAR_RESEARCH.md 2.2, 6.1):
## Param2 (120: a devil's spirit's "may be reinforced" flag, the alchemy
## window's 0xe test, AVATAR_ALCHEMY_RESEARCH.md 2), Param7 (130: an avatar's
## body-region mask, the second key of its charactervisualchange row) and
## ChildItemCount (159: a dress that takes an attachment; ref +0x535 on the
## client, INFERRED from its use, READ +0x53d on the server).
const COL_PARAM2 := 120
const COL_PARAM7 := 130
const COL_CHILD_ITEM_COUNT := 159
## Round 826: Param4, and the twenty Param / Desc128 pairs from Param1 (118).
const COL_PARAM4 := 124
const COL_PARAM3 := 122
const COL_PARAM6 := 128
## Round 829 (the repair, RepairQuote): CanRepair (ref +0xaa), CostRepair
## (+0xc0) and CostRevive (+0xc4) -- itemdata columns 22, 27 and 28 (READ,
## GlobalDataManager::FUN_00972910's reads, counted).
const COL_CAN_REPAIR := 22
const COL_COST_REPAIR := 27
const COL_COST_REVIVE := 28
const PARAM_PAIRS := 20

## The row's COOLTIME pair (round 826; READ, the client's item parser
## 0x975a10 at 0x9761a1 keeps the group as wcstol(.., 16) and the Param as
## the re-use ms): the first pair whose Desc128 contains "cooltime" (any
## case) and a ':' with a base-16 number after it, and whose Param is an
## integer -> [group, ms]; [0, 0] for none. The native reader's cooltime_of
## is the same rule.
static func cooltime_of(cols: PackedStringArray) -> Array:
	for k in PARAM_PAIRS:
		var vi := COL_PARAM1 + 2 * k
		if vi + 1 >= cols.size():
			break
		# findn first: no copy of the cell for the 19 pairs of a row that are
		# not one (round 826's perf gate: 20 copies a row cost the GDScript
		# parse 130 ms over 15,338 rows).
		if cols[vi + 1].findn("cooltime") < 0:
			continue
		var desc := cols[vi + 1].strip_edges()
		var colon := desc.find(":")
		if colon < 0:
			continue
		var g := desc.substr(colon + 1).strip_edges()
		if g.to_lower().begins_with("0x"):
			g = g.substr(2)
		if g == "" or not g.is_valid_hex_number(false):
			continue
		var v := cols[vi].strip_edges()
		if not v.is_valid_int():
			continue
		return [g.hex_to_int(), int(v)]
	return [0, 0]
## The per-plus increments, in PLUS_INC_* order: PD 67, ER 70, PAR 73, MD 78,
## MAR 81, phy. atk 99, mag. atk 104, attack rate 115 (the fifth float of each
## group; ITEM_FORMAT.md). Lane B's "(+x%)" subtracts them (item_tooltip.md §2).
static var PLUS_INC_COLS := [67, 70, 73, 78, 81, 99, 104, 115]
enum { PLUS_INC_PD, PLUS_INC_ER, PLUS_INC_PAR, PLUS_INC_MD, PLUS_INC_MAR, PLUS_INC_PA, PLUS_INC_MA, PLUS_INC_HR }
## The upper ends of the int ranges whose lower ends the reader already has
## (phys_atk is (95, 97), each of its two ends a [lower, upper] pair whose
## upper is 96 / 98): the "(+x%)" is 100 on an empty range (item_tooltip.md
## §2), so a reference item's percentage needs them.
const COL_PHYS_ATK_MIN_UPPER := 96
const COL_PHYS_ATK_MAX_UPPER := 98
const COL_MAG_ATK_MIN_UPPER := 101
const COL_MAG_ATK_MAX_UPPER := 103
const COL_PHYS_REINFORCE_MIN_UPPER := 106
const COL_PHYS_REINFORCE_MAX_UPPER := 108
const COL_MAG_REINFORCE_MIN_UPPER := 110
const COL_MAG_REINFORCE_MAX_UPPER := 112
const COL_ATTACK_RATE_UPPER := 114
const COL_CRITICAL_UPPER := 117
## Armour and shield reinforce, PDStr 82/83 and MDInt 84/85: the client's row
## parser (GlobalDataManager::FUN_00975a10) stores them / 1000 at ref
## +0x224..+0x230, and 0x66c5b0 prints them x 100 as the single-value
## reinforce line when the weapon pair is zero (round 731's review, READ).
const COL_ARMOUR_PHYS_REINFORCE_MIN := 82
const COL_ARMOUR_PHYS_REINFORCE_MAX := 83
const COL_ARMOUR_MAG_REINFORCE_MIN := 84
const COL_ARMOUR_MAG_REINFORCE_MAX := 85
## The description key, column 6 (DescStrID128, ref +0x7c): 0x66f850 prints
## its text when the object table resolves it (round 731's review, READ).
const COL_DESC_STRID := 6

## TypeID3 (the item family) values, index 2 of type_ids.
const FAMILY_WEAPON := 6
const CHINA_ARMOUR_FAMILIES := [1, 2, 3]
const EUROPE_ARMOUR_FAMILIES := [9, 10, 11]
## The object-name tables, as the client has them (round 731): its text
## lookups (FUN_008c9bb0 for an object's name, FUN_008c9c30 for a UI key)
## both read TextStringManager's one map (FUN_008c9b20, READ), filled from
## the files textdataname.txt lists -- TextData_Equip&Skill.txt and
## TextData_Object.txt (MEASURED). With the object file alone 4,811 of the
## 11,772 item rows had no name (the raw code showed); with both, 271 -- the
## equip file holds e.g. SN_ITEM_EU_LIGHT_01_HA_A "Sagittarius Savage
## Sallet" (MEASURED, round 731); the two files share no key (MEASURED: 10,893 and 7,814
## keys, 0 in both), so their order does not matter.
## OBJECT_NAME_PATHS is the fallback for an archive without the list file.
static var OBJECT_NAME_PATHS := [
	"server_dep\\silkroad\\textdata\\textdata_object.txt",
	"server_dep\\silkroad\\textdata\\textdata_equip&skill.txt",
]

## The list file itself (round 789). Reading it, as the client does, is what
## lets an asset pack add a name table the way it adds an item part through
## itemdata.txt: the pack's textdataname.txt names one more file (OURS: the
## pack layer, docs/TODO.md "Asset packs"; the list rule is the client's).
const OBJECT_NAME_INDEX := "textdataname.txt"

## The name tables `archive` lists in textdataname.txt, as full paths in its
## order; OBJECT_NAME_PATHS when it has no list.
static func object_name_paths(archive) -> PackedStringArray:
	var out := PackedStringArray()
	if archive != null:
		for name in CharCatalog.index_part_names(archive, OBJECT_NAME_INDEX):
			out.append(CharCatalog.TEXTDATA_DIR + name)
	if out.is_empty():
		out = PackedStringArray(OBJECT_NAME_PATHS)
	return out

## Every listed table parsed and merged (an earlier table's key wins), or null
## when the archive has none.
static func load_object_names(archive) -> UiTextTable:
	var out: UiTextTable = null
	if archive == null:
		return null
	for path in object_name_paths(archive):
		var entry = ObjectLoader.find_file(archive, path)
		if entry == null:
			continue
		var t := UiTextTable.parse(archive.read_file(entry))
		if out == null:
			out = t
		else:
			out.merge_missing(t)
	return out

const REQ_LEVEL_PAIRS := 4

class Item:
	var id: int
	var code_name: String
	## Column 4, OrgObjCodeName; "" for `xxx` (round 740).
	var org_code_name: String = ""
	## The internal object name (column 3): English for weapons, but Korean for
	## many consumables. Prefer display_name(), which resolves the string id.
	var item_name: String
	## The name string id (column 5, `SN_ITEM_*`), resolved through
	## textdata_object.txt for the real English display name.
	var name_strid: String
	## MaxStack (column 57): how many fit in one inventory slot. 1 for
	## equipment; a large cap for stackable consumables/materials.
	var max_stack: int = 1
	## SellPrice (column 31): the NPC buy-back price, for the sell estimate.
	var sell_price: int = 0
	## KeepingFee (column 30, READ): the warehouse deposit fee a unit.
	var keeping_fee: int = 0
	## Round 834: column 16 (COL_CAN_TRADE); true when the table has none.
	var can_trade := true
	## Round 838: column 24 (COL_CAN_USE), the whole byte; 0 when none.
	var can_use: int = 0
	## Archive path of the inventory icon, ICON_PREFIX already applied.
	var icon_path: String
	## The `.bsr` the item is worn as, as the table writes it (no `res\`
	## prefix). Empty for an item with no worn model -- consumables, and a
	## few equipment rows that write `xxx`.
	var model_path: String
	## Every model the column lists, in file order. Almost every row names
	## one; 88 Degree-11 SET_A/SET_B rows name two, comma-separated
	## (`heavy_11_set_b_ba.bsr,heavy_11_set_b_ba_fullset.bsr`). READ in the
	## client (round 626): the row parser (GlobalDataManager::FUN_00972910)
	## splits the column on "," into a list and makes element [0] the drawn
	## model; FUN_00a60c60 switches a worn item to element [1] only while the
	## whole set (refsetitemgroup) is worn, and back to [0] when any piece
	## comes off. model_path is element [0]; the full-set switch is OPEN here.
	var model_paths: PackedStringArray = PackedStringArray()
	## The `.bsr` drawn when the item lies on the ground.
	var drop_model_path: String
	## TypeID1..4 -- the game's own classification, four levels deep.
	var type_ids: PackedInt32Array = PackedInt32Array()
	## CashItem (column 7) and Bionic (column 8), the type word's bits 0 and 1.
	var cash_item: int = 0
	var bionic: int = 0
	var country: int = 0
	var req_gender: int = 0
	## Requirement (type, level) pairs, in table order. A pair whose type
	## is -1 or 0 is unused; type 1 is the character's own level.
	var req_level_types: PackedInt32Array = PackedInt32Array()
	var req_levels: PackedInt32Array = PackedInt32Array()
	## Weapon stats, base (+0). Reinforce is in tenths of a percent, as the
	## table stores it (306 = 30.6%). Zero for a non-weapon.
	var durability: int = 0
	var phys_atk := Vector2i.ZERO
	var mag_atk := Vector2i.ZERO
	var phys_reinforce := Vector2i.ZERO
	var mag_reinforce := Vector2i.ZERO
	var attack_rate: int = 0
	var critical: int = 0
	## The weapon's reach (COL_RANGE), world units; 0 for a non-weapon or a
	## row too short to carry the column.
	var attack_range: int = 0
	## Param1 (column 118; round 632 review): a composite item's (the Energy
	## of life scroll's) duration in seconds, which retail's item-grant
	## gauge reads as its total (ref+0x2b4 x 1000). 0 when the row is short.
	var param1: int = 0
	## Round 768 (COL_PARAM5, COL_DESC1, COL_DESC4); 0 / "" for a short row.
	var param5: int = 0
	var desc1: String = ""
	var desc4: String = ""
	## Armour defence, base (+0), min~max (floats). Zero for a non-defensive
	## item. block is a shield's block ratio.
	var phys_def := Vector2.ZERO
	var mag_def := Vector2.ZERO
	var block := Vector2.ZERO
	## Round 731 (the tooltip's columns, COL_RARITY.. above).
	var rarity: int = 0
	var item_class: int = 0
	var set_id: int = 0
	var durability_max: int = 0
	var req_str: int = 0
	var req_int: int = 0
	var max_magic_options: int = 0
	## Round 789: Param2, Param7 and ChildItemCount (COL_PARAM2 and on).
	var param2: int = 0
	var param7: int = 0
	var child_item_count: int = 0
	## Round 826 (item re-use, ItemCooldowns): Param4 (COL_PARAM4, a potion's
	## MP %), and the COOLTIME pair (cooltime_of): its group and its ms.
	var param4: int = 0
	## Round 869: Param3 and Param6 (a Dimension hole's band minimum and its
	## gate's access type; forgotten_world.md 2).
	var param3: int = 0
	var param6: int = 0
	var cool_group: int = 0
	var cool_ms: int = 0
	## Round 829: COL_CAN_REPAIR, COL_COST_REPAIR, COL_COST_REVIVE.
	var can_repair: int = 0
	var cost_repair: int = 0
	var cost_revive: int = 0
	var parry := Vector2.ZERO
	var phys_absorb := Vector2.ZERO
	var mag_absorb := Vector2.ZERO
	## PLUS_INC_COLS' values, PLUS_INC_* order.
	var plus_incs: PackedFloat32Array = PackedFloat32Array()
	## The upper ends (COL_*_UPPER): each Vector2i is (min's upper, max's upper).
	var phys_atk_upper := Vector2i.ZERO
	var mag_atk_upper := Vector2i.ZERO
	var phys_reinforce_upper := Vector2i.ZERO
	var mag_reinforce_upper := Vector2i.ZERO
	var attack_rate_upper: int = 0
	var critical_upper: int = 0
	## Armour/shield reinforce in the column's own unit (thousandths: 222 is
	## 22.2 %), (lower, upper).
	var armour_phys_reinforce := Vector2.ZERO
	var armour_mag_reinforce := Vector2.ZERO
	## Column 6, the description's key ("xxx" where none).
	var desc_strid: String = ""

	func is_equipment() -> bool:
		return model_path != ""

	func family() -> int:
		return type_ids[2] if type_ids.size() > 2 else 0

	func is_weapon() -> bool:
		return family() == FAMILY_WEAPON

	## The item ref's TypeID word (+0x80), READ s:0x48f610 / c:0x6abcd0:
	## CashItem | Bionic << 1 | TypeID1 << 2 | TypeID2 << 5 | TypeID3 << 7 |
	## TypeID4 << 11 (round 789, AVATAR_RESEARCH.md).
	func type_word() -> int:
		if type_ids.size() < 4:
			return 0
		return (cash_item & 1) | ((bionic & 1) << 1) | (type_ids[0] << 2) | (type_ids[1] << 5) \
			| (type_ids[2] << 7) | (type_ids[3] << 11)

	## An avatar (TypeID 3/1/13: hat 1, dress 2, attachment 3, flag 4).
	func is_avatar() -> bool:
		return type_ids.size() >= 4 and type_ids[0] == 3 and type_ids[1] == 1 and type_ids[2] == 13

	## A devil's spirit (TypeID 3/1/14).
	func is_devil_spirit() -> bool:
		return type_ids.size() >= 4 and type_ids[0] == 3 and type_ids[1] == 1 and type_ids[2] == 14

	func is_armour() -> bool:
		return CHINA_ARMOUR_FAMILIES.has(family()) or EUROPE_ARMOUR_FAMILIES.has(family())

	## True when the item carries a defence value (armour or a shield) -- what
	## decides whether the tooltip shows a defence block.
	func has_defence() -> bool:
		return phys_def != Vector2.ZERO or mag_def != Vector2.ZERO

	## The real English display name: the name string id (column 5) resolved
	## through the object-name tables (load_object_names: textdata_object.txt
	## and textdata_equip&skill.txt, round 731) -- textuisystem.txt holds no
	## `SN_ITEM_` key (measured 2026-09-19), so a caller handing in the
	## UI-string table gets nothing resolved. When no table is given or the id does not resolve, the
	## column-3 object name is used only if it reads as English: it is English
	## for weapons and armour but Korean for many consumables, and in this
	## archive the Korean is already mangled to question marks in the file
	## itself (`ITEM_ETC_HP_POTION_01`'s column 3 is literally "HP ?? ??").
	## Otherwise "" -- never an id. A name the table resolves is shown as the
	## client shows it, even when the key's first row carries no English: the
	## client then draws that row's language column as it stands, typically
	## the "0" filler (UiTextTable.parse; the box archive's Rebecca Event Hats
	## read "0").
	func display_name(names: UiTextTable = null) -> String:
		if names != null and name_strid != "":
			var resolved := names.get_text(name_strid)
			if resolved != "" and resolved != name_strid:
				return resolved
		if reads_as_english(item_name):
			return item_name
		return ""

	## True when a column-3 object name is usable as an English label:
	## printable ASCII with at least one letter and no '?' (the archive's
	## mark of a lost non-Latin character). A name with a Hangul character,
	## a "?", or nothing but digits and punctuation is not shown.
	static func reads_as_english(text: String) -> bool:
		var trimmed := text.strip_edges()
		if trimmed == "" or trimmed.contains("?"):
			return false
		var has_letter := false
		for ch in trimmed:
			var code := ch.unicode_at(0)
			if code < 0x20 or code > 0x7e:
				return false
			if (code >= 0x41 and code <= 0x5a) or (code >= 0x61 and code <= 0x7a):
				has_letter = true
		return has_letter

	## The character level the item asks for, or 0 when it asks by
	## something other than character level (or nothing at all).
	func required_character_level() -> int:
		for i in range(req_level_types.size()):
			if req_level_types[i] == REQ_TYPE_CHARACTER_LEVEL:
				return req_levels[i]
		return 0

## The value in a requirement pair's type column that means "the
## character's own level" -- what every starter item and every plain
## armour row checked carries in its first pair.
const REQ_TYPE_CHARACTER_LEVEL := 1
const REQ_GENDER_WOMAN := 0
const REQ_GENDER_MAN := 1
const REQ_GENDER_ANY := 2

## Parses one itemdata part into {id -> Item}, merging into `into` so the
## parts can be accumulated.
## Column 4's text as the item keeps it: stripped, `xxx` (any case, as
## NpcTableReader.parse_org_codes) read as "".
static func org_of(field: String) -> String:
	var org := field.strip_edges()
	return "" if org.to_lower() == "xxx" else org

static func parse(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	var _pp := ParseProfile.t0()
	if _parse_native(data, into):
		ParseProfile.add("text.items", _pp)
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_NAME:
			continue
		var id_text := cols[COL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var item := Item.new()
		item.id = int(id_text)
		item.code_name = cols[COL_CODE_NAME].strip_edges()
		item.item_name = cols[COL_NAME].strip_edges()
		if cols.size() > COL_ORG_CODE_NAME:
			item.org_code_name = org_of(cols[COL_ORG_CODE_NAME])
		if cols.size() > COL_NAME_STRID:
			item.name_strid = cols[COL_NAME_STRID].strip_edges()
		if cols.size() > COL_DESC_STRID:
			item.desc_strid = cols[COL_DESC_STRID].strip_edges()
		var stack := _int_at(cols, COL_MAX_STACK)
		if stack > 0:
			item.max_stack = stack
		item.sell_price = _int_at(cols, COL_SELL_PRICE)
		item.keeping_fee = _int_at(cols, COL_KEEPING_FEE)
		if cols.size() > COL_CAN_TRADE:
			item.can_trade = _int_at(cols, COL_CAN_TRADE) != 0
		item.can_use = _int_at(cols, COL_CAN_USE)
		var icon := _find_icon_path(cols)
		if icon != "":
			item.icon_path = ICON_PREFIX + icon
		item.model_paths = _models_at(cols, COL_MODEL)
		item.model_path = item.model_paths[0] if not item.model_paths.is_empty() else ""
		item.drop_model_path = _model_at(cols, COL_DROP_MODEL)
		for col in range(COL_TYPE_ID1, COL_TYPE_ID4 + 1):
			item.type_ids.append(_int_at(cols, col))
		item.cash_item = _int_at(cols, COL_CASH_ITEM)
		item.bionic = _int_at(cols, COL_BIONIC)
		item.country = _int_at(cols, COL_COUNTRY)
		item.req_gender = _int_at(cols, COL_REQ_GENDER)
		for pair in range(REQ_LEVEL_PAIRS):
			item.req_level_types.append(_int_at(cols, COL_REQ_LEVEL_TYPE1 + pair * 2))
			item.req_levels.append(_int_at(cols, COL_REQ_LEVEL1 + pair * 2))
		item.durability = _int_at(cols, COL_DURABILITY)
		item.phys_atk = Vector2i(_int_at(cols, COL_PHYS_ATK_MIN), _int_at(cols, COL_PHYS_ATK_MAX))
		item.mag_atk = Vector2i(_int_at(cols, COL_MAG_ATK_MIN), _int_at(cols, COL_MAG_ATK_MAX))
		item.phys_reinforce = Vector2i(_int_at(cols, COL_PHYS_REINFORCE_MIN), _int_at(cols, COL_PHYS_REINFORCE_MAX))
		item.mag_reinforce = Vector2i(_int_at(cols, COL_MAG_REINFORCE_MIN), _int_at(cols, COL_MAG_REINFORCE_MAX))
		item.attack_rate = _int_at(cols, COL_ATTACK_RATE)
		item.critical = _int_at(cols, COL_CRITICAL)
		item.attack_range = _int_at(cols, COL_RANGE)
		item.param1 = _int_at(cols, COL_PARAM1)
		item.param5 = _int_at(cols, COL_PARAM5)
		if cols.size() > COL_DESC4:
			item.desc1 = cols[COL_DESC1].strip_edges()
			item.desc4 = cols[COL_DESC4].strip_edges()
		item.phys_def = Vector2(_float_at(cols, COL_PHYS_DEF_MIN), _float_at(cols, COL_PHYS_DEF_MAX))
		item.mag_def = Vector2(_float_at(cols, COL_MAG_DEF_MIN), _float_at(cols, COL_MAG_DEF_MAX))
		item.block = Vector2(_float_at(cols, COL_BLOCK_MIN), _float_at(cols, COL_BLOCK_MAX))
		item.rarity = _int_at(cols, COL_RARITY)
		item.item_class = _int_at(cols, COL_ITEM_CLASS)
		item.set_id = _int_at(cols, COL_SET_ID)
		item.durability_max = _int_at(cols, COL_DURABILITY_MAX)
		item.req_str = _int_at(cols, COL_REQ_STR)
		item.req_int = _int_at(cols, COL_REQ_INT)
		item.max_magic_options = _int_at(cols, COL_MAX_MAGIC_OPTIONS)
		item.param2 = _int_at(cols, COL_PARAM2)
		item.param7 = _int_at(cols, COL_PARAM7)
		item.child_item_count = _int_at(cols, COL_CHILD_ITEM_COUNT)
		item.param4 = _int_at(cols, COL_PARAM4)
		item.param3 = _int_at(cols, COL_PARAM3)
		item.param6 = _int_at(cols, COL_PARAM6)
		var cool := cooltime_of(cols)
		item.cool_group = int(cool[0])
		item.cool_ms = int(cool[1])
		item.can_repair = _int_at(cols, COL_CAN_REPAIR)
		item.cost_repair = _int_at(cols, COL_COST_REPAIR)
		item.cost_revive = _int_at(cols, COL_COST_REVIVE)
		item.parry = Vector2(_float_at(cols, COL_PARRY_MIN), _float_at(cols, COL_PARRY_MAX))
		item.phys_absorb = Vector2(_float_at(cols, COL_PHYS_ABSORB_MIN), _float_at(cols, COL_PHYS_ABSORB_MAX))
		item.mag_absorb = Vector2(_float_at(cols, COL_MAG_ABSORB_MIN), _float_at(cols, COL_MAG_ABSORB_MAX))
		for col in PLUS_INC_COLS:
			item.plus_incs.append(_float_at(cols, col))
		item.phys_atk_upper = Vector2i(_int_at(cols, COL_PHYS_ATK_MIN_UPPER), _int_at(cols, COL_PHYS_ATK_MAX_UPPER))
		item.mag_atk_upper = Vector2i(_int_at(cols, COL_MAG_ATK_MIN_UPPER), _int_at(cols, COL_MAG_ATK_MAX_UPPER))
		item.phys_reinforce_upper = Vector2i(_int_at(cols, COL_PHYS_REINFORCE_MIN_UPPER), _int_at(cols, COL_PHYS_REINFORCE_MAX_UPPER))
		item.mag_reinforce_upper = Vector2i(_int_at(cols, COL_MAG_REINFORCE_MIN_UPPER), _int_at(cols, COL_MAG_REINFORCE_MAX_UPPER))
		item.attack_rate_upper = _int_at(cols, COL_ATTACK_RATE_UPPER)
		item.critical_upper = _int_at(cols, COL_CRITICAL_UPPER)
		item.armour_phys_reinforce = Vector2(_float_at(cols, COL_ARMOUR_PHYS_REINFORCE_MIN), _float_at(cols, COL_ARMOUR_PHYS_REINFORCE_MAX))
		item.armour_mag_reinforce = Vector2(_float_at(cols, COL_ARMOUR_MAG_REINFORCE_MIN), _float_at(cols, COL_ARMOUR_MAG_REINFORCE_MAX))
		# A row with neither a name nor an icon tells the player nothing.
		if item.item_name == "" and item.icon_path == "":
			continue
		into[item.id] = item
	ParseProfile.add("text.items", _pp)
	return into

## The loop above, its row work done by the native port (round 671; native/
## src/core/tables.rs `items`): every kept row's fields come back as columns,
## and each Item is built from them here, field for field as above, merged into
## `into` in file order (a later duplicate id replaces an earlier one, as
## above). False when there is no library or the port handed the table back.
static func _parse_native(data: PackedByteArray, into: Dictionary) -> bool:
	var rows := NativeAssets.table_rows("items", [data])
	if rows.is_empty():
		return false
	var ids: PackedInt64Array = rows["ids"]
	var code_names: PackedStringArray = rows["code_names"]
	# Round 740: a library from before this column has none (no Org: nothing
	# inherits a glow).
	var org_code_names: PackedStringArray = rows.get("org_code_names", PackedStringArray())
	var item_names: PackedStringArray = rows["item_names"]
	var name_strids: PackedStringArray = rows["name_strids"]
	var desc_strids: PackedStringArray = rows.get("desc_strids", PackedStringArray())
	var icon_paths: PackedStringArray = rows["icon_paths"]
	var drop_models: PackedStringArray = rows["drop_models"]
	var models: PackedStringArray = rows["models"]
	var model_counts: PackedInt64Array = rows["model_counts"]
	var max_stacks: PackedInt64Array = rows["max_stacks"]
	var sell_prices: PackedInt64Array = rows["sell_prices"]
	# Round 728: a library from before this column has none (fee 0).
	var keeping_fees: PackedInt64Array = rows.get("keeping_fees", PackedInt64Array())
	# Round 834: a library from before this column has none (all tradeable;
	# the server still refuses).
	var can_trades: PackedInt64Array = rows.get("can_trades", PackedInt64Array())
	# Round 838: a library from before this column has none (no tool picks a
	# target; build the library).
	var can_uses: PackedInt64Array = rows.get("can_uses", PackedInt64Array())
	var countries: PackedInt64Array = rows["countries"]
	var req_genders: PackedInt64Array = rows["req_genders"]
	var durabilities: PackedInt64Array = rows["durabilities"]
	var attack_rates: PackedInt64Array = rows["attack_rates"]
	var criticals: PackedInt64Array = rows["criticals"]
	var ranges: PackedInt64Array = rows["ranges"]
	var param1s: PackedInt64Array = rows["param1s"]
	# Round 768: a library from before these columns has none (no elixir or
	# stone passes the window's checks; the server still decides).
	var param5s: PackedInt64Array = rows.get("param5s", PackedInt64Array())
	# Round 869: a library from before these has none (a hole's gate line reads 0).
	var param3s: PackedInt64Array = rows.get("param3s", PackedInt64Array())
	var param6s: PackedInt64Array = rows.get("param6s", PackedInt64Array())
	var desc1s: PackedStringArray = rows.get("desc1s", PackedStringArray())
	var desc4s: PackedStringArray = rows.get("desc4s", PackedStringArray())
	var type_ids: PackedInt64Array = rows["type_ids"]
	# Round 726: a library from before these two columns has neither; such a
	# library's rows read as 0 (no cash item, not bionic).
	var cash_items: PackedInt64Array = rows.get("cash_items", PackedInt64Array())
	var bionics: PackedInt64Array = rows.get("bionics", PackedInt64Array())
	var req_types: PackedInt64Array = rows["req_types"]
	var req_levels: PackedInt64Array = rows["req_levels"]
	var attacks: PackedInt64Array = rows["attacks"]
	var defences: PackedFloat64Array = rows["defences"]
	# Round 731: a library from before these columns has none (all 0).
	var ext_ints: PackedInt64Array = rows.get("ext_ints", PackedInt64Array())
	var ext_floats: PackedFloat64Array = rows.get("ext_floats", PackedFloat64Array())
	# Round 789: a library from before these columns has none (all 0: no
	# avatar finds its visual row, so none is drawn -- build the library).
	var avatar_ints: PackedInt64Array = rows.get("avatar_ints", PackedInt64Array())
	# Round 826: a library from before these has none (no item re-use but the kind's).
	var cool_ints: PackedInt64Array = rows.get("cool_ints", PackedInt64Array())
	# Round 829: likewise (no repair quote but the server's).
	var repair_ints: PackedInt64Array = rows.get("repair_ints", PackedInt64Array())
	var m := 0
	for i in ids.size():
		var item := Item.new()
		item.id = ids[i]
		item.code_name = code_names[i]
		if i < org_code_names.size():
			item.org_code_name = org_code_names[i]
		item.item_name = item_names[i]
		item.name_strid = name_strids[i]
		if desc_strids.size() > i:
			item.desc_strid = desc_strids[i]
		item.max_stack = max_stacks[i]
		item.sell_price = sell_prices[i]
		if i < keeping_fees.size():
			item.keeping_fee = keeping_fees[i]
		if i < can_trades.size():
			item.can_trade = can_trades[i] != 0
		if i < can_uses.size():
			item.can_use = can_uses[i]
		item.icon_path = icon_paths[i]
		var count: int = model_counts[i]
		item.model_paths = models.slice(m, m + count)
		m += count
		item.model_path = item.model_paths[0] if not item.model_paths.is_empty() else ""
		item.drop_model_path = drop_models[i]
		for k in range(4):
			item.type_ids.append(type_ids[i * 4 + k])
		if i < cash_items.size():
			item.cash_item = cash_items[i]
		if i < bionics.size():
			item.bionic = bionics[i]
		item.country = countries[i]
		item.req_gender = req_genders[i]
		for pair in range(REQ_LEVEL_PAIRS):
			item.req_level_types.append(req_types[i * REQ_LEVEL_PAIRS + pair])
			item.req_levels.append(req_levels[i * REQ_LEVEL_PAIRS + pair])
		item.durability = durabilities[i]
		var a := i * 8
		item.phys_atk = Vector2i(attacks[a], attacks[a + 1])
		item.mag_atk = Vector2i(attacks[a + 2], attacks[a + 3])
		item.phys_reinforce = Vector2i(attacks[a + 4], attacks[a + 5])
		item.mag_reinforce = Vector2i(attacks[a + 6], attacks[a + 7])
		item.attack_rate = attack_rates[i]
		item.critical = criticals[i]
		item.attack_range = ranges[i]
		item.param1 = param1s[i]
		if i < param5s.size():
			item.param5 = param5s[i]
		if i < param3s.size():
			item.param3 = param3s[i]
		if i < param6s.size():
			item.param6 = param6s[i]
		if i < desc1s.size():
			item.desc1 = desc1s[i]
		if i < desc4s.size():
			item.desc4 = desc4s[i]
		var d := i * 6
		item.phys_def = Vector2(defences[d], defences[d + 1])
		item.mag_def = Vector2(defences[d + 2], defences[d + 3])
		item.block = Vector2(defences[d + 4], defences[d + 5])
		var e := i * 17
		if e + 16 < ext_ints.size():
			item.rarity = ext_ints[e]
			item.item_class = ext_ints[e + 1]
			item.set_id = ext_ints[e + 2]
			item.durability_max = ext_ints[e + 3]
			item.req_str = ext_ints[e + 4]
			item.req_int = ext_ints[e + 5]
			item.max_magic_options = ext_ints[e + 6]
			item.phys_atk_upper = Vector2i(ext_ints[e + 7], ext_ints[e + 8])
			item.mag_atk_upper = Vector2i(ext_ints[e + 9], ext_ints[e + 10])
			item.phys_reinforce_upper = Vector2i(ext_ints[e + 11], ext_ints[e + 12])
			item.mag_reinforce_upper = Vector2i(ext_ints[e + 13], ext_ints[e + 14])
			item.attack_rate_upper = ext_ints[e + 15]
			item.critical_upper = ext_ints[e + 16]
		var f := i * 18
		if f + 17 < ext_floats.size():
			item.parry = Vector2(ext_floats[f], ext_floats[f + 1])
			item.phys_absorb = Vector2(ext_floats[f + 2], ext_floats[f + 3])
			item.mag_absorb = Vector2(ext_floats[f + 4], ext_floats[f + 5])
			for k in range(8):
				item.plus_incs.append(ext_floats[f + 6 + k])
			item.armour_phys_reinforce = Vector2(ext_floats[f + 14], ext_floats[f + 15])
			item.armour_mag_reinforce = Vector2(ext_floats[f + 16], ext_floats[f + 17])
		else:
			for k in range(8):
				item.plus_incs.append(0.0)
		var av := i * 3
		if av + 2 < avatar_ints.size():
			item.param2 = avatar_ints[av]
			item.param7 = avatar_ints[av + 1]
			item.child_item_count = avatar_ints[av + 2]
		var co := i * 3
		if co + 2 < cool_ints.size():
			item.param4 = cool_ints[co]
			item.cool_group = cool_ints[co + 1]
			item.cool_ms = cool_ints[co + 2]
		if co + 2 < repair_ints.size():
			item.can_repair = repair_ints[co]
			item.cost_repair = repair_ints[co + 1]
			item.cost_revive = repair_ints[co + 2]
		into[item.id] = item
	return true

## A `.bsr` path in the column the layout puts it in, or "" for the `xxx`
## the table writes where a row has no model -- checked by extension so a
## part with a shifted layout yields nothing rather than a wrong path.
static func _model_at(cols: PackedStringArray, col: int) -> String:
	if col >= cols.size():
		return ""
	var value := cols[col].strip_edges()
	return value.replace("/", "\\") if value.to_lower().ends_with(".bsr") else ""

## The column's `.bsr` paths, comma-separated as the client splits it
## (round 626, see Item.model_paths): each token passes _model_at's own
## test, so `xxx` or a stray token yields nothing. Until round 626 the whole
## "a.bsr,b.bsr" string was taken as one path, which is no file, so a set
## chest drew nothing.
static func _models_at(cols: PackedStringArray, col: int) -> PackedStringArray:
	var out := PackedStringArray()
	if col >= cols.size():
		return out
	for token in cols[col].split(",", false):
		var one := _model_at(PackedStringArray([token]), 0)
		if one != "":
			out.append(one)
	return out

static func _int_at(cols: PackedStringArray, col: int) -> int:
	if col >= cols.size():
		return 0
	var text := cols[col].strip_edges()
	return int(text) if text.is_valid_int() else 0

## A float column (armour defence values are written like "2.5"), or 0.
static func _float_at(cols: PackedStringArray, col: int) -> float:
	if col >= cols.size():
		return 0.0
	var text := cols[col].strip_edges()
	return float(text) if text.is_valid_float() else 0.0

## The `.ddj` field in an item row. A row also carries two `.bsr` model
## paths, so matching on the extension is what picks the icon out.
static func _find_icon_path(cols: PackedStringArray) -> String:
	for col in cols:
		var trimmed := col.strip_edges()
		if trimmed.to_lower().ends_with(".ddj"):
			return trimmed
	return ""

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var _pp := ParseProfile.t0()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := TextDecode.utf16(raw)
	if text.is_empty():
		text = raw.get_string_from_utf8()
	var _out := text.replace("\r", "").split("\n")
	ParseProfile.add("text.decode_split", _pp, data.size())
	return _out
