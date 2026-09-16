// Package refdata holds this project's own static game-data model (item
// stats, and eventually skills/drops) plus an importer for populating it
// from a player-supplied export of their own legally-obtained game data —
// the same "bring your own data" approach this repo already uses for pk2
// client assets (see docs/LEGAL.md). No actual game-balance numbers are
// ever committed to this repo; only the schema/format is.
package refdata

import "errors"

// ErrItemNotFound means the store has no row for that item id. It is a
// normal answer, not a failure: reference data is brought by the operator
// (see docs/LEGAL.md), so a deployment that has imported nothing -- or has
// imported a partial export -- has items nobody has stats for. Callers
// treat those as contributing nothing rather than refusing to work, and
// keep real errors for a lookup that actually broke.
var ErrItemNotFound = errors.New("refdata: no such item")

// Item is this project's own, deliberately curated subset of item stats —
// not a 1:1 mirror of the original's ~105-column layout (documented
// structurally in docs/protocol/refdata_schema.md), just the fields that
// matter for combat/equipment math. Extend as gameplay needs grow.
type Item struct {
	ID       int64
	MaxStack int
	// TypeID1..4 are the game's own four-level classification of the item:
	// 3/1/x/y is equipment, where TypeID3 says which family (China's
	// garment/protector/armour are 1/2/3, Europe's robe/light/heavy are
	// 9/10/11, weapons 6, shields 4, accessories 7) and TypeID4 which
	// piece -- for armour 1 helm, 2 shoulder guard, 3 mail, 4 pants,
	// 5 gauntlet, 6 boots, which is what decides the slot an item may go
	// in. See docs/protocol/ITEM_FORMAT.md.
	TypeID1, TypeID2, TypeID3, TypeID4 int
	// Country is the race the item belongs to: 0 China, 1 Europe, 3 either.
	Country int
	// ReqGender is who may wear it: 1 a man, 0 a woman, 2 either.
	ReqGender int
	// ReqLevelType1/ReqLevel1 are the first of the table's four requirement
	// pairs. Type 1 is the character's own level -- what every ordinary
	// armour and weapon row carries.
	ReqLevelType1, ReqLevel1 int
	ReqStr                   int
	ReqInt                   int
	ItemClass                int
	// Price is the NPC buy price in gold, and SellPrice what the NPC pays to
	// buy it back -- both real, from the client's own itemdata (_RefObjCommon
	// Price and SellPrice columns; SellPrice < Price on every row checked).
	// This is the one place the earlier "no real vendor price" conclusion was
	// wrong: it held for the restored DB's _RefObjItem, but the client
	// itemdata.txt carries these columns. Zero when an import predates them,
	// in which case the shop falls back to its own formula. See
	// docs/protocol/refdata_schema.md.
	Price     int64
	SellPrice int64

	// RestoreHP/RestoreMP are how much health/mana using this item gives
	// back, and the Pct pair the same as a percentage of the maximum. REAL,
	// and unusually self-evidencing: the item table's Param block stores each
	// value beside its own description, so col 118 is followed by the literal
	// label "HP..." and col 122 by "MP...", with the "(%)" variants at 120 and
	// 124. HP_POTION_01 carries 120 in the HP column and nothing in the MP
	// one; MP_POTION_01 the mirror image. The large potions carry 370.
	RestoreHP                      int
	RestoreHPPct                   int
	RestoreMP                      int
	RestoreMPPct                   int
	TwoHanded                      bool
	DurabilityMin, DurabilityMax   float64
	PhysDefenseMin, PhysDefenseMax float64
	MagDefenseMin, MagDefenseMax   float64

	// WHICH END OF A RANGE srrevamp USES, in one place, because the answer is
	// not consistent and the inconsistency is deliberate rather than an
	// oversight.
	//
	// A real item has per-instance variance: the table gives a range and each
	// dropped or bought instance sits somewhere inside it. srrevamp models no
	// such variance, so every consumer has to pick an end, and neither end is
	// more correct than the other:
	//
	//	defenderArmor       PhysDefenseMax   (long-standing; also feeds the
	//	                                      shop price and the shop listing
	//	                                      the client displays)
	//	attackerCritical    CriticalMin      (col 116, the variance FLOOR --
	//	                                      and this IS a choice after all.
	//	                                      An earlier note here said the
	//	                                      "Max" field was not the same
	//	                                      stat, on the strength of the
	//	                                      tooltip showing a single value.
	//	                                      It is the same stat: col 117 is
	//	                                      its per-instance variance
	//	                                      ceiling, which a single instance
	//	                                      never displays as a range. See
	//	                                      cmd/export-refdata for the engine
	//	                                      triple that settles it.)
	//	defenderBlock       BlockRatioMin    (a genuine 10~20 range; the low
	//	                                      end, so a shield is never
	//	                                      overstated)
	//
	// Changing defenderArmor to match would move a displayed stat and a shop
	// price for no grounded reason, so it stays; this comment is the record
	// that the difference was examined rather than missed.

	// BlockRatioMin/BlockRatioMax are a SHIELD's block ratio, itemdata
	// columns 74-75 -- present on exactly the 500 shield rows in the real
	// table and reading 10~20 on a starter shield. It is the chance, in
	// percent, that a blow at the wearer is blocked outright; see
	// combat.RollChance and session.defenderBlock.
	BlockRatioMin, BlockRatioMax float64
	// ReinforcePhys/Mag are a WEAPON's reinforce percentages, itemdata
	// columns 105/107 (physical) and 109/111 (magical), stored HERE IN THE
	// TABLE'S OWN UNIT: tenths of a percent, so a Copper Sword's 306 means
	// 30.6%. combat.ReinforceDamage is the one place that converts.
	//
	// This is the game's Strength-to-damage coupling, and it is a range
	// endpoint rather than a multiplier on the result. GObjPC_InitStats
	// declares the chain:
	//
	//	Str(1) -> 17 -> 13 (phys dmg min)   with 34 -> 17 at slot 3
	//	Str(1) -> 18 -> 14 (phys dmg max)   with 36 -> 18 at slot 3
	//
	// Slot 3 is the percent scale, so param 17 evaluates to Str*reinforce/100,
	// and it lands in param 13's slot 0 ALONGSIDE the weapon's own flat range.
	// Slot 0 SUMS entries keyed by distinct ctx (GParamKeeper's reduce,
	// 004b2e60), and the two arrive under different keys: the weapon's range
	// is stored with ctx = the item pointer, the derived term with ctx = the
	// source param's object (Param_PropagateToDependents). So they coexist and
	// add -- a player's physical attack is the weapon's range PLUS a
	// Str-derived term.
	//
	// THE USE-SITE, not a curve: FUN_0040db50 -- the helper the real attack
	// roll calls twice for its two bounds -- reads
	//
	//	iVar4 = (unaff_EDI != 0) + 0xd;                // 13 or 14
	//	fVar5 = (**(code **)(*in_EAX + 0x104))(iVar4); // GetParam(13/14)
	//
	// so the damage bounds ARE params 13/14. (Formula_RollWeaponDamage exists
	// too and reads 190/191, which receive only the weapon's flat range and
	// are never a bind target -- a separate, simpler path. Char_PublishCombatStats
	// publishes the same two floats into both pairs, which is why they look
	// identical at publish time and differ at evaluation time.)
	//
	// The columns are pinned by the engine's own innate defaults, which
	// GObjPC_InitStats writes as .rdata constants: 30.6 / 34.2 / 49.0 / 54.8
	// for params 34/36/35/37. Those are exactly the FLOORS of columns
	// 105/107/109/111 across all 1,568 weapon rows -- four constants matching
	// four independent column minima.
	//
	// A weapon's own reinforce REPLACES that innate default rather than adding
	// to it: InitStats writes param 34 with ctx 0 and Char_PublishCombatStats
	// republishes it with ctx 0 too, and a same-key store overwrites. An
	// unarmed character keeps the 30.6/34.2 default; this project does not
	// model that yet (see session.unarmedDamage) and takes 0 there.
	ReinforcePhysMin, ReinforcePhysMax float64
	ReinforceMagMin, ReinforceMagMax   float64
	PhysAttackMin, PhysAttackMax       float64
	MagAttackMin, MagAttackMax         float64
	HitRateMin, HitRateMax             float64
	CriticalMin, CriticalMax           float64
}
