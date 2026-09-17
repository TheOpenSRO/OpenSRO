// Package persistence is the database surface the real server used, recovered
// from SR_GameServer.exe.
//
// Nothing here is designed. The procedure names and their argument counts were
// read out of the ODBC call literals the binary builds -- `{?=CALL _NAME (%d,
// %d, ...)}` -- and the table names out of its string pool. srrevamp does not
// have to use this schema, but it is what the game's own operations are, and a
// reimplementation that cannot express one of these has found a gap.
//
// See docs/protocol/persistence.md.
package persistence

// Proc is one stored procedure as the server calls it.
type Proc struct {
	Name string
	// Args is the number of parameter placeholders in the call literal. It is
	// the count in the widest literal found, because a few procedures are
	// called from more than one site.
	Args int
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
}

// ReferenceTables are the 85 read-only tables the server loads at start-up.
// This list was harvested from the string pool and is EXACTLY the set
// docs/protocol/refdata_tables.md enumerated from the 85 loader functions --
// same count, same members, from two probes with nothing in common. That is
// what makes "85" a complete count rather than a count of what was found.
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
}

// RuntimeTables are the tables the server reads and writes as it runs: the
// character, inventory, guild and log tables. Unlike the reference tables
// these have no loader to enumerate them, so this list is what the string pool
// carries and may be incomplete -- a table only touched through a stored
// procedure would not appear.
var RuntimeTables = []string{
	"_ALLIEDCLANS",
	"_CHAR",
	"_CHARCOS",
	"_CHARQUEST",
	"_CHARSKILL",
	"_CHARSKILLMASTERY",
	"_CHEST",
	"_DELETEDCHAR",
	"_DUMMY",
	"_EVENTDAEMON",
	"_GUILD",
	"_GUILDCHEST",
	"_GUILDMEMBER",
	"_GUILDWAR",
	"_INVCOS",
	"_INVENTORY",
	"_INVENTORYFORAVATAR",
	"_INVENTORYFORLINKEDSTORAGE",
	"_ITEMQUOTATION",
	"_ITEMS",
	"_LOADED",
	"_LOGEVENTCHAR",
	"_LOGEVENTITEM",
	"_LOGEVENTSIEGEFORTRESS",
	"_LOGSERVEREVENT",
	"_SIEGEFORTRESSSTRUCT",
	"_STATICAVATAR",
	"_STRUCT",
	"_TIMEDJOB",
	"_TIMEDJOBFORPET",
	"_TRAININGCAMP",
	"_TRAININGCAMPBUFFSTATUS",
	"_TRAININGCAMPHONORRANK",
	"_TRAININGCAMPMEMBER",
	"_USER",
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
