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
	// 9/10/11, weapons 6, shields 4, job suits 7, accessories 5 for China
	// and 12 for Europe) and TypeID4 which piece -- for armour 1 helm,
	// 2 shoulder guard, 3 mail, 4 pants, 5 gauntlet, 6 boots, which is what
	// decides the slot an item may go in. See docs/protocol/ITEM_FORMAT.md.
	//
	// REFINEMENT 2026-09-16: TypeID3 == 4 is not only shields. It holds shields
	// AND ammunition, told apart by TypeID2 -- (3,1,4,1) is ITEM_CH_SHIELD and
	// (3,3,4,1) is a quiver of arrows; (3,1,4,2) is ITEM_EU_SHIELD and (3,3,4,2)
	// is bolts.
	//
	// AND THE CONCLUSION DRAWN FROM THAT WAS WRONG, corrected the same day.
	// It said equipment.SlotFor was "already correct ... it rejects anything
	// whose TypeID2 is not TypeEquipment (1) before it looks at TypeID3 at all,
	// so ammunition never reaches the shield branch." Rejecting ammunition is
	// not correct, it is the bug: the engine's own resolver
	// (GObjPC::FUN_00496c20) has a second arm that returns the SHIELD slot for
	// TypeID2 == 3, TypeID3 == 4. Arrows are equipped, where a shield would go.
	// The note reasoned about srrevamp's code and never asked the engine.
	TypeID1, TypeID2, TypeID3, TypeID4 int
	// Country is the race the item belongs to: 0 China, 1 Europe, 3 either.
	Country int
	// ReqGender is who may wear it: 1 a man, 0 a woman, 2 either.
	ReqGender int
	// The table's four requirement pairs, in the engine's own order. Type 1
	// is the character's own level -- what every ordinary armour and weapon
	// row carries. See equipment.Requirement for the rest of the vocabulary
	// and for how the engine combines them.
	//
	// ALL FOUR ARE CARRIED AS OF 2026-09-16; only the first used to be.
	// _RefObjCommon stores them as four (int32 type, uint8 value) pairs at
	// +0xb4/+0xb8 stride 8, filled from columns 32..39 by a four-iteration
	// loop in RefObjCommon_ExtractData, and CheckEquipRequirements
	// (0x004919e0) reads every one. Over a real client's 23,327 item rows the
	// later slots are not decoration: 3,372 rows carry mastery requirements
	// there, 8 carry a type 0x301, and 7 carry a SECOND character-level
	// requirement that reading only the first pair drops on the floor.
	ReqLevelType1, ReqLevel1 int
	ReqLevelType2, ReqLevel2 int
	ReqLevelType3, ReqLevel3 int
	ReqLevelType4, ReqLevel4 int

	// RepairCost is what a FULL repair of this item costs in gold -- itemdata
	// column 27, GROUNDED 2026-09-17 from the engine's own arithmetic rather
	// than from the column's shape, and the COLUMN CORRECTED from 28 to 27 on
	// 2026-09-20 (round 304).
	//
	// GItemEquip::ComputeRepair (0x00496e60) computes
	// `price = refRecord[0xa4] / maxDurability` and `cost = price * units`, so
	// repairing from zero to full buys `units = maxDurability` and costs exactly
	// `refRecord[0xa4]`. `refRecord[0xa4]` is _RefObjCommon **field 28**, and
	// field 28 is text **column 27**: the deserializer's field index is 1-based
	// over the row and the column index is 0-based, so they differ by one.
	//
	// The earlier note equated them, which put RepairCost on `+0xa8` -- the
	// adjacent flat restore cost, an authored 1.5x the basis -- and overcharged
	// every repair by half again. DecayTimeMs, four fields below in this same
	// struct, had the relationship right all along: it records "field 14 ...
	// column 13". The struct contradicted itself.
	//
	// ITEM_CH_SWORD_01_A: column 27 = 198 against durability 62/76, so 2.6 gold a
	// unit and 198 for a full repair, against a vendor Price of 890. Column 28
	// holds 297, which is the `+0xa8` restore cost, not this.
	//
	// Zero for an item whose export predates the column. CORRECTED 2026-09-17:
	// this comment used to claim repair.Estimate treats a zero basis as "no basis
	// known" rather than "free". It does neither. UnitPrice clamps the price to a
	// floor of 1.0 -- the engine's own `fld1`, so this is faithful -- and
	// Estimate(1000000, 0, 76, 0) returns {Units:76 Cost:76}: a missing basis
	// silently charges one gold per durability point. A caller that cares about
	// the difference must check RepairCost == 0 itself; nothing here refuses it.
	//
	// Note also that repair.Estimate has NO callers in the server yet -- there is
	// no repair handler -- so this field is loaded but not consumed.
	RepairCost int

	// DecayTimeMs is how long this item lies on the ground before the world
	// removes it, in milliseconds -- itemdata column 13 (`_RefObjCommon
	// DecayTime`). READ 2026-09-19 (round 227): the server's common-record
	// deserializer stores field 14 at +0x84 as `int / 1000.0` (RefObjCommon_ExtractData
	// 0x6a334b, the divisor being the 1000.0 at 0xb45c68), field 14 converts to
	// text column 13 by the documented rule (refobj_binary_format.md; the same
	// rule places the regen amount at field 41 = column 40), and CGObj::Update
	// (0x484d10) accumulates the object's seconds in life-state 2 and removes it
	// (slot 218 -> SetLifeState(3)) once they pass that float; a dropped item
	// enters the world in state 2 with the accumulator at zero
	// (CGObj::EnterWorld -> slot 226 -> SetLifeState(2, 0xff, 0)). In the
	// player's own table: 10000 for 2,435 of 2,876 rows in itemdata_5000 (gold,
	// potions, weapons, armour), 180000 for 420, 1800000 for 18, 3600000 for 1.
	// Zero means the export predates this column; grounditem falls back to its
	// disclosed constant then.
	DecayTimeMs int
	ReqStr      int
	ReqInt      int
	ItemClass   int
	// SetID is the item set this piece belongs to, 0 for most items. It is
	// the key of the game's own `_RefSetItemGroup` table (shipped as
	// `textdata\refsetitemgroup.txt`), and wearing one piece in each of a
	// set's slots grants a bonus.
	//
	// Grounded twice, independently. The server reads it into its RefObjItem
	// at +0x1ac -- the next field after ItemClass in RefObjItem::vslot_001's
	// consecutive march (+0x198 +0x19c +0x1a0 +0x1a4 +0x1a8 +0x1ac), which is
	// what makes it column 62 -- and CSetMagicOptionOP::PutoutTheBindingItem
	// reads that same offset and logs it in the engine's own words:
	// `"## %s %d ## Invalid data is used! [SetID:%d]"`.
	//
	// The data agrees: joining column 62 against the set table's own code
	// names, the race and gender spelled in the item's name match the ones in
	// its set's name on 360 of 360 rows where both spell them. The decoy
	// columns that also hold only legal set ids score ~25%, which is chance
	// for a four-way split.
	//
	// The bonus is a `MagicOptGroupID` into `refmagicoptgroup.txt`, chosen by
	// how many pieces are worn -- see equipment.BonusTier, which carries the
	// tier rule and the evidence. (A note here said the tier columns "are not
	// decoded"; they were decoded the following tick.) srrevamp models set
	// membership, completion and tier selection, and grants nothing, because
	// it has no magic-option system to grant into.
	SetID int
	// CanTrade, CanSell and CanDrop are three of the engine's item capability
	// flags -- itemdata columns 16, 17 and 20. REAL, and grounded in both
	// directions. (CanDrop was read from column 19 until round 494.)
	//
	// The engine keeps these as bits of one word on the item's reference row
	// (`+0x8c`), and the base class names each bit with an `## Illegal ##`
	// virtual stub: `IGObj::CanTrade`, `IGObj::CanSell`, `IGObj::CanDrop` and
	// six more. `CGObjCOS_Summoned` implements all nine, each a two-line reader
	// of one bit. Zero means REFUSE -- a set bit is permission -- and the trade
	// handler returns `0x183a UIIT_MSG_STRGERR_CANNOT_BE_TRADED` when CanTrade
	// answers zero.
	//
	// The columns come from `RefObjCommon_ExtractData`'s (0x006a3090) own
	// column counter, `[stream+0x28]`, bumped once per column -- see
	// docs/protocol/item_capability_flags.md, round 460's table ("The columns,
	// anchored against real data"). Column 18 is consumed without a load
	// (0x6a33f0/0x6a33f6), so the byte after CanSell's is column 19.
	//
	// Column 19 is NOT CanDrop. It is a packed byte, tested `& 0x80` and
	// `& 0x40` for flags bits 12 and 13, which the engine does not name. It is
	// the column that reads 255/128/223/192 in real data. CanDrop is column 20
	// (0/1/3): the parser takes its `& 1` as bit 4, CanDrop, and its `& 2` as
	// the unnamed bit 14. It also clears a CanDrop byte of exactly 1 when
	// CanTrade is 0 (0x6a34e6..0x6a34f7). export-refdata applies both rules
	// and ships CanDrop as 0/1.
	//
	// The class check this comment used to call decisive -- starter items
	// (`_A_DEF`) and quest items (`ITEM_QNO_`) bound, ordinary swords free --
	// confirms CanTrade. It never chose between columns 19 and 20 for CanDrop.
	// Over the combined itemdata (21,552 rows) the classes it named read
	// nearly the same under both: `_A_DEF` rows are droppable on 0 of 81
	// either way, `ITEM_QNO_` on 37 or 0 of 851, and non-rare `ITEM_CH_SWORD_`
	// on 83 or 82 of 89 (column 19 first). Cash-shop rows do differ, 727 of
	// 750 against 10, but "cash-shop items are droppable" was an expectation,
	// not a measurement. The binary's column counter decides it.
	//
	// Nothing in srrevamp reads CanDrop yet: it has no drop-from-bag path.
	CanTrade bool
	CanSell  bool
	CanDrop  bool
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
	// They are the Param1..4 columns of EVERY row, and restore amounts only
	// on the recovery kinds (TypeID 3/3/1 with TypeID4 outside 4..10, round
	// 491): on any other row they mean something else -- a storage
	// expansion's Param1 is its slot increment (round 270), a return
	// scroll's reads 30000.
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
	// dropped or bought instance sits somewhere inside it. Since 2026-09-19
	// srrevamp instances carry that variance (inventory.Instance.Variance),
	// and the two DEFENCE sums read the engine's own interpolation through it
	// (session.defenderArmor, durability.WhiteStat). The consumers below
	// still pick an end, for the reasons given:
	//
	//	shop price/listing  PhysDefenseMax   (a listing shows the range's top;
	//	                                      an unsold item has no instance)
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
	//	(defenderBlock left this list in round 245: a worn shield's block
	//	rate is its instance's white stat, BR_L + q*(BR_U-BR_L), like the
	//	armour's defence and the weapon's damage before it.)
	//
	// defenderArmor used to be in this list at PhysDefenseMax; it left it
	// when the variance arrived, because with an instance in hand the engine's
	// rule is readable and there is no end to pick.

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
	// ParryRatioMin/Max are BODY ARMOUR's parry pair, itemdata columns 68/69,
	// which the engine reads as ParamKeeper param 9 ('era'). It is the exact
	// complement of BlockRatio: across all 21,560 rows no item carries both, and
	// every non-zero block row is a shield while no non-zero parry row is.
	// Carried but NOT YET CONSUMED -- it is the defender's half of the engine's
	// damage centre, which srrevamp still rolls uniformly
	// (docs/RE_COMPLETION.md, "The distribution is still uniform").
	ParryRatioMin, ParryRatioMax float64
	CriticalMin, CriticalMax     float64

	// The per-instance HIGH ends of the eight weapon stats above, itemdata
	// columns 96/98, 101/103 (attack) and 106/108, 110/112 (reinforce). Each
	// weapon stat is a (lo, hi) pair the engine interpolates by the INSTANCE's
	// variance -- Char_BuildAggregateStats (0x00495d60), weapon branch:
	// damage min/max by group 4 (physical, ref +0x228/+0x22c and
	// +0x234/+0x238 -> item +0x1b8/+0x1bc, params 13/14) and group 5
	// (magical, +0x240/+0x244 and +0x24c/+0x250 -> +0x1c0/+0x1c4, params
	// 15/16); the reinforce pairs by group 1 (physical, +0x258/+0x25c and
	// +0x264/+0x268) and group 2 (magical, +0x270/+0x274 and +0x27c/+0x280),
	// read off the disassembly 2026-09-19 (round 244). The *Min/*Max fields
	// above are the lo ends (columns 95/97, 100/102, 105/107, 109/111); an
	// export older than these eight columns leaves the hi ends 0, and
	// combat.WeaponRange then uses the lo end alone, as it always did.
	PhysAttackMinHi, PhysAttackMaxHi       float64
	MagAttackMinHi, MagAttackMaxHi         float64
	ReinforcePhysMinHi, ReinforcePhysMaxHi float64
	ReinforceMagMinHi, ReinforceMagMaxHi   float64

	// Range is the weapon's reach, itemdata column 94 (the item ref record's
	// u16 at +0x224), in world units = tenths of a metre: every sword and
	// blade 6, spear and glaive 18, bow and crossbow 180, dagger 3 in the
	// retail table. Char_PublishCombatStats publishes it as ParamKeeper param
	// 33, and the server's action tick adds it to the two BCRadius values to
	// decide how far a blow lands -- combat.ApproachBand (round 247).
	Range int

	// ReinforceRates are the three packed success-rate dwords an ELIXIR row
	// carries: itemdata Param2/Param3/Param4 (columns 120/122/124), which the
	// item parser's 20-element loop stores at record+0x2c0/+0x2e0/+0x300 --
	// elements 1..3 of the (dword, string) array -- and
	// CEnchant_Reinforce::LookupPackedRate reads by tier. Four percentages per
	// dword, high byte first; the table's own Desc128 texts for the three are
	// "1,2,3,4", "5,6,7,8" and "9,10,11,12": the plus levels each dword packs
	// (round 262). alchemy.BaseRate unpacks them (ReinforceRates gathers the
	// three). The columns carry Param2/3/4 of EVERY row: only an elixir's
	// (TypeID 3/3/10) are rates -- a cure pill's read 3/100/20000, a coupon's
	// export as 0 for "-1" -- so a reader must check the kind first. Zero on
	// exports predating the columns.
	ReinforceRate1, ReinforceRate2, ReinforceRate3 uint32

	// CooltimeGroup / CooltimeMs are the item's reuse delay: the item parser
	// finds the Param/Desc128 pair whose descriptor reads "COOLTIME:<group>"
	// and stores the group at ref+0x520 and the delay, in milliseconds, at
	// ref+0x524. Item_HandleUseItem refuses a use (0x185b,
	// WAIT_FOR_REUSE_DELAY) while the character's timer for that GROUP runs,
	// and arms it for CooltimeMs on success; items sharing a group share the
	// timer (round 263). 148 retail rows carry one (cure pills 20 s, event
	// items up to 23 h); no HP/MP potion does, so a potion has no server
	// cooldown. Zero when the row has none.
	CooltimeGroup uint32
	CooltimeMs    int

	// CanUse is flags bit 8, itemdata column 24 (round 489). Item_HandleUseItem
	// (0x00510980) asks the item's vtable slot 56 -- IGObj::CanUse, which every
	// CGItem* class inherits as CGObj::CanUse (0x00483ee0, `refobj+0x8c >> 8 &
	// 1`) -- before it looks at the item's type or its cooldown, and a zero
	// refuses the use with 0x183e UIIT_MSG_STRGERR_CANNOT_BE_USED. The column
	// is set on every HP/MP potion and clear on elixirs, alchemy stones,
	// materials and all equipment but 28 cash-shop avatars; see
	// docs/protocol/item_capability_flags.md.
	//
	// A permission, so the CSV loader and the SQL store both default it to
	// TRUE for an export that predates the column. A literal Item{} leaves it
	// false and so FORBIDS use -- a hand-built item meant to be drunk must say
	// CanUse: true.
	CanUse bool

	// CanPick is flags bit 5, itemdata column 21 (round 493).
	// GObjPC::CheckCanPickUp (0x004a9050) asks the item's vtable slot 53 --
	// IGObj::CanPick, CGObj::CanPick (0x00483e50, `refobj+0x8c >> 5 & 1`) in
	// every CGItem* vtable -- straight after finding the object, before the
	// quest check, the range, the busy flag and the owner, and a zero refuses
	// the pick with 0x1839 UIIT_MSG_STRGERR_CANNOT_BE_PICKED. The column is
	// 0/1; it is 0 on 309 of the combined itemdata's 21,552 rows (the starter
	// `_DEF` gear, fortress items) and 1 on gold and potions. See
	// docs/protocol/item_capability_flags.md and ground_items.md.
	//
	// A permission, defaulted to TRUE by the CSV loader and the SQL store for
	// an export that predates the column. A literal Item{} leaves it false.
	CanPick bool
}

// ReinforceRates is the three packed dwords in tier order, the shape
// alchemy.Inputs.Tiers takes.
func (it *Item) ReinforceRates() [3]uint32 {
	return [3]uint32{it.ReinforceRate1, it.ReinforceRate2, it.ReinforceRate3}
}
