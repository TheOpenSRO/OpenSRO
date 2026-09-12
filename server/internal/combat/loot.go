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
// docs/protocol/refdata_schema.md) -- real per-monster drop rates and item-group
// weights are importable. Not wired in here yet: this map is keyed by monster
// *name* (this project's own design), while the real tables key by a real
// numeric RefMonsterID this project doesn't have a confirmed name->ID mapping to.
var LootTables = map[string][]LootEntry{
	// Keyed by the species names the game's own tables use, matching the
	// spawns in cmd/server. Renaming the spawns without renaming these
	// would have silently dropped every monster's loot.
	"Mangyang": {
		{ItemID: ItemHPPotion, Chance: 1.0, MinQuantity: 1, MaxQuantity: 2},
	},
	"Weasel": {
		{ItemID: ItemMPPotion, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
	},
	"Earth Ghost": {
		{ItemID: ItemHPPotionLg, Chance: 0.3, MinQuantity: 1, MaxQuantity: 1},
		{ItemID: ItemMPPotionLg, Chance: 0.75, MinQuantity: 1, MaxQuantity: 3},
	},
}
