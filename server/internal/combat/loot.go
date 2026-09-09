package combat

// LootEntry is one possible drop from a monster: a Chance in [0, 1] of
// dropping between MinQuantity and MaxQuantity of ItemID.
type LootEntry struct {
	ItemID      int64
	Chance      float64
	MinQuantity int
	MaxQuantity int
}

// LootTables maps a monster's Name (species, not instance -- every
// "Mangyang" drops from the same table) to the set of items it can drop on
// death, each rolled independently. Own design, same pattern as
// skill.Catalog/quest.Catalog: a small fixed set, not real drop-rate data.
// Item IDs 500-502 are cmd/server's own placeholder ref items, matching
// docs/protocol/refdata_schema.md's "bring your own data" approach --
// operators importing real refdata should pick real item IDs here. Keyed
// off the same species names as cmd/server's monsterSpecs.
//
// refdata.MonsterDrop/refdata.DropGroupEntry now exist as real, curated
// schemas for the real _RefMonster_AssignedItemRndDrop/_RefDropItemGroup
// tables (see docs/protocol/refdata_schema.md) -- real per-monster drop
// rates and real item-group weights are importable. Not wired in here yet:
// this map is keyed by monster *name* (this project's own design), while
// the real tables key by a real numeric RefMonsterID this project doesn't
// have a confirmed mapping from species name to yet.
var LootTables = map[string][]LootEntry{
	// Keyed by the species names the game's own tables use, matching the
	// spawns in cmd/server. Renaming the spawns without renaming these
	// would have silently dropped every monster's loot.
	"Mangyang": {
		{ItemID: 500, Chance: 1.0, MinQuantity: 1, MaxQuantity: 1},
	},
	"Weasel": {
		{ItemID: 501, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
	},
	"Earth Ghost": {
		{ItemID: 500, Chance: 0.3, MinQuantity: 1, MaxQuantity: 1},
		{ItemID: 502, Chance: 0.75, MinQuantity: 1, MaxQuantity: 3},
	},
}
