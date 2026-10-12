package refdata

import (
	"encoding/csv"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// itemCSVColumns is the expected column order for LoadItemsCSV, matching
// the columns a player would export from their own restored reference-data
// database. See docs/protocol/refdata_schema.md for what each of the
// original columns means; this is the curated subset refdata.Item keeps.
var itemCSVColumns = []string{
	"ID", "MaxStack", "ReqStr", "ReqInt", "ItemClass", "TwoHanded",
	"Dur_L", "Dur_U", "PD_L", "PD_U", "MD_L", "MD_U",
	"PAttackMin_L", "PAttackMax_U", "MAttackMin_L", "MAttackMax_U",
	"HR_L", "HR_U", "CHR_L", "CHR_U",
	// Appended rather than slotted in by the original's column order, so
	// an export made for the earlier twenty columns is still a prefix of
	// this one.
	"TypeID1", "TypeID2", "TypeID3", "TypeID4", "Country", "ReqGender",
	"ReqLevelType1", "ReqLevel1",
	// Appended later still (real NPC vendor prices): an export made for the
	// earlier 28 columns is a prefix of this one, so both load.
	"Price", "SellPrice",
	// Appended later still (real potion restore amounts, from the item
	// table's self-labelling Param block): again a strict suffix, so every
	// earlier export still loads.
	"RestoreHP", "RestoreHPPct", "RestoreMP", "RestoreMPPct",
	// Appended later still (a shield's real block ratio, _RefObjItem's BR
	// pair): a strict suffix like every block before it, so an export made
	// for any earlier column count still loads and simply blocks nothing.
	"BR_L", "BR_U",
	// Appended later still (a weapon's reinforce percentages, the engine's
	// Str-to-damage coupling): a strict suffix like every block before it, so
	// an export made for any earlier column count still loads and simply
	// contributes no Strength term.
	"ReinforcePhys_L", "ReinforcePhys_U", "ReinforceMag_L", "ReinforceMag_U",
	// Appended later still (the item set a piece belongs to): a strict suffix
	// like every block before it, so an export made for any earlier column
	// count still loads and simply belongs to no set.
	"SetID",
	// Appended later still (the item capability flags): a strict suffix like
	// every block before it, so an older export still loads and simply reports
	// every item as unrestricted.
	"CanTrade", "CanSell", "CanDrop",
	// Appended later still (the three requirement slots past the first): a
	// strict suffix like every block before it, so an older export still
	// loads and simply carries no requirement beyond its first pair -- which
	// is exactly what the loader did before these columns existed.
	"ReqLevelType2", "ReqLevel2", "ReqLevelType3", "ReqLevel3",
	"ReqLevelType4", "ReqLevel4",
	// Appended later still (the item's full-repair cost, itemdata column 28):
	// a strict suffix like every block before it, so an older export still
	// loads and simply reports no repair basis.
	"RepairCost",
	// Appended later still (how long a dropped item lies on the ground,
	// itemdata column 13 DecayTime in milliseconds): a strict suffix like every
	// block before it, so an older export still loads and grounditem keeps its
	// disclosed fallback for every item.
	"DecayTime",
	// Appended later still (round 244): the per-instance HIGH ends of the
	// eight weapon stats -- itemdata columns 96/98, 101/103, 106/108, 110/112.
	// A strict suffix like every block before it, so an older export still
	// loads and a weapon reads its lo ends alone, as it did before.
	"PhysAttackMinHi", "PhysAttackMaxHi", "MagAttackMinHi", "MagAttackMaxHi",
	"ReinforcePhysMinHi", "ReinforcePhysMaxHi", "ReinforceMagMinHi", "ReinforceMagMaxHi",
	// Appended later still (round 247): the weapon's Range, itemdata column
	// 94, world units. A strict suffix; an older export reads 0, unarmed.
	"Range",
	// Appended later still (round 262): an elixir's three packed reinforce
	// success dwords, itemdata Param2/3/4 (columns 120/122/124). A strict
	// suffix; an older export reads zeros, which alchemy.BaseRate turns into
	// a 0 % base rate rather than an invented one.
	"ReinforceRate1", "ReinforceRate2", "ReinforceRate3",
	// Appended later still (round 263): the reuse cooltime group and delay
	// (ms) an item's "COOLTIME:<group>" descriptor carries. A strict suffix;
	// an older export reads 0 and 0: no reuse delay, which is also what the
	// engine does for every row without the descriptor.
	"CooltimeGroup", "CooltimeMs",
	// Appended later still (round 377): body armour's parry pair, itemdata
	// columns 68/69, which the engine reads as ParamKeeper param 9 ('era').
	// A strict suffix; an older export reads 0 and 0, which is what every
	// non-armour row carries anyway -- the pair is the exact complement of
	// BlockRatio, and no retail row has both.
	"ParryRatioMin", "ParryRatioMax",
	// Appended later still (round 489): CanUse, itemdata column 24, the
	// capability bit Item_HandleUseItem refuses on (0x183e). A strict suffix;
	// an older export has no value for it and loads every item as USABLE --
	// the same permission default as CanTrade/CanSell/CanDrop, for the same
	// reason (see parseItemRow).
	"CanUse",
	// Appended later still (round 493): CanPick, itemdata column 21, the
	// capability bit GObjPC::CheckCanPickUp refuses a ground item on
	// (0x1839). A strict suffix; an older export loads every item as
	// PICKABLE, the same permission default as CanUse.
	"CanPick",
	// Appended later still (round 497): CodeName, itemdata column 2, the
	// string GObjPC::CheckCanPickUp compares with "ITEM_QNO_RM_ARCHEMY" to
	// decide who besides a quest item's owner may pick it. A strict suffix;
	// an older export loads every item with an empty code name.
	"CodeName",
	// Appended later still (round 632 review): CompositeDesc, the composite
	// item's FourCC list, e.g. "[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1],[UIU1:
	// ITEM_ETC_INCREASE_HWAN_TIME_01]" -- see Item.CompositeDesc. Empty on
	// every other row and on an older export.
	"CompositeDesc",
	// Appended later still (round 728): KeepingFee, itemdata column 30, the
	// warehouse's per-item deposit fee (see Item.KeepingFee). 0 on an older
	// export.
	"KeepingFee",
	// Appended later still (round 768): the alchemy columns -- CashItem
	// (column 7), Param1/Param5 (118/126), Desc128_1/Desc128_4 (119/125) and
	// MaxMagicOptCount (158); see Item.CashItem. A strict suffix; an older
	// export reads zeros and empty strings, and every alchemy attempt then
	// refuses.
	"CashItem", "Param1", "Param5", "Desc1", "Desc4", "MaxMagicOptions",
	// Appended later still (round 769): the per-plus increments, itemdata
	// columns 67, 70, 73, 78, 81, 99, 104 and 115 (see Item.PlusIncPhysDef).
	// A strict suffix; an older export reads zeros, and a plus adds nothing.
	"PlusIncPhysDef", "PlusIncParry", "PlusIncPhysAbsorb", "PlusIncMagDef", "PlusIncMagAbsorb",
	"PlusIncPhysAtk", "PlusIncMagAtk", "PlusIncAttackRate",
	// Appended later still (round 770): Rarity, _RefObjCommon column 15 (see
	// Item.Rarity). A strict suffix; an older export reads 0, no Seal item.
	"Rarity",
	// Appended later still (round 786): Param6, itemdata column 128 (ref
	// +0x340), the sixth Param a universal pill hands its cure as the zombie
	// slot's strength (FUN_0049ac50 reads +0x2a0..+0x340, see Item.Param6). A
	// strict suffix; an older export reads 0, and that slot is not cured.
	"Param6",
}

// ItemCSVColumnCount is how many columns LoadItemsCSV currently knows. Every
// column past itemCSVRequiredColumns is an optional suffix, so a shorter
// export still loads -- this is for the EXPORTER, which must emit exactly this
// many so the two halves cannot drift apart. export-refdata's round-trip test
// reads it rather than repeating the number, which it had to hand-bump three
// times before this existed.
var ItemCSVColumnCount = len(itemCSVColumns)

// itemCSVRequiredColumns is the prefix every export must carry; the columns
// past it (Price, SellPrice) are optional so an older export still loads.
const itemCSVRequiredColumns = 28

// LoadItemsCSV parses item rows from r, a headerless CSV in
// itemCSVColumns's order (i.e. exactly what a plain `SELECT <those
// columns> FROM _RefObjItem ORDER BY ID` export produces). Returns a
// descriptive error naming the row/column on any parse failure rather than
// silently skipping bad data.
func LoadItemsCSV(r io.Reader) ([]Item, error) {
	cr := csv.NewReader(r)
	// Variable width, so an older 28-column export and a newer one carrying
	// Price/SellPrice both load; the row count is checked per row below.
	cr.FieldsPerRecord = -1

	var items []Item
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++
		if len(record) < itemCSVRequiredColumns {
			return nil, fmt.Errorf("refdata: row %d has %d columns, need at least %d", rowNum, len(record), itemCSVRequiredColumns)
		}

		item, err := parseItemRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		items = append(items, item)
	}
	return items, nil
}

func parseItemRow(f []string) (Item, error) {
	var (
		it  Item
		err error
	)
	parseInt := func(s string) int {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return int(v)
	}
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}
	parseBool := func(s string) bool {
		return parseInt(s) != 0
	}

	it.ID = parseInt64(f[0])
	it.MaxStack = parseInt(f[1])
	it.ReqStr = parseInt(f[2])
	it.ReqInt = parseInt(f[3])
	it.ItemClass = parseInt(f[4])
	it.TwoHanded = parseBool(f[5])
	it.DurabilityMin = parseFloat(f[6])
	it.DurabilityMax = parseFloat(f[7])
	it.PhysDefenseMin = parseFloat(f[8])
	it.PhysDefenseMax = parseFloat(f[9])
	it.MagDefenseMin = parseFloat(f[10])
	it.MagDefenseMax = parseFloat(f[11])
	it.PhysAttackMin = parseFloat(f[12])
	it.PhysAttackMax = parseFloat(f[13])
	it.MagAttackMin = parseFloat(f[14])
	it.MagAttackMax = parseFloat(f[15])
	it.HitRateMin = parseFloat(f[16])
	it.HitRateMax = parseFloat(f[17])
	it.CriticalMin = parseFloat(f[18])
	it.CriticalMax = parseFloat(f[19])
	it.TypeID1 = parseInt(f[20])
	it.TypeID2 = parseInt(f[21])
	it.TypeID3 = parseInt(f[22])
	it.TypeID4 = parseInt(f[23])
	it.Country = parseInt(f[24])
	it.ReqGender = parseInt(f[25])
	it.ReqLevelType1 = parseInt(f[26])
	it.ReqLevel1 = parseInt(f[27])
	// Prices are optional (appended after the original 28 columns): an older
	// export lacks them and the shop falls back to its own formula.
	if len(f) > 28 {
		it.Price = parseInt64(f[28])
	}
	if len(f) > 29 {
		it.SellPrice = parseInt64(f[29])
	}
	// Restore amounts are optional in the same way.
	if len(f) > 30 {
		it.RestoreHP = parseInt(f[30])
	}
	if len(f) > 31 {
		it.RestoreHPPct = parseInt(f[31])
	}
	if len(f) > 32 {
		it.RestoreMP = parseInt(f[32])
	}
	if len(f) > 33 {
		it.RestoreMPPct = parseInt(f[33])
	}
	// A shield's block ratio, optional in the same way.
	if len(f) > 34 {
		it.BlockRatioMin = parseFloat(f[34])
	}
	if len(f) > 35 {
		it.BlockRatioMax = parseFloat(f[35])
	}
	// A weapon's reinforce percentages, optional in the same way. In the
	// table's own unit (tenths of a percent) -- see refdata.Item.
	if len(f) > 36 {
		it.ReinforcePhysMin = parseFloat(f[36])
	}
	if len(f) > 37 {
		it.ReinforcePhysMax = parseFloat(f[37])
	}
	if len(f) > 38 {
		it.ReinforceMagMin = parseFloat(f[38])
	}
	if len(f) > 39 {
		it.ReinforceMagMax = parseFloat(f[39])
	}
	// The item set, optional in the same way.
	if len(f) > 40 {
		it.SetID = parseInt(f[40])
	}
	// The capability flags, optional in the same way -- but with the default the
	// OTHER way round, which matters.
	//
	// These are permissions: a clear bit forbids. Go's zero value for a bool is
	// false, so an export made before these columns existed would load every
	// item as un-tradeable, un-sellable and un-droppable, and a server running
	// it would refuse every trade and every sale with no indication why. So an
	// absent column means UNRESTRICTED, set here rather than left to each
	// caller to remember. The SQL store defaults the same way (`DEFAULT TRUE`).
	//
	// The remaining sharp edge is a `refdata.Item` built by hand -- in a test,
	// say -- where the zero value still forbids everything. That is deliberate:
	// a literal is written by someone who can see the field, whereas an old
	// export is not.
	it.CanTrade, it.CanSell, it.CanDrop = true, true, true
	if len(f) > 41 {
		it.CanTrade = parseBool(f[41])
	}
	if len(f) > 42 {
		it.CanSell = parseBool(f[42])
	}
	if len(f) > 43 {
		it.CanDrop = parseBool(f[43])
	}
	// Requirement slots 2..4, optional in the same way. Zero -- not the
	// table's -1 -- is the absent value here, and equipment.RequirementsOf
	// treats both as "slot unused", so an older export simply carries the one
	// pair it has.
	if len(f) > 44 {
		it.ReqLevelType2 = parseInt(f[44])
	}
	if len(f) > 45 {
		it.ReqLevel2 = parseInt(f[45])
	}
	if len(f) > 46 {
		it.ReqLevelType3 = parseInt(f[46])
	}
	if len(f) > 47 {
		it.ReqLevel3 = parseInt(f[47])
	}
	if len(f) > 48 {
		it.ReqLevelType4 = parseInt(f[48])
	}
	if len(f) > 49 {
		it.ReqLevel4 = parseInt(f[49])
	}
	if len(f) > 50 {
		it.RepairCost = parseInt(f[50])
	}
	if len(f) > 51 {
		it.DecayTimeMs = parseInt(f[51])
	}
	// The weapon stats' high ends, optional in the same way (see Item).
	if len(f) > 59 {
		it.PhysAttackMinHi = parseFloat(f[52])
		it.PhysAttackMaxHi = parseFloat(f[53])
		it.MagAttackMinHi = parseFloat(f[54])
		it.MagAttackMaxHi = parseFloat(f[55])
		it.ReinforcePhysMinHi = parseFloat(f[56])
		it.ReinforcePhysMaxHi = parseFloat(f[57])
		it.ReinforceMagMinHi = parseFloat(f[58])
		it.ReinforceMagMaxHi = parseFloat(f[59])
	}
	if len(f) > 60 {
		it.Range = parseInt(f[60])
	}
	if len(f) > 63 {
		// The packed dwords are exported as plain decimals, the way itemdata
		// prints them; the top byte can be set, so they are read unsigned.
		// A dword column; anything that is not one (an older hand-edited
		// file, a "-1") reads as 0 -- no rate, no cooltime -- rather than
		// failing the whole import.
		parseU32 := func(s string) uint32 {
			v, e := strconv.ParseUint(s, 10, 32)
			if e != nil {
				return 0
			}
			return uint32(v)
		}
		it.ReinforceRate1 = parseU32(f[61])
		it.ReinforceRate2 = parseU32(f[62])
		it.ReinforceRate3 = parseU32(f[63])
		if len(f) > 65 {
			it.CooltimeGroup = parseU32(f[64])
			it.CooltimeMs = parseInt(f[65])
		}
		if len(f) > 67 {
			it.ParryRatioMin = parseFloat(f[66])
			it.ParryRatioMax = parseFloat(f[67])
		}
	}
	// CanUse (round 489), a permission like the three flags above and
	// defaulted the same way: an export older than column 68 must not load
	// every potion as unusable. Outside the block above, so the default holds
	// whatever the row's width.
	it.CanUse = true
	if len(f) > 68 {
		it.CanUse = parseBool(f[68])
	}
	// CanPick (round 493), the same kind of permission: an export older than
	// column 69 must not leave every drop lying on the ground unpickable.
	it.CanPick = true
	if len(f) > 69 {
		it.CanPick = parseBool(f[69])
	}
	// CodeName (round 497), a string: no parse to fail, and an export older
	// than column 70 leaves it empty (grounditem.OwnerOnlyPick treats an empty
	// name as "cannot tell", not as "not exempt").
	if len(f) > 70 {
		it.CodeName = strings.TrimSpace(f[70])
	}
	if len(f) > 71 {
		it.CompositeDesc = strings.TrimSpace(f[71])
	}
	if len(f) > 72 {
		it.KeepingFee = int64(parseInt(f[72]))
	}
	if len(f) > 78 {
		it.CashItem = parseBool(f[73])
		// Dwords, read unsigned and leniently, as ReinforceRate1..3 are.
		u32 := func(s string) uint32 {
			v, e := strconv.ParseUint(strings.TrimSpace(s), 10, 32)
			if e != nil {
				return 0
			}
			return uint32(v)
		}
		it.Param1 = u32(f[74])
		it.Param5 = u32(f[75])
		it.Desc1 = strings.TrimSpace(f[76])
		it.Desc4 = strings.TrimSpace(f[77])
		it.MaxMagicOptions = parseInt(f[78])
	}
	if len(f) > 86 {
		it.PlusIncPhysDef = parseFloat(f[79])
		it.PlusIncParry = parseFloat(f[80])
		it.PlusIncPhysAbsorb = parseFloat(f[81])
		it.PlusIncMagDef = parseFloat(f[82])
		it.PlusIncMagAbsorb = parseFloat(f[83])
		it.PlusIncPhysAtk = parseFloat(f[84])
		it.PlusIncMagAtk = parseFloat(f[85])
		it.PlusIncAttackRate = parseFloat(f[86])
	}
	if len(f) > 87 {
		it.Rarity = parseInt(f[87])
	}
	if len(f) > 88 {
		if v, e := strconv.ParseInt(strings.TrimSpace(f[88]), 10, 64); e == nil {
			it.Param6 = uint32(v)
		}
	}

	if err != nil {
		return Item{}, err
	}
	return it, nil
}

// skillCSVColumns is the expected column order for LoadSkillsCSV, matching
// the columns a player would export from their own restored reference-data
// database. See docs/protocol/refdata_schema.md and refdata.Skill's doc
// comment for what each real column means and why only these are kept.
var skillCSVColumns = []string{
	"ID", "GroupID", "Basic_Code", "Basic_Name", "Basic_Level", "Basic_ChainCode",
	"Basic_RecycleCost", "PreparingTime", "CastingTime", "ActionDuration",
	"ReuseDelay", "CoolTime", "FlyingSpeed", "Interruptable", "Overlap", "AutoAttackType",
	"Range", "Consume_HP", "Consume_MP", "ReqLearn_SP", "ReqLearn_Race", "UI_SkillName",
	"ReqCommon_Mastery1", "ReqCommon_MasteryLevel1",
	// Appended later (real skill damage, from the 'att' parameter): a strict
	// suffix, so an export made before it still loads.
	"AttackPercent", "DamageMin", "DamageMax",
	// Appended later (a skill's hit count, from its 'mc' parameter): a strict
	// suffix, so an export made before it still loads and every skill simply
	// strikes once.
	"HitCount",
	// Appended later still ('att' value[0], the damage-type mask): a strict
	// suffix, so an export made before it loads with 0, which
	// combat.AttackType reads as "unknown, treat as physical".
	"AttackType",
	// Appended later still (the two required-weapon bytes): a strict suffix,
	// so an export made before them loads with 0, which is invalid in the real
	// table and here means "unknown", permitting the cast.
	"ReqCastWeapon1", "ReqCastWeapon2",
	// Appended later ("reqi" run count; non-zero means the weapon gate does
	// not apply). A strict suffix: an older export leaves 0, which applies the
	// gate exactly as before this column existed.
	"ReqCastListCount",
	// Appended later (the list records themselves, and the ALL-of flag).
	"ReqCastList", "ReqCastAll",
	// Appended later (whether the engine resolves a blow for this skill at
	// all). A strict suffix, and NEGATIVE so an older export loads false,
	// meaning "it does resolve a blow" -- exactly what it meant before.
	"NoCombatParam",
	// Appended later (a resolved blow whose damage is zero; wider than the
	// column above and containing it). Also a strict suffix: false means "this
	// skill's damage is computed", which is what older exports meant.
	"ZeroDamage",
	// Appended later (a computed blow that is identically zero and therefore
	// always the floor of 1). Strict suffix; false is what older exports meant.
	"FloorBlow",
	// Appended later (the learn prerequisites, skilldata columns 40..45): a
	// strict suffix, so an older export loads with none and learning is gated
	// by the mastery level and SP alone, as it was before these existed.
	"ReqLearnSkill1", "ReqLearnSkillLevel1", "ReqLearnSkill2", "ReqLearnSkillLevel2",
	"ReqLearnSkill3", "ReqLearnSkillLevel3",
	// Appended later (round 503: the flat HP/MP a self-heal restores to its
	// caster, skillparam.SelfHealAmounts). A strict suffix: an older export
	// loads 0, which is no self-heal -- exactly what it meant before.
	"SelfHealHP", "SelfHealMP",
	// Appended later (round 504: the cooldown group, Action_Overlap's high
	// byte CRefSkill+0x8f). A strict suffix: an older export loads 0, which is
	// no group -- each skill keeps its own timer, as before.
	"CooldownGroup",
	// Appended later (round 607): the skill gate's motion-state refusals, a
	// bit mask (see Skill.SitGate). A strict suffix: an older export loads 0,
	// no refusal, which is what the read gate does for most skills.
	"SitGate",
	// Appended later (round 616): the buff and self-cast columns (see
	// Skill.ActionKind and what follows it). A strict suffix: an older export
	// loads zero for all of them -- an instant action with no buff, no ground
	// cast and no marker, which is what every skill was before.
	"ActionKind", "TargetRequired", "TargetLand", "TargetSelf", "TargetAlly", "TargetParty",
	"DuraMs", "Cbuf", "Nbuf", "Bbuf", "Lnks", "Tele0", "Tele1", "BuffParams",
	// Appended in round 616's review: the 'lks2' marker the recast rule tests.
	"Lks2",
	// Appended in round 622: what a Target_Required 1 heal restores to each
	// character it names (skillparam.TargetHealAmounts). A strict suffix: an
	// older export loads 0, which is no heal on a target.
	"TargetHealHP", "TargetHealMP",
	// Appended in round 636: the recast rule's columns (Skill.ActionOverlap
	// and what follows it). A strict suffix: an older export loads zero and
	// empty, no overlap bits -- the rule as it was before this round.
	"ActionOverlap", "Ovl2", "HasDttp", "Dttp0", "Dttp1", "Efr2", "Offensive",
	"Msch1", "Hide", "SkcEnd", "BasicGroup", "Activity", "Dtt",
	// Appended in round 636's review: FUN_0059dc80's columns (Skill.LnksGroup
	// and what follows it). A strict suffix: an older export loads zero, and
	// the 'lnks' check never refuses -- the rule as it was before.
	"LnksGroup", "LnksMax", "Efr3", "Qest", "Trap",
	// Appended in round 636's review follow-up: an 'efr' of kind 1, which
	// sends a buff down SkillAction_Buff's collector path (Skill.Efr1).
	"Efr1",
	// Appended in round 640: 'pw' value[0..3] (Skill.Pw0..Pw3), the protection
	// walls. A strict suffix: an older export loads 0, no wall.
	"Pw0", "Pw1", "Pw2", "Pw3",
	// Appended in the rounds 636-640 integration review: whether the row
	// carries 'tel2' / 'tel3' (Skill.Tel2, Skill.Tel3). A strict suffix: an
	// older export loads false, and only 'tele' is tested, as before.
	"Tel2", "Tel3",
	// Appended in round 654: AI_AttackChance, skilldata column 66
	// (Skill.AIAttackChance). A strict suffix: an older export loads -1,
	// unknown -- not 0, which is a real "never drawn".
	"AIAttackChance",
	// Appended in round 659: every status run of the Param block
	// (Skill.StatusParams, statuseffect.ParseRuns). A strict suffix: an older
	// export loads "", no status.
	"StatusParams",
	// Appended in round 785: the whole raw Param block (Skill.ParamWords) and
	// the second mastery slot (Skill.Mastery2 / MasteryLevel2). A strict
	// suffix: an older export loads no words and no second mastery.
	"Params", "Mastery2", "MasteryLevel2",
}

// skillCSVRequiredColumns is the prefix every skill export must carry; the
// three damage columns past it are optional, so an older export still loads.
// Rows shorter than this are rejected with a descriptive error rather than
// reaching the field parser, which would index past the end.
const skillCSVRequiredColumns = 24

// LoadSkillsCSV parses skill rows from r, a headerless CSV in
// skillCSVColumns's order (i.e. exactly what a plain `SELECT <those
// columns> FROM _RefSkill ORDER BY ID` export produces). Returns a
// descriptive error naming the row/column on any parse failure rather than
// silently skipping bad data.
func LoadSkillsCSV(r io.Reader) ([]Skill, error) {
	cr := csv.NewReader(r)
	// Variable width: the damage columns were appended, so an export made
	// before them is a strict prefix and still loads.
	cr.FieldsPerRecord = -1

	var skills []Skill
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		if len(record) < skillCSVRequiredColumns {
			return nil, fmt.Errorf("refdata: skill row %d has %d columns, need at least %d",
				rowNum, len(record), skillCSVRequiredColumns)
		}
		sk, err := parseSkillRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		skills = append(skills, sk)
	}
	return skills, nil
}

func parseSkillRow(f []string) (Skill, error) {
	var (
		sk  Skill
		err error
	)
	parseInt := func(s string) int {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return int(v)
	}
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}
	parseBool := func(s string) bool {
		return parseInt(s) != 0
	}

	sk.ID = parseInt64(f[0])
	sk.GroupID = parseInt64(f[1])
	sk.BasicCode = f[2]
	sk.BasicName = f[3]
	sk.BasicLevel = parseInt(f[4])
	sk.BasicChainCode = parseInt64(f[5])
	sk.BasicRecycleCost = parseInt(f[6])
	sk.PreparingTimeMs = parseInt(f[7])
	sk.CastingTimeMs = parseInt(f[8])
	sk.ActionDurationMs = parseInt(f[9])
	sk.ReuseDelayMs = parseInt(f[10])
	sk.CoolTimeMs = parseInt(f[11])
	sk.FlyingSpeed = parseFloat(f[12])
	sk.Interruptable = parseBool(f[13])
	sk.Overlap = parseBool(f[14])
	sk.AutoAttackType = parseInt(f[15])
	sk.Range = parseInt(f[16])
	sk.ConsumeHP = parseInt(f[17])
	sk.ConsumeMP = parseInt(f[18])
	sk.ReqLearnSP = parseInt(f[19])
	sk.ReqLearnRace = parseInt(f[20])
	sk.UISkillName = f[21]
	sk.Mastery1 = parseInt64(f[22])
	sk.MasteryLevel1 = parseInt(f[23])
	// The real damage from the skill's 'att' parameter, appended later.
	if len(f) > 24 {
		sk.AttackPercent = parseInt(f[24])
	}
	if len(f) > 25 {
		sk.DamageMin = parseInt(f[25])
	}
	if len(f) > 26 {
		sk.DamageMax = parseInt(f[26])
	}
	// The hit count from the skill's 'mc' parameter, appended later still. An
	// export predating it leaves 0, which HitsFor reads as one strike.
	if len(f) > 27 {
		sk.HitCount = parseInt(f[27])
	}
	// The damage-type mask from 'att' value[0], appended later still. An
	// export predating it leaves 0, which combat.AttackType(0).IsMagical()
	// reports false -- so an old export keeps today's physical-only behaviour
	// rather than silently changing it.
	if len(f) > 28 {
		sk.AttackType = parseInt(f[28])
	}
	// The two required-weapon bytes, appended later still.
	if len(f) > 29 {
		sk.ReqCastWeapon1 = parseInt(f[29])
	}
	if len(f) > 30 {
		sk.ReqCastWeapon2 = parseInt(f[30])
	}
	if len(f) > 31 {
		sk.ReqCastListCount = parseInt(f[31])
	}
	if len(f) > 32 {
		sk.ReqCastList = f[32]
	}
	if len(f) > 33 {
		sk.ReqCastAll = parseInt(f[33]) != 0
	}
	if len(f) > 34 {
		sk.NoCombatParam = parseInt(f[34]) != 0
	}
	if len(f) > 35 {
		sk.ZeroDamage = parseInt(f[35]) != 0
	}
	if len(f) > 36 {
		sk.FloorBlow = parseInt(f[36]) != 0
	}
	// The learn prerequisites (group id, level) x3, optional in the same way.
	if len(f) > 42 {
		sk.ReqLearnSkill1 = parseInt64(f[37])
		sk.ReqLearnSkillLevel1 = parseInt64(f[38])
		sk.ReqLearnSkill2 = parseInt64(f[39])
		sk.ReqLearnSkillLevel2 = parseInt64(f[40])
		sk.ReqLearnSkill3 = parseInt64(f[41])
		sk.ReqLearnSkillLevel3 = parseInt64(f[42])
	}
	// The self-heal amounts (round 503), optional in the same way: an export
	// predating them leaves 0, no heal.
	if len(f) > 43 {
		sk.SelfHealHP = parseInt(f[43])
	}
	if len(f) > 44 {
		sk.SelfHealMP = parseInt(f[44])
	}
	// The cooldown group (round 504), optional in the same way: an export
	// predating it leaves 0, no shared timer.
	if len(f) > 45 {
		sk.CooldownGroup = parseInt(f[45])
	}
	// The motion-state refusals (round 607), optional in the same way.
	if len(f) > 46 {
		sk.SitGate = parseInt(f[46])
	}
	// The buff and self-cast columns (round 616), optional in the same way:
	// each is read only when present, so an export cut anywhere in the run
	// still loads.
	intAt := func(i int, dst *int) {
		if len(f) > i {
			*dst = parseInt(f[i])
		}
	}
	boolAt := func(i int, dst *bool) {
		if len(f) > i {
			*dst = parseInt(f[i]) != 0
		}
	}
	intAt(47, &sk.ActionKind)
	boolAt(48, &sk.TargetRequired)
	boolAt(49, &sk.TargetLand)
	boolAt(50, &sk.TargetSelf)
	boolAt(51, &sk.TargetAlly)
	boolAt(52, &sk.TargetParty)
	intAt(53, &sk.DuraMs)
	boolAt(54, &sk.Cbuf)
	boolAt(55, &sk.Nbuf)
	boolAt(56, &sk.Bbuf)
	boolAt(57, &sk.Lnks)
	intAt(58, &sk.Tele0)
	intAt(59, &sk.Tele1)
	if len(f) > 60 {
		sk.BuffParams = strings.TrimSpace(f[60])
	}
	boolAt(61, &sk.Lks2)
	intAt(62, &sk.TargetHealHP)
	intAt(63, &sk.TargetHealMP)
	int64At := func(i int, dst *int64) {
		if len(f) > i {
			*dst = parseInt64(f[i])
		}
	}
	int64At(64, &sk.ActionOverlap)
	int64At(65, &sk.Ovl2)
	boolAt(66, &sk.HasDttp)
	int64At(67, &sk.Dttp0)
	int64At(68, &sk.Dttp1)
	boolAt(69, &sk.Efr2)
	boolAt(70, &sk.Offensive)
	boolAt(71, &sk.Msch1)
	boolAt(72, &sk.Hide)
	intAt(73, &sk.SkcEnd)
	if len(f) > 74 {
		sk.BasicGroup = strings.TrimSpace(f[74])
	}
	intAt(75, &sk.Activity)
	boolAt(76, &sk.Dtt)
	int64At(77, &sk.LnksGroup)
	int64At(78, &sk.LnksMax)
	boolAt(79, &sk.Efr3)
	boolAt(80, &sk.Qest)
	boolAt(81, &sk.Trap)
	boolAt(82, &sk.Efr1)
	int64At(83, &sk.Pw0)
	int64At(84, &sk.Pw1)
	int64At(85, &sk.Pw2)
	int64At(86, &sk.Pw3)
	boolAt(87, &sk.Tel2)
	boolAt(88, &sk.Tel3)
	sk.AIAttackChance = -1
	intAt(89, &sk.AIAttackChance)
	if len(f) > 90 {
		sk.StatusParams = strings.TrimSpace(f[90])
	}
	if len(f) > 91 {
		sk.ParamWords = ParseParamWords(f[91])
	}
	int64At(92, &sk.Mastery2)
	intAt(93, &sk.MasteryLevel2)

	if err != nil {
		return Skill{}, err
	}
	return sk, nil
}

// monsterDropCSVColumns is the expected column order for LoadMonsterDropsCSV.
// See docs/protocol/refdata_schema.md and refdata.MonsterDrop's doc comment.
var monsterDropCSVColumns = []string{
	"RefMonsterID", "RefItemGroupID", "Overlap", "DropAmountMin", "DropAmountMax", "DropRatio",
}

// LoadMonsterDropsCSV parses monster-drop rows from r, a headerless CSV in
// monsterDropCSVColumns's order (i.e. exactly what a plain `SELECT <those
// columns> FROM _RefMonster_AssignedItemRndDrop` export produces).
func LoadMonsterDropsCSV(r io.Reader) ([]MonsterDrop, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = len(monsterDropCSVColumns)

	var drops []MonsterDrop
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		d, err := parseMonsterDropRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		drops = append(drops, d)
	}
	return drops, nil
}

func parseMonsterDropRow(f []string) (MonsterDrop, error) {
	var (
		d   MonsterDrop
		err error
	)
	parseInt := func(s string) int {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return int(v)
	}
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}
	parseBool := func(s string) bool {
		return parseInt(s) != 0
	}

	d.MonsterID = parseInt64(f[0])
	d.ItemGroupID = parseInt64(f[1])
	d.Overlap = parseBool(f[2])
	d.DropAmountMin = parseInt(f[3])
	d.DropAmountMax = parseInt(f[4])
	d.DropRatio = parseFloat(f[5])

	if err != nil {
		return MonsterDrop{}, err
	}
	return d, nil
}

// dropGroupEntryCSVColumns is the expected column order for
// LoadDropGroupEntriesCSV. See docs/protocol/refdata_schema.md and
// refdata.DropGroupEntry's doc comment.
var dropGroupEntryCSVColumns = []string{
	"RefItemGroupID", "CodeName128", "RefItemID", "SelectRatio",
}

// LoadDropGroupEntriesCSV parses drop-group-entry rows from r, a headerless
// CSV in dropGroupEntryCSVColumns's order (i.e. exactly what a plain
// `SELECT <those columns> FROM _RefDropItemGroup` export produces).
func LoadDropGroupEntriesCSV(r io.Reader) ([]DropGroupEntry, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = len(dropGroupEntryCSVColumns)

	var entries []DropGroupEntry
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		e, err := parseDropGroupEntryRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		entries = append(entries, e)
	}
	return entries, nil
}

func parseDropGroupEntryRow(f []string) (DropGroupEntry, error) {
	var (
		e   DropGroupEntry
		err error
	)
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}

	e.GroupID = parseInt64(f[0])
	e.CodeName = f[1]
	e.ItemID = parseInt64(f[2])
	e.SelectRatio = parseFloat(f[3])

	if err != nil {
		return DropGroupEntry{}, err
	}
	return e, nil
}
