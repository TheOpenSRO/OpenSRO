extends RefCounted
class_name QuestMapGuide

## Where the quest list's world-map button (row control 18) looks for a
## quest's area (round 845, lane K). Every address is sro_client.exe's;
## docs/protocol/quests.md section 9 has the reading. Labels: READ, MEASURED,
## INFERRED, OURS.
##
## **The button (READ).** CNIFQuestSlot's message map (0xeb98d0, filled by
## 0xd6d6e0) sends control 18 to 0x6e51e0, 19 to 0x6e5290 (the detail) and 8
## to 0x6e55d0 (the check box). 0x6e51e0, for the row's quest id:
## 1. asks the world map window (CGInterface window 0x1c, 0x799920) whether
##    the quest has a place (0x612e60); if not, only tracks the quest
##    (DAT_00eeae70 = id) -- 0x612e60 has already printed the error;
## 2. else shows the window: when it exists and is shown, its vslot 0x50
##    (0x46cd60 -> 0xb90c00; INFERRED: to the front), else 0x79abe0 (the M
##    key's toggle, which opens it);
## 3. puts the quest on it (0x6256e0) and tracks the quest.
##
## **The test (0x612e60, READ).** The player's record of the quest
## (0x9d4c60 -> 0x8b9290): with status 8 (QUEST_STATUS_ACHIEVED_KILL_MONSTER)
## the quest has a place when its NPC list (0x30D5 flags & 0x40, +0x24..+0x28)
## is not empty; any other status, when the guide table has a QUEST row of the
## quest's code name (GlobalDataManager +0x80c, 0x9418d0). Otherwise the
## system message window gets `UIIT_MSG_MAP_ERR` ("Does not have any
## information about that quest.") through 0x7781b0(0, text): type 0, the
## line that always shows, in 0xffdbc99b.
##
## **The guide table (READ).** `worldmapguidedata.txt`'s sections are loaded
## by Client_LoadRefDataFile case 0x59; a row is kept only when its first
## column (the 서비스 flag) is not 0 (`thunk_FUN_00b43f75` then `!= 0`;
## INFERRED that it reads that column). A QUEST row (0x970110) keeps its 구분
## (kind), its 지역 (area: the MAP_MANAGER name), 리전x, 리전y, pos_x, pos_y --
## the x and y columns are read and dropped -- and its last column split at
## `,`; the rows are filed under the code name, in file order (0x90ce00 /
## 0x943c70). MEASURED (the box's Media.pk2): 128 rows in service, 127
## codes; 120 kind 0 in `field`, 7 kind 0 in `dunhuang1`, 1 kind 1
## (QNO_CH_HWAN_1_3_1).

const GUIDE_PATH := WorldmapGuideReader.TABLE_PATH
const STATUS_ACHIEVED_KILL := 8
## UIIT_MSG_MAP_ERR, the 0x612e60 line (string id 0xd990ac, READ).
const MAP_ERR_KEY := "UIIT_MSG_MAP_ERR"

var guide: WorldmapGuideReader.ParsedGuide
## Monster code -> its mask tiles (worldmapguidedata_region.txt).
var region_tiles := {}
## Quest code -> its QUEST rows in service, file order.
var _quests := {}
## Monster code -> its first MONSTER row in service (INFERRED: the client's
## map insert keeps the first of a code's rows; 4 codes have two, all in the
## Donwhang cave).
var _monsters := {}
## MAP_MANAGER name -> row, in service.
var _maps := {}
## npcpos rows by NPC id: [region id, local position] (QuestMarks).
var _npcpos := {}
var _npcpos_loaded := false
var _archive: Pk2Reader

static var _shared: QuestMapGuide = null

## The guide read from `archive` (Media.pk2), once a process.
static func shared(archive: Pk2Reader) -> QuestMapGuide:
	if _shared == null or (_shared._archive != archive and archive != null):
		_shared = QuestMapGuide.new()
		_shared.load_from(archive)
	return _shared

## For tests: a guide built from the files' bytes.
static func from_data(guide_data: PackedByteArray, region_data: PackedByteArray) -> QuestMapGuide:
	var g := QuestMapGuide.new()
	g._index(WorldmapGuideReader.parse(guide_data), WorldmapGuideReader.parse_region_tiles(region_data))
	return g

func load_from(archive: Pk2Reader) -> void:
	_archive = archive
	var gdata := PackedByteArray()
	var rdata := PackedByteArray()
	if archive != null:
		var e := ObjectLoader.find_file(archive, GUIDE_PATH)
		if e != null:
			gdata = archive.read_file(e)
		var r := ObjectLoader.find_file(archive, WorldmapGuideReader.REGION_TABLE_PATH)
		if r != null:
			rdata = archive.read_file(r)
	_index(WorldmapGuideReader.parse(gdata), WorldmapGuideReader.parse_region_tiles(rdata))

func _index(parsed: WorldmapGuideReader.ParsedGuide, tiles: Dictionary) -> void:
	guide = parsed
	region_tiles = tiles
	_quests.clear()
	_monsters.clear()
	_maps.clear()
	for q in parsed.quests:
		if q.service == 0:
			continue
		var list: Array = _quests.get(q.code, [])
		list.append(q)
		_quests[q.code] = list
	for m in parsed.monsters:
		if m.service != 0 and not _monsters.has(m.code):
			_monsters[m.code] = m
	for mp in parsed.maps:
		if mp.service != 0 and not _maps.has(mp.name):
			_maps[mp.name] = mp

## The QUEST rows of a code name, in service.
func quest_rows(code: String) -> Array:
	return _quests.get(code, [])

func monster(code: String) -> WorldmapGuideReader.GuidePoint:
	return _monsters.get(code, null)

func map_named(area: String) -> WorldmapGuideReader.GuideMap:
	return _maps.get(area, null)

## A monster's mask tiles, [Vector2i(A, B)...] (region x, region y of each
## tile's first region).
func tiles_of(code: String) -> Array:
	return region_tiles.get(code, [])

## 0x612e60: whether the quest of `code` with record `view` has a place.
func has_area(view: QuestNet.View, code: String) -> bool:
	if view != null and view.status == STATUS_ACHIEVED_KILL:
		return not view.npcs.is_empty()
	return not quest_rows(code).is_empty()

## An NPC's npcpos row (0x938260): [region id, local position], or null.
func npc_position(npc_id: int) -> Variant:
	if not _npcpos_loaded:
		_npcpos_loaded = true
		if _archive != null:
			var e := ObjectLoader.find_file(_archive, NpcTableReader.POSITION_TABLE_PATH)
			if e != null:
				_npcpos = QuestMarks.index_positions(NpcTableReader.parse_positions(_archive.read_file(e)))
	return _npcpos.get(npc_id, null)

## For tests: npcpos rows without the archive.
func set_npc_positions(index: Dictionary) -> void:
	_npcpos = index
	_npcpos_loaded = true
