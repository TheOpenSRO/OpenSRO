package combat

// LootEntry is one possible drop from a monster: a Chance in [0, 1] of
// dropping between MinQuantity and MaxQuantity of ItemID.
type LootEntry struct {
	ItemID      int64
	Chance      float64
	MinQuantity int
	MaxQuantity int
}

// Real, common consumable item IDs, recovered from the private-server client's
// own item data (server_dep\silkroad\textdata\itemdata_5000.txt in the pserver
// Media.pk2). These are standard vSRO IDs every derived client resolves to an
// icon, so a drop actually shows art in the bag.
//
//	ItemHPPotion   = 4   ITEM_ETC_HP_POTION_01  (icon item\etc\hp_potion_01.ddj)
//	ItemMPPotion   = 11  ITEM_ETC_MP_POTION_01
//	ItemHPPotionLg = 6   ITEM_ETC_HP_POTION_03
//	ItemMPPotionLg = 13  ITEM_ETC_MP_POTION_03
//
// The item IDs are real; *which monster drops which* is still this project's
// own assignment (see below), not the game's real per-monster drop table.
const (
	ItemHPPotion   int64 = 4
	ItemMPPotion   int64 = 11
	ItemHPPotionLg int64 = 6
	ItemMPPotionLg int64 = 13
)

// LootTables maps a monster's Name (species, not instance -- every
// "Mangyang" drops from the same table) to the set of items it can drop on
// death, each rolled independently. The item IDs are real (above); the
// assignment is own design, the same pattern as skill.Catalog/quest.Catalog
// -- a small plausible set, not the game's real drop-rate data. Keyed off the
// same species names as cmd/server's monsterSpecs.
//
// refdata.MonsterDrop/refdata.DropGroupEntry exist as real, curated schemas for
// the real _RefMonster_AssignedItemRndDrop/_RefDropItemGroup tables (see
// docs/protocol/refdata_schema.md), and since 2026-09-15 cmd/import-refdata can
// actually load them (-drops-csv, -drop-groups-csv); before that the loaders
// and the store existed but nothing exposed them.
//
// WHAT ACTUALLY BLOCKS THIS, corrected 2026-09-15. An earlier note here said
// the obstacle was that the real tables key by a numeric RefMonsterID "this
// project doesn't have a confirmed name->ID mapping to". That mapping is one
// column lookup: characterdata's col 1 is the RefObjChar id and col 2 the code
// name, so MOB_CH_MANGNYANG is 1933, the same shape as itemdata's id/code-name
// pair this project already reads.
//
// The real obstacle is that the drop tables are SERVER-SIDE DATABASE tables and
// are not in the client archives at all -- Media.pk2's server_dep textdata
// listing carries characterdata, leveldata, levelgold, hwanleveldata and the
// rest, and no drop or rnd-drop table of any kind. So this stays own design
// until an operator brings those tables, which the importer is now able to
// accept. Chasing the name->ID mapping would have been chasing the wrong thing.
//
// UPDATE 2026-09-15: the missing DATA is still missing, but the missing
// ALGORITHM no longer is. CRefDropData__AddAssignedItemDrop has been read, and
// refdata.RollAssignedDrop / refdata.SelectFromGroup now implement it exactly:
// an attempt count picked in [DropAmountMin, DropAmountMax] with DropRatio
// rolled independently per attempt against a per-million roll, and a cumulative
// SelectRatio pick within the group. So the table below is the only thing still
// standing in for real data -- the machinery to consume that data faithfully is
// written and tested.
//
// UPDATE 2026-09-20: THE SECOND BLOCKER IS GONE AND THE REAL PATH IS ON.
// combat.Monster now carries RefObjID, and session.dropsForKill consults the
// real tables first, falling back to this one only when a monster has no rows
// in them. The key had in fact existed upstream since 2026-09-19 as
// cmd/server's monsterSpec.RefObjID -- it was simply never passed down, so the
// loaders, the store and the recovered roll all sat one field away from being
// reachable. Both loot paths (ground drops and straight-to-inventory) go
// through dropsForKill, because wiring only one would have left the path
// cmd/server actually runs on this table.
//
// ONE thing remains, and it is not this file's to fix: an operator must supply
// the tables. Until they do, everything below is what a kill drops.
//
// The two blockers as they were recorded: an operator must supply the tables,
// and combat.Monster carries CodeName but no numeric RefObjID, which is the key
// those tables use.
// The rates below are the engine's shape only by accident -- each entry here is
// a single independent roll with a separate quantity, which is NOT what the
// engine does (see refdata.MonsterDrop's own comment).
var LootTables = map[string][]LootEntry{
	// Keyed by the species names the game's own tables use, matching the
	// spawns in cmd/server. Renaming the spawns without renaming these
	// would have silently dropped every monster's loot.
	//
	// The whole Jangan ladder (levels 1-10) plus the Earth Ghost is covered so
	// no spawned monster drops nothing. The names are grounded (characterdata);
	// the drop chances/quantities are own design, scaling loosely with level --
	// low mobs give small potions at high rates, higher ones start giving the
	// large variants. Not the game's real per-monster drop rates.
	"Mangyang": { // L1
		{ItemID: ItemHPPotion, Chance: 1.0, MinQuantity: 1, MaxQuantity: 2},
	},
	"Small-eyed Ghost": { // L2
		{ItemID: ItemHPPotion, Chance: 0.8, MinQuantity: 1, MaxQuantity: 2},
	},
	"Big-eyed Ghost": { // L3
		{ItemID: ItemHPPotion, Chance: 0.6, MinQuantity: 1, MaxQuantity: 2},
		{ItemID: ItemMPPotion, Chance: 0.3, MinQuantity: 1, MaxQuantity: 1},
	},
	"Old Weasel": { // L4
		{ItemID: ItemMPPotion, Chance: 0.6, MinQuantity: 1, MaxQuantity: 2},
	},
	"Weasel": { // L5
		{ItemID: ItemMPPotion, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
	},
	"Water Ghost slave": { // L6
		{ItemID: ItemHPPotion, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
		{ItemID: ItemMPPotion, Chance: 0.4, MinQuantity: 1, MaxQuantity: 2},
	},
	"Water Ghost": { // L7
		{ItemID: ItemHPPotion, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
		{ItemID: ItemMPPotion, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
	},
	"Tomb Stone Ghost": { // L8
		{ItemID: ItemHPPotion, Chance: 0.4, MinQuantity: 1, MaxQuantity: 2},
		{ItemID: ItemMPPotion, Chance: 0.4, MinQuantity: 1, MaxQuantity: 2},
	},
	"Stone Ghost": { // L9
		{ItemID: ItemHPPotionLg, Chance: 0.25, MinQuantity: 1, MaxQuantity: 1},
		{ItemID: ItemMPPotion, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
	},
	"Yeoha": { // L10
		{ItemID: ItemHPPotionLg, Chance: 0.3, MinQuantity: 1, MaxQuantity: 1},
		{ItemID: ItemMPPotionLg, Chance: 0.4, MinQuantity: 1, MaxQuantity: 2},
	},
	"Earth Ghost": { // L27
		{ItemID: ItemHPPotionLg, Chance: 0.3, MinQuantity: 1, MaxQuantity: 1},
		{ItemID: ItemMPPotionLg, Chance: 0.75, MinQuantity: 1, MaxQuantity: 3},
	},
}
