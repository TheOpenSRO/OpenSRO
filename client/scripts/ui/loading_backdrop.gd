class_name LoadingBackdrop
extends RefCounted

## Which art the "NOW LOADING" screen shows (round 785's follow-up), as the
## client chooses it (READ, sro_client.exe, UI_ALCHEMYBOX::FUN_0084b6e0, the
## screen's raise; LoadingScreen's header has the rest of that state).
##
## FUN_0084b6e0 is a __thiscall with one stack argument (`ret 4`): its two
## callers are CPSMission::OnCreate (0x84c9dd: `push 0`, the world's first
## entry) and OnResetClient (0x86dafc: `push edi`, the WORD it read from the
## 0x34B5 packet and logged as "OnResetClient : %d"). The game server fills
## that WORD from the character's position record (SR_GameServer
## CMainProcess::CharDataSavingCompleted appends `chardata + 0x94`; the same
## record's readers take +0x94 as a WORD beside x/y/z at +0x98..+0xa0 and the
## heading at +0xec, e.g. CGObjPC::FUN_004e08a0): the region the character
## arrives in. The screen then branches on CPSMission+0xe0, "the mode":
##
##   0  loading_europe_%d.ddj, %d = rand() % 2 + 1     (OnCreate sets 0 first)
##   1  loading_rebirth.ddj      (set when this player dies: FUN_008a80a0,
##                                life state 2 -> FUN_0084ab10(1) before
##                                FUN_0077b000, the death)
##   2, 3  by the region WORD -- REGION_ART below, else loading_china_1.ddj
##   4  loading_thief2.ddj       (no setter of 4 found)
##   5  custumize_china_loading.ddj (character select)
##   >5 no art change            (6: one item use's result, not identified)
##
## Teleports' requests set 2 (the NPC teleport's 0x705A sends, 0x7035f0 and
## 0x81de31; two item-use results, 0x87adb9 / 0x87ae2f -- which items is not
## read),
## and every finished load sets 2 (FUN_0084c060's end) -- so a teleport, a
## scroll or any later load picks by region unless the player died since.
##
## The region WORD is the region id: high byte the region's x, low byte its y
## (25000 = 97 << 8 | 168, Jangan; 0x8001.. the dungeons' ids, DungeonWorld).
## REGION_ART was read by running the branch tree at 0x84b896 (cmp / jg / je /
## sub / add / ja and its two byte-indexed jump tables at 0x84be4c and
## 0x84bf54) for every WORD 0..65535 against the image itself (tools note in
## docs/WORLD_ISSUES.md round 785): these 45 ids pick their own art, every
## other id loading_china_1.ddj. An exact region, not a zone: a town's art
## shows only for an arrival in that one region.

const DIR := "interface\\loading\\"
const MODE_FIRST := 0
const MODE_REBIRTH := 1
const MODE_ZONE := 2
const DEFAULT_ZONE_ART := "loading_china_1.ddj"

## Region id -> art (READ, see above).
const REGION_ART := {
	19001: "loading_valley.ddj",
	19019: "loading_pharaoh.ddj",
	21067: "loading_desert.ddj", 21569: "loading_desert.ddj", 22347: "loading_desert.ddj",
	23088: "loading_alex.ddj",
	23180: "loading_river.ddj", 23183: "loading_river.ddj", 23436: "loading_river.ddj",
	23439: "loading_river.ddj", 24734: "loading_river.ddj", 24993: "loading_river.ddj",
	25244: "loading_river.ddj", 25761: "loading_river.ddj",
	23406: "loading_loksan.ddj", 25532: "loading_loksan.ddj", 25533: "loading_loksan.ddj",
	25788: "loading_loksan.ddj", 25789: "loading_loksan.ddj", 25792: "loading_loksan.ddj",
	26044: "loading_loksan.ddj", 26045: "loading_loksan.ddj", 26046: "loading_loksan.ddj",
	26300: "loading_loksan.ddj", 26301: "loading_loksan.ddj", 26302: "loading_loksan.ddj",
	26790: "loading_loksan.ddj",
	23603: "loading_thiefzone.ddj",
	23687: "loading_hotan.ddj",
	23856: "loading_pharos.ddj",
	24758: "loading_thief.ddj",
	25000: "loading_zangan.ddj",
	25163: "loading_port2.ddj", 25945: "loading_port2.ddj", 26457: "loading_port2.ddj",
	26265: "loading_dunwhang.ddj",
	26959: "loading_constantinople.ddj",
	27244: "loading_samarkand.ddj",
	32769: "loading_dungeons_donwhang.ddj",
	32770: "loading_royalmausoleum.ddj", 32771: "loading_royalmausoleum.ddj",
	32772: "loading_royalmausoleum.ddj", 32773: "loading_royalmausoleum.ddj",
	32774: "loading_royalmausoleum.ddj", 32775: "loading_royalmausoleum.ddj",
}

## The region id of region (x, y), as the client's WORD carries it.
static func region_id(rx: int, ry: int) -> int:
	return ((rx & 0xFF) << 8) | (ry & 0xFF)

## The art for an arrival in region `region_id` (mode 2/3).
static func for_region(rid: int) -> String:
	return DIR + String(REGION_ART.get(rid, DEFAULT_ZONE_ART))

## The art the screen shows in `mode` for region `rid`; `roll` is the random
## draw mode 0 uses (rand() % 2 + 1 there; any int here). "" for a mode that
## changes no art (> 5) -- the caller keeps what it showed last.
static func path(mode: int, rid: int, roll: int) -> String:
	match mode:
		MODE_FIRST:
			return DIR + "loading_europe_%d.ddj" % (posmod(roll, 2) + 1)
		MODE_REBIRTH:
			return DIR + "loading_rebirth.ddj"
		2, 3:
			return for_region(rid)
		4:
			return DIR + "loading_thief2.ddj"
		5:
			return DIR + "custumize_china_loading.ddj"
	return ""
