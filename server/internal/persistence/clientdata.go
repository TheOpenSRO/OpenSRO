package persistence

// Which reference tables ship to the client, and which do not.
//
// The server loads all 124 reference tables from its database. The CLIENT
// carries a `server_dep\silkroad\textdata\*.txt` copy of some of them, and
// that copy is the only way this project can read one without a real database.
//
// Measured 2026-09-17 against a retail Media.pk2: **51 have a file, the rest do
// not.** Before this, docs/protocol/refdata_tables.md said "77 of 85 unread",
// which conflated "not yet read" with "not readable" -- most of them were
// sitting in the archive. The 39 tables the census missed (round 242,
// 2026-09-19) were checked against the same file list: none has a file.
//
// Only the FILENAME is recorded here. No table content is, and none may be:
// see docs/LEGAL.md.
// ClientTextdata maps a reference table to the textdata file that carries it,
// without the `_NNNN` shard suffix where a table is sharded (itemdata,
// characterdata and skilldata are).
//
// Six entries could not be derived from the table name and were resolved by
// reading the archive's own file list: _REFTELELINK is `teleportlink`,
// _REFOBJITEM is `itemdata`, _REFOBJCHAR is `characterdata`, _REFMAGICOPT is
// `magicoption`, _REFMAGICOPTASSIGN is `magicoptionassign`, and
// _REFSIEGEFORTRESSREWARDS is `siegefortressreward` (singular).
//
// Round 837: _REFSHOP, _REFSHOPGROUP and _REFSHOPTAB were mapped to the legacy
// `shopdata`, `shopgroupdata` and `shoptabdata`. The client never loads those
// (no such string in sro_client.exe, and they are not in its load list); it
// loads `refshop`, `refshopgroup` and `refshoptab`, whose rows are the shard's
// Service-1 rows of the three tables (MEASURED: 93/93, 111/111, all 298 tab
// rows; docs/protocol/item_mall_data.md §9 and item_mall_data_verify.md).
var ClientTextdata = map[string]string{
	"_REFABILITYBYITEMOPTLEVEL":         "refabilitybyitemoptleveldata",
	"_REFACCESSPERMISSIONOFSHOP":        "refaccesspermissionofshop",
	"_REFCONDITIONTOBUYSCRAPITEM":       "refconditiontobuyscrapitem",
	"_REFCONDITIONTOSELLPACKAGEITEM":    "refconditiontosellpackageitem",
	"_REFCONDITIONTOSELLSCRAPITEM":      "refconditiontosellscrapitem",
	"_REFEVENT":                         "eventdata",
	"_REFEVENTZONE":                     "eventzonedata",
	"_REFGACHAITEMSET":                  "gachaitemset",
	"_REFGACHANPCMAP":                   "gachanpcmap",
	"_REFGAME_WORLD":                    "gameworlddata",
	"_REFGAME_WORLD_CONFIG":             "gameworldconfigdata",
	"_REFHWANLEVEL":                     "hwanleveldata",
	"_REFLEVEL":                         "leveldata",
	"_REFMAGICOPT":                      "magicoption",
	"_REFMAGICOPTASSIGN":                "magicoptionassign",
	"_REFMAGICOPTBYITEMOPTLEVEL":        "refmagicoptbyitemoptleveldata",
	"_REFMAGICOPTGROUP":                 "refmagicoptgroup",
	"_REFMAPPINGSHOPGROUP":              "refmappingshopgroup",
	"_REFMAPPINGSHOPWITHTAB":            "refmappingshopwithtab",
	"_REFOBJCHAR":                       "characterdata",
	"_REFOBJITEM":                       "itemdata",
	"_REFOPTIONALTELEPORT":              "refoptionalteleport",
	"_REFPACKAGEITEM":                   "refpackageitem",
	"_REFPRICEPOLICYOFITEM":             "refpricepolicyofitem",
	"_REFQUEST":                         "questdata",
	"_REFREGION":                        "refregion",
	"_REFREWARDPOLICYTOBUYSCRAPITEM":    "refrewardpolicytobuyscrapitem",
	"_REFREWARDPOLICYTOSELLPACKAGEITEM": "refrewardpolicytosellpackageitem",
	"_REFREWARDPOLICYTOSELLSCRAPITEM":   "refrewardpolicytosellscrapitem",
	"_REFSCRAPOFPACKAGEITEM":            "refscrapofpackageitem",
	"_REFSETITEMGROUP":                  "refsetitemgroup",
	"_REFSHOP":                          "refshop",
	"_REFSHOPGOODS":                     "refshopgoods",
	"_REFSHOPGROUP":                     "refshopgroup",
	"_REFSHOPITEMSTOCKPERIOD":           "refshopitemstockperiod",
	"_REFSHOPTAB":                       "refshoptab",
	"_REFSHOPTABGROUP":                  "refshoptabgroup",
	"_REFSIEGEBLESSBUFF":                "refsiegeblessbuff",
	"_REFSIEGEDUNGEON":                  "refsiegedungeon",
	"_REFSIEGEFORTRESS":                 "siegefortress",
	"_REFSIEGEFORTRESSBATTLERANK":       "siegefortressbattlerank",
	"_REFSIEGEFORTRESSGUARD":            "siegefortressguard",
	"_REFSIEGEFORTRESSITEMFORGE":        "siegefortressitemforge",
	"_REFSIEGEFORTRESSREWARDS":          "siegefortressreward",
	"_REFSIEGESTRUCTUPGRADE":            "siegestructupgradedata",
	"_REFSKILL":                         "skilldata",
	"_REFSKILLBYITEMOPTLEVEL":           "refskillbyitemoptleveldata",
	"_REFSKILLMASTERY":                  "skillmasterydata",
	"_REFTELELINK":                      "teleportlink",
	"_REFTELEPORT":                      "teleportdata",
	"_REFTREATITEMOFSHOP":               "reftreatitemofshop",
}

// ServerOnlyLootTables are the reference tables that decide what a monster
// drops. **All seventeen of them are absent from the client archive**, and the
// completeness of that is the point: exactly one file in the whole of Media.pk2
// has "drop" anywhere in its path, and it is not one of these.
//
// So loot tables are not shipped to players, which is what you would expect and
// is now measured rather than assumed. Drop rates are NOT recoverable from the
// client, and a reimplementation needs its own or a real database.
var ServerOnlyLootTables = []string{
	"_REFCUSTOMIZINGRESERVEDITEMDROPFORMONSTER",
	"_REFDROPCLASSSEL_ALCHEMY_ATTRSTONE",
	"_REFDROPCLASSSEL_ALCHEMY_MAGICSTONE",
	"_REFDROPCLASSSEL_ALCHEMY_TABLET",
	"_REFDROPCLASSSEL_AMMO",
	"_REFDROPCLASSSEL_CURE",
	"_REFDROPCLASSSEL_EQUIP",
	"_REFDROPCLASSSEL_RAREEQUIP",
	"_REFDROPCLASSSEL_RECOVER",
	"_REFDROPCLASSSEL_REINFORCE",
	"_REFDROPCLASSSEL_SCROLL",
	"_REFDROPGOLD",
	"_REFDROPITEMASSIGN",
	"_REFDROPITEMGROUP",
	"_REFDROPOPTLVLSEL",
	"_REFMONSTER_ASSIGNEDITEMDROP",
	"_REFMONSTER_ASSIGNEDITEMRNDDROP",
}

// ServerOnlyOtherTables are the remaining tables with no client file, for
// reasons that vary and are not all established.
//
// _REFOBJCOMMON is explained: it has no file because it is the shared prefix
// denormalised into itemdata and characterdata, which
// docs/protocol/refobj_binary_format.md established from the other end. The
// rest are simply absent.
var ServerOnlyOtherTables = []string{
	// The 39 tables found in round 242: none has a client file.
	"TAB_REFHIVE",
	"TAB_REFTACTICS",
	"TAB_REFNEST",
	"TAB_REFAISKILL",
	"TAB_REFRANKING_TRADERACTIVITY",
	"TAB_REFRANKING_ROBBERACTIVITY",
	"TAB_REFRANKING_HUNTERACTIVITY",
	"TAB_REFRANKING_TRADERCONTRIBUTION",
	"TAB_REFRANKING_ROBBERCONTRIBUTION",
	"TAB_REFRANKING_HUNTERCONTRIBUTION",
	"_RefServerEvent",
	"_RefServerEventReward",
	"_RefServerEventReward_ExpUPForPlayers",
	"_RefServerEventReward_SpawnMonster",
	"_RefRentItem",
	"_RefQuestReward",
	"_RefQuestRewardItems",
	"_RefEventReward",
	"_RefEventRewardItems",
	"_RefCollectionBook_Theme",
	"_RefCollectionBook_Item",
	"_RefUIString_Mt",
	"_RefGameWorldBindTriggerCategory",
	"_RefTriggerCategory",
	"_RefTriggerCategoryBindTrigger",
	"_RefTrigger",
	"_RefTriggerVariable",
	"_RefTriggerBindEvent",
	"_RefTriggerBindCondition",
	"_RefTriggerBindAction",
	"_RefTriggerCommon",
	"_RefTriggerEvent",
	"_RefTriggerCondition",
	"_RefTriggerAction",
	"_RefTriggerConditionParam",
	"_RefTriggerActionParam",
	"_RefGameWorldBindGameWorldGroup",
	"_RefGameWorldGroup",
	"_RefGameWorldGroup_Config",
	"_REFALCHEMYMERIT",
	"_REFCHARDEFAULT_QUEST",
	"_REFCHARGEN",
	"_REFCLIMATE",
	"_REFGACHACODE",
	"_REFGAMEWORLDNPC",
	"_REFINSTANCE_WORLD_REGION",
	"_REFINSTANCE_WORLD_START_POS",
	"_REFOBJCHAREXTRASKILL",
	"_REFOBJCOMMON",
	"_REFOBJSTRUCT",
	"_REFREGIONBINDASSOCSERVER",
	"_REFSHARDCONTENTCONFIG",
	"_REFSHOPOBJECT",
	"_REFSIEGELVLSUMMONMONSTER",
	"_REFSIEGEQUEST",
	"_REFSIEGEQUESTREWARD",
}
