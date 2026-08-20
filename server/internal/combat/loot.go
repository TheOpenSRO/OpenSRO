package combat

// LootEntry is one possible drop from a monster: a Chance in [0, 1] of
// dropping between MinQuantity and MaxQuantity of ItemID.
type LootEntry struct {
	ItemID      int64
	Chance      float64
	MinQuantity int
	MaxQuantity int
}

// LootTables maps a monster's Name (species, not instance -- every "Stone
// Golem" drops from the same table) to the set of items it can drop on
// death, each rolled independently. Own design, same pattern as
// skill.Catalog/quest.Catalog: a small fixed set, not real _RefObjItem
// drop-rate data (which hasn't been catalogued). Item IDs 500-502 are
// cmd/server's own placeholder ref items, matching docs/protocol/
// refdata_schema.md's "bring your own data" approach -- operators
// importing real refdata should pick real item IDs here. Keyed off the
// same species names as cmd/server's monsterSpecs.
var LootTables = map[string][]LootEntry{
	"Stone Golem": {
		{ItemID: 500, Chance: 1.0, MinQuantity: 1, MaxQuantity: 1},
	},
	"Wild Boar": {
		{ItemID: 501, Chance: 0.5, MinQuantity: 1, MaxQuantity: 2},
	},
	"Sand Scorpion": {
		{ItemID: 500, Chance: 0.3, MinQuantity: 1, MaxQuantity: 1},
		{ItemID: 502, Chance: 0.75, MinQuantity: 1, MaxQuantity: 3},
	},
}
