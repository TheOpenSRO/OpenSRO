// Package persistence is the database surface the real server used, recovered
// from SR_GameServer.exe.
//
// Nothing here is designed. The procedure names and their argument counts were
// read out of the ODBC call literals the binary builds and the table names out
// of its string pool. OpenSRO does not have to use this schema, but it is what
// the game's own operations are, and a reimplementation that cannot express one
// of these has found a gap.
//
// CORRECTED 2026-09-17: there are 71 procedures, not 39. The first harvest
// matched only `{?=CALL _NAME (...)}` and the server calls procedures in three
// more forms it never saw -- `{CALL _NAME (...)}` (26), `EXEC _NAME ...` (7),
// and five `trs_sm_*job` wrappers. This is the SAME defect as the runtime-table
// count in docs/protocol/persistence.md, which found 35 of 54 because its regex
// was uppercase-only: one pattern, assumed to be the only spelling, in this same
// file. A harvest is only complete once its pattern has been falsified rather
// than just run.
//
// See docs/protocol/persistence.md.
package persistence

// Proc is one stored procedure as the server calls it.
type Proc struct {
	Name string
	// Args is the number of parameter placeholders in the call literal. It is
	// the count in the widest literal found, because a few procedures are
	// called from more than one site.
	//
	// A quoted placeholder group is ONE argument, not several: _Rent_Info_Manager
	// passes three datetimes as `'%d-%d-%d %d:%d:%d'` and takes 10 arguments, not
	// 24. A counter that tallies `%d` rather than top-level commas gets that
	// wrong, and got it wrong once during this recovery.
	Args int
	// Variadic marks a procedure whose literal is built in pieces, so Args is
	// the fixed head and the real arity depends on the data. Only the two magic
	// -item procedures are: AQ_StorageUpdater::AddMagicItem emits the head and
	// then appends `"%s,%I64d"` once per magic parameter, bounded by its own
	// assert "Item's MagParamNum(%d) is out of range".
	Variadic bool
	// Caller is the function that builds the call, which is usually an AQ_*
	// class method and so says which subsystem owns the procedure.
	Caller string
}

// Procs is every stored procedure the server calls, in name order.
var Procs = []Proc{
	{Name: "_ADDTIMEDJOB", Args: 14, Caller: "FUN_00650980"},
	{Name: "_ADDTIMEDJOBFORPET", Args: 13, Caller: "FUN_0065fc60"},
	{Name: "_AddNewCOS", Args: 12, Caller: "GObjPC::FUN_00440120"},
	{Name: "_AddSiegeFortressObject", Args: 10, Caller: "AQ_Siege::FUN_00456ec0"},
	{Name: "_AssignNickName", Args: 2, Caller: "FUN_00465160"},
	{Name: "_Bind_Option_Manager", Args: 9, Caller: "AQ_BindOptionWithItem::FUN_0044b600"},
	{Name: "_COS_Naming", Args: 2, Caller: "GObjPC::FUN_00440120"},
	{Name: "_CanAssignThisNickName", Args: 1, Caller: "FUN_004650b0"},
	{Name: "_ChangeCOSState", Args: 2, Caller: "GObjPC::FUN_00440120"},
	{Name: "_CharInstanceWorldDataMarkUpLastWorld", Args: 4, Caller: "AQ_GameWorld::FUN_00441b40"},
	{Name: "_CharInstanceWorldDataUpdate", Args: 12, Caller: "AQ_GameWorld::FUN_00441b40"},
	{Name: "_DelExpiredRentItemInStorage", Args: 3, Caller: "AQ_CharDataLoader::FUN_0043d2c0"},
	{Name: "_DeleteCharCOS", Args: 3, Caller: "GObjPC::FUN_00440120"},
	{Name: "_DeleteCharTrijobSafeTradeData", Args: 1, Caller: "AQ_Trijob::FUN_00465f20"},
	{Name: "_DeleteGPHistory", Args: 1, Caller: "FUN_005d05e0"},
	{Name: "_Guild_Master_Election_Available", Args: 2, Caller: "AQ_GuildQuery::FUN_00441940"},
	{Name: "_InsertCharTrijobSafeTradeData", Args: 3, Caller: "AQ_Trijob::FUN_00465e50"},
	{Name: "_OpenMarket_Cancle", Args: 6, Caller: "AQ_OpenMarket::FUN_00453a20"},
	{Name: "_OpenMarket_Insert", Args: 17, Caller: "AQ_OpenMarket::FUN_004535a0"},
	{Name: "_OpenMarket_Purchase", Args: 9, Caller: "AQ_OpenMarket::FUN_00453c20"},
	{Name: "_OpenMarket_Receipt", Args: 3, Caller: "AQ_OpenMarket::FUN_00453820"},
	{Name: "_OpenMarket_Update", Args: 5, Caller: "AQ_OpenMarket::FUN_00454270"},
	{Name: "_Rent_Info_Manager", Args: 10, Caller: "AQ_StorageUpdaterForPacakageItem::FUN_0045ea30"},
	{Name: "_STRG_DEL_ITEM", Args: 4, Caller: "AQ_StorageUpdater::DeleteItem"},
	{Name: "_STRG_MERGE_ITEM", Args: 8, Caller: "AQ_StorageUpdater::RearrangeItem"},
	{Name: "_STRG_MOVEITEM_NEW", Args: 9, Caller: "AQ_ItemXChanger::vslot_006"},
	{Name: "_STRG_MOVE_ITEM", Args: 8, Caller: "AQ_StorageUpdater::MoveItem"},
	{Name: "_STRG_SWAP_ITEM", Args: 8, Caller: "AQ_StorageUpdater::RearrangeItem"},
	{Name: "_SiegeFortressEngageBlessBuff", Args: 3, Caller: "GObjPC::FUN_0061e330"},
	{Name: "_SiegeFortressEntryDungeon", Args: 2, Caller: "GObjPC::FUN_0061e330"},
	{Name: "_SiegeFortressFinished", Args: 1, Caller: "GObjPC::FUN_0061e1d0"},
	{Name: "_SiegeFortressHireNPC", Args: 5, Caller: "GObjPC::FUN_0061e330"},
	{Name: "_SiegeFortressRequestSiege", Args: 4, Caller: "AQ_Siege::FUN_00627cd0"},
	{Name: "_SiegeFortressTaxCollect", Args: 3, Caller: "GObjPC::FUN_0061e330"},
	{Name: "_SiegeFortressTempFinished", Args: 1, Caller: "GObjPC::FUN_0061e280"},
	{Name: "_UPDATE_CHAR_GOLD_FOR_GUILDCHEST", Args: 2, Caller: "AQ_StorageUpdater::MoveItemWithGold"},
	{Name: "_UPDATE_GUILD_N_CHAR_GOLD", Args: 4, Caller: "AQ_StorageUpdater::MoveItemWithGold"},
	{Name: "_UPDATE_USER_N_CHAR_GOLD", Args: 4, Caller: "AQ_StorageUpdater::MoveItemWithGold"},
	{Name: "_UpdateSiegeFortressTaxRatio", Args: 2, Caller: "GObjPC::FUN_0061e330"},
	// --- ADDED 2026-09-17: the 32 the {?=CALL} pattern never saw. ---
	// Item creation, which the first harvest missed entirely: every route by
	// which an item comes into existence is one of these.
	{Name: "_STRG_ADD_EQUIP_NORMAL", Args: 9, Caller: "AQ_StorageUpdater::AddItem"},
	{Name: "_STRG_ADD_EXPENDABLE", Args: 7, Caller: "AQ_StorageUpdater::AddItem"},
	{Name: "_STRG_ADD_ALCHEMYSTONE", Args: 8, Caller: "AQ_StorageUpdater::AddItem"},
	{Name: "_STRG_ADD_SPECIALTY", Args: 8, Caller: "AQ_StorageUpdater::AddItem"},
	{Name: "_STRG_ADD_ITEM_MAGIC", Args: 10, Variadic: true, Caller: "AQ_StorageUpdater::AddMagicItem"},
	{Name: "_STRG_ADD_PACKAGEITEM", Args: 11, Caller: "AQ_StorageUpdaterForPacakageItem"},
	{Name: "_STRG_ADD_PACKAGEITEM_WITH_STOCKQUANTITY", Args: 12, Caller: "AQ_StorageUpdaterForPacakageItem"},
	{Name: "_STRG_SPLIT_ITEM", Args: 9, Caller: "AQ_StorageUpdater::RearrangeItem"},
	// The cash shop and its undo, a whole subsystem the catalogue had no trace of.
	{Name: "_STRG_BUY_CASHITEM_EQUIP_NORMAL", Args: 12, Caller: "AQ_StorageUpdater::BuyCashItem"},
	{Name: "_STRG_BUY_CASHITEM_EXP", Args: 10, Caller: "AQ_StorageUpdater::BuyCashItem"},
	{Name: "_STRG_RESTORE_SOLDITEM_EQUIP_NORMAL", Args: 11, Caller: "AQ_StorageUpdater::RestoreSoldItem"},
	{Name: "_STRG_RESTORE_SOLDITEM_EXPENDABLE", Args: 8, Caller: "AQ_StorageUpdater::RestoreSoldItem"},
	{Name: "_STRG_RESTORE_SOLDITEM_ALCHEMYSTONE", Args: 9, Caller: "AQ_StorageUpdater::RestoreSoldItem"},
	{Name: "_STRG_RESTORE_SOLDITEM_SPECIALTY", Args: 9, Caller: "AQ_StorageUpdater::RestoreSoldItem"},
	{Name: "_STRG_RESTORE_SOLDITEM_ITEM_MAGIC", Args: 11, Variadic: true, Caller: "AQ_StorageUpdater::RestoreSoldMagicItem"},
	// Skills and quests ARE persisted by a procedure -- see the correction in
	// docs/protocol/persistence.md, which claimed they were not.
	{Name: "_skill_manage", Args: 4, Caller: "AQ_SkillManager::FUN_004587a0"},
	{Name: "_quest_manage", Args: 3, Caller: "AQ_QuestDataManager::FUN_00455f50"},
	// Gold is READ by procedure too, not only written.
	{Name: "_GET_USER_GOLD", Args: 2, Caller: "AQ_CharDataLoader::vslot_006"},
	{Name: "_GET_GUILD_GOLD", Args: 2, Caller: "AQ_CharDataLoader::vslot_006"},
	// The five logging procedures, each called from a _Log* class's slot 0 --
	// a uniform shape that is itself the check that none was missed.
	{Name: "_ADDLOGCHAR", Args: 6, Caller: "_LogChar::vslot_000"},
	{Name: "_ADDLOGITEM", Args: 11, Caller: "_LogItem::vslot_000"},
	{Name: "_ADDLOGSIEGEFORTRESS", Args: 6, Caller: "_LogSiegeFortress::vslot_000"},
	{Name: "_AddLogServerEvent", Args: 3, Caller: "_LogServerEvent::vslot_000"},
	{Name: "_AddLogSchedule", Args: 6, Caller: "_LogSchedule::vslot_000"},
	// The trade-job (Trijob) history, which only _Insert/_Delete were known for.
	{Name: "_AddTrijobReward", Args: 2, Caller: "FUN_00465220"},
	{Name: "_GetOldTrijobData", Args: 8, Caller: "FUN_00465390"},
	{Name: "_QueryOldTrijobInfo", Args: 5, Caller: "FUN_00465000"},
	{Name: "_DeleteOldTrijobData", Args: 1, Caller: "FUN_004652e0"},
	// The remainder.
	{Name: "_AddCollectionBook_Item", Args: 3, Caller: "GObjPC::FUN_0044d0c0"},
	{Name: "_AddFlagEventParticipant", Args: 1, Caller: "FUN_006480e0"},
	{Name: "_Memo_Delete", Args: 1, Caller: "AQ_CharDataLoader::FUN_005d70a0"},
	{Name: "_SiegeFortressCollectForgedItem", Args: 8, Caller: "AQ_Siege::FUN_006282f0"},
}

// ReferenceTables are the 124 read-only tables the server loads at start-up,
// in the binary's own spelling: 85 `_REFNAME`, 10 `TAB_REFNAME`, 29 `_RefName`.
//
// This list said 85 until 2026-09-19 (round 242). It had been harvested from
// the string pool and matched docs/protocol/refdata_tables.md's count from the
// loader functions -- "two probes with nothing in common" -- but both probes
// used an upper-case `_REF` pattern, so both missed the same 39 names. The
// count that is complete is the number of loaders that build a table name
// through FUN_00401fc0(name, len): 124, every one with a CRef* descriptor.
var ReferenceTables = []string{
	"_REFABILITYBYITEMOPTLEVEL",
	"_REFACCESSPERMISSIONOFSHOP",
	"_REFALCHEMYMERIT",
	"_REFCHARDEFAULT_QUEST",
	"_REFCHARGEN",
	"_REFCLIMATE",
	"_REFCONDITIONTOBUYSCRAPITEM",
	"_REFCONDITIONTOSELLPACKAGEITEM",
	"_REFCONDITIONTOSELLSCRAPITEM",
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
	"_REFEVENT",
	"_REFEVENTZONE",
	"_REFGACHACODE",
	"_REFGACHAITEMSET",
	"_REFGACHANPCMAP",
	"_REFGAMEWORLDNPC",
	"_REFGAME_WORLD",
	"_REFGAME_WORLD_CONFIG",
	"_REFHWANLEVEL",
	"_REFINSTANCE_WORLD_REGION",
	"_REFINSTANCE_WORLD_START_POS",
	"_REFLEVEL",
	"_REFMAGICOPT",
	"_REFMAGICOPTASSIGN",
	"_REFMAGICOPTBYITEMOPTLEVEL",
	"_REFMAGICOPTGROUP",
	"_REFMAPPINGSHOPGROUP",
	"_REFMAPPINGSHOPWITHTAB",
	"_REFMONSTER_ASSIGNEDITEMDROP",
	"_REFMONSTER_ASSIGNEDITEMRNDDROP",
	"_REFOBJCHAR",
	"_REFOBJCHAREXTRASKILL",
	"_REFOBJCOMMON",
	"_REFOBJITEM",
	"_REFOBJSTRUCT",
	"_REFOPTIONALTELEPORT",
	"_REFPACKAGEITEM",
	"_REFPRICEPOLICYOFITEM",
	"_REFQUEST",
	"_REFREGION",
	"_REFREGIONBINDASSOCSERVER",
	"_REFREWARDPOLICYTOBUYSCRAPITEM",
	"_REFREWARDPOLICYTOSELLPACKAGEITEM",
	"_REFREWARDPOLICYTOSELLSCRAPITEM",
	"_REFSCRAPOFPACKAGEITEM",
	"_REFSETITEMGROUP",
	"_REFSHARDCONTENTCONFIG",
	"_REFSHOP",
	"_REFSHOPGOODS",
	"_REFSHOPGROUP",
	"_REFSHOPITEMSTOCKPERIOD",
	"_REFSHOPOBJECT",
	"_REFSHOPTAB",
	"_REFSHOPTABGROUP",
	"_REFSIEGEBLESSBUFF",
	"_REFSIEGEDUNGEON",
	"_REFSIEGEFORTRESS",
	"_REFSIEGEFORTRESSBATTLERANK",
	"_REFSIEGEFORTRESSGUARD",
	"_REFSIEGEFORTRESSITEMFORGE",
	"_REFSIEGEFORTRESSREWARDS",
	"_REFSIEGELVLSUMMONMONSTER",
	"_REFSIEGEQUEST",
	"_REFSIEGEQUESTREWARD",
	"_REFSIEGESTRUCTUPGRADE",
	"_REFSKILL",
	"_REFSKILLBYITEMOPTLEVEL",
	"_REFSKILLMASTERY",
	"_REFTELELINK",
	"_REFTELEPORT",
	"_REFTREATITEMOFSHOP",
	// The ten TAB_REF* tables (the AI's four and the six job rankings).
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
	// The 29 mixed-case tables the first census missed (round 242).
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
}

// RuntimeTables are the tables the server reads and writes as it runs.
//
// **CORRECTED 2026-09-17, from 35 to 54.** The first version of this list came
// from harvesting `_UPPERCASE` identifiers out of the string pool with the
// pattern `_[A-Z][A-Z0-9_]{3,}` -- uppercase only -- and that silently dropped
// every mixed-case table name. All twenty it missed are mixed-case, so the
// regex accounts for the gap exactly: `_SiegeFortress`, `_CharTrijob`,
// `_FleaMarketNetwork`, `_Friend`, `_Memo` and fifteen more.
//
// This list is now the 54 tables the binary's own schema pool declares, in its
// order -- see SchemaTableOrder and docs/protocol/db_columns.md. That is a
// better source than a regex over strings, because the pool is what
// Database::BindTableSchema actually binds.
//
// `_LOADED` was in the old list and is NOT here: it does not appear in the
// schema pool. docs/protocol/persistence.md hedged that it "may be a flag
// rather than a table", and its absence from the pool is that hedge resolved.
//
// NOT ONE OF THE 85 REFERENCE TABLES IS IN THIS LIST, and that is structural
// rather than incidental: reference tables are read with `SELECT * FROM %s`
// and consumed positionally by the ExtractData deserializers, so the server
// never needs their column names and the binary does not carry them.
var RuntimeTables = []string{
	"_USER",
	"_CHAR",
	"_CHARCOS",
	"_INVENTORY",
	"_INVENTORYFORAVATAR",
	"_INVENTORYFORLINKEDSTORAGE",
	"_CHEST",
	"_INVCOS",
	"_ITEMQUOTATION",
	"_ITEMS",
	"_CHARSKILL",
	"_CHARSKILLMASTERY",
	"_STRUCT",
	"_DUMMY",
	"_EVENTDAEMON",
	"_SIEGEFORTRESSSTRUCT",
	"_CHARQUEST",
	"_TRAININGCAMP",
	"_TRAININGCAMPMEMBER",
	"_TRAININGCAMPHONORRANK",
	"_TRAININGCAMPBUFFSTATUS",
	"_GUILD",
	"_GUILDMEMBER",
	"_ALLIEDCLANS",
	"_GUILDWAR",
	"_GUILDCHEST",
	"_Friend",
	"_GPHistory",
	"_Memo",
	"_DELETEDCHAR",
	"_TIMEDJOB",
	"_TIMEDJOBFORPET",
	"_STATICAVATAR",
	"_CharInstanceWorldData",
	"_CharTrijob",
	"_FleaMarketNetwork",
	"_SiegeFortress",
	"_SiegeFortressObject",
	"_SiegeFortressItemForge",
	"_SiegeFortressRequest",
	"_SiegeFortressBattleRecord",
	"_SiegeFortressStoneState",
	"_ServerEvent",
	"_ServerEventReward",
	"_LOGEVENTCHAR",
	"_LOGEVENTITEM",
	"_LOGEVENTSIEGEFORTRESS",
	"_LOGSERVEREVENT",
	"_LogSchedule",
	"_ClientConfig",
	"_BlockedWhisperers",
	"_CharTrijobSafeTrade",
	"_AssociationReputation",
	"_CharCollectionBook",
}

// The AsyncQuery interface. All 28 AQ_* classes derive from AQ_Base and
// implement exactly these nine slots -- not most of them, all of them, with no
// exceptions and no class implementing a tenth except four that add 11 to 13.
//
// AQ_Base declares slots 3, 5, 6, 7, 8, 9 and 10 as __purecall, so the shape
// is enforced by the compiler rather than by convention.
const (
	SlotDestructor = 0  // every class overrides it
	SlotReset      = 2  // zeroes the query's own fields and chains to the base
	SlotRelease    = 3  // releases the attached object, if there is one
	SlotIsReady    = 4  // `return this->+0x18`, a byte; shared by 38 vtables
	SlotPrepare    = 5  // `return 1` in most classes
	SlotDoWork     = 6  // THE QUERY. The engine's own name -- see below
	SlotOnSuccess  = 7  // asserts state == 0xb, then the success path
	SlotOnFailure  = 8  // asserts state == 0xb, then the failure path
	SlotOnCleanup  = 9  // empty in most classes
	SlotOnFinish   = 10 // empty in most classes
)

// DoWorkIsTheEnginesName records why SlotDoWork is not a guess: twelve distinct
// log and assert strings across the AQ classes name the method, for example
//
//	"AQ_COSManipulator::DoWork() - nothing to query"
//	"AQ_StorageUpdater::DoWork() Failed! - %d"
//
// and every one of them is inside the function occupying slot 6.
const DoWorkIsTheEnginesName = true

// QueryStateRunning is the value slots 7 and 8 assert the query's state field
// (offset +0x20) holds before they run: `if (state != 0xb) Assert()`. Both the
// success and the failure callback assert the same value, so 0xb is the state
// a query is in while its work is outstanding.
const QueryStateRunning = 0xb
