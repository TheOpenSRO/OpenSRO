package combat

import (
	"math"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// AttackType is a skill's damage-type mask -- `att` value[0] in the skill's
// Param block, the word this project read past for a year while consuming the
// three numbers behind it.
//
// It is RECOVERED, and it is the engine's own switch for which half of a blow
// exists. `Combat_ResolveDamage` (0058e5f0) computes two independent damages
// into one record and sums them:
//
//	rec[0x28] = Formula_MitigatePhysicalDamage(...)    // physical half
//	rec[0x24] = Formula_MitigateMagicalDamage(...)     // magical half
//	rec[0x20] = rec[0x28] + rec[0x24]
//
// and each formula opens by returning 0 unless its own bit is set in this mask:
//
//	if (skill[0x230] == 0 || ... || ((**(byte **)(skill + 0x230) & BIT) == 0))
//	    return 0;                      // BIT = 4 physical (0040e450)
//	                                   // BIT = 8 magical  (0040e830)
//
// Which bit is which is settled twice over, by two sources that were not asked
// to agree. The formulas' raw-damage builders read different ParamKeeper stats
// -- 0040db50 reads param `(max ? 1 : 0) + 13`, 0040dc10 reads `+ 15` -- and
// the recovered param registry names 13/14 "phys damage low/high" and 15/16
// "mag damage low/high" independently of any of this.
//
// THE SUM IS SAFE, which is the point of the whole recovery. This project left
// the magical half unimplemented for three ticks because summing two halves
// looked like it would double a blow. Measured over the real table it cannot:
// of 31,605 skilldata rows carrying `att`, the distribution of value[0] is
//
//	5  {1,4}  17,075 physical      10 {2,8}   6,971 magical
//	6  {2,4}   4,055 physical       9 {1,8}   2,528 magical
//	                                8 {8}       966 magical
//	0/1/2         10 neither
//
// and **zero rows set both bit 4 and bit 8**. The two halves are mutually
// exclusive by authoring, so the engine's sum always has exactly one live term.
// It is not an addition of two damages; it is how the engine writes "whichever
// half this skill deals".
//
// Bits 1 and 2 are an orthogonal axis. In the magical formula they choose which
// flat-absorption param the defender pays -- bit 1 selects param 130, bit 2
// param 131, through the getter at vtable +0x104. Nothing here models those
// params yet (both default to 0 in the registry, so they contribute nothing to
// an unbuffed character), so this type exposes the axis without acting on it.
//
// The same 4-bit vocabulary is shared by two other skill codes: `skc` (field
// 0x490) is AND-ed against this mask as a filter, and `pw` (field 0x2b4)
// inverts it -- a set bit there *removes* the corresponding half. See
// docs/protocol/skill_params.md.
type AttackType int

// The bits, as the two mitigation formulas test them.
const (
	// AttackPhysical gates Formula_MitigatePhysicalDamage (0040e450).
	AttackPhysical AttackType = 4
	// AttackMagical gates Formula_MitigateMagicalDamage (0040e830).
	AttackMagical AttackType = 8

	// AttackClassA and AttackClassB are the second axis, selecting the
	// defender's flat-absorption param (130 and 131 respectively). Named by
	// position rather than by meaning: what distinguishes the two classes was
	// not recovered, and inventing a name for it would be the kind of
	// plausible fiction this project has paid for before.
	//
	// MEASURED, AND THE NAMES STAY POSITIONAL ANYWAY (rounds 385-386).
	//
	// In authored content the axis lines up exactly with melee versus ranged.
	// Grouping all 30,064 real skill rows that carry `att`: class A names carry
	// SPEAR 3,763, SWORD 2,671, SHIELD 178 and **no BOW at all**; class B carries
	// every BOW row. Round 385 held this back as a naming correlation with 172
	// counterexamples -- class B rows named SWORD or SPEAR.
	//
	// Those 172 turned out to be the confirmation. They are all
	// SKILL_CH_SWORD_GEOMGI_*, real player skills, and the Range column
	// (skilldata col 21) separates them from the rest with ZERO OVERLAP:
	//
	//	sword/spear class A   n=1194   range min 0, max 0
	//	sword/spear class B   n= 172   range min 120, max 160
	//
	// Range was not used to form the groups -- the `att` mask was -- so this is a
	// clean separation on an independent column, not the naming argument round
	// 385 declined.
	//
	// **And it still does not license renaming these constants.** What the ENGINE
	// does with the bits is select the defender's flat-absorption param, 130 or
	// 131; it does not branch on them for anything range-related. Melee-versus-
	// ranged is a CONTENT-AUTHORING convention that happens to align with the
	// damage class, not the bits' meaning. Naming them AttackMelee/AttackRanged
	// would name a correlation and hide the mechanism, so they stay positional
	// and the measurement is recorded here instead.
	AttackClassA AttackType = 1
	AttackClassB AttackType = 2
)

// IsPhysical reports whether the blow has a physical half.
//
// An unknown mask (0) reads as physical. That is deliberate and is NOT a claim
// about the engine, which would deal no damage at all: 0 is what a skill record
// from an export predating the AttackType column carries, and treating it as
// physical keeps such an export behaving exactly as it did before the column
// existed. The ten real rows that genuinely carry 0, 1 or 2 are buff-shaped and
// deal no weapon damage anyway.
func (t AttackType) IsPhysical() bool {
	if t&(AttackPhysical|AttackMagical) == 0 {
		return true
	}
	return t&AttackPhysical != 0
}

// IsMagical reports whether the blow has a magical half. An unknown mask (0) is
// not magical, so an old export cannot silently reroute damage -- see
// IsPhysical.
func (t AttackType) IsMagical() bool { return t&AttackMagical != 0 }

// Known reports whether the mask actually names a damage half, distinguishing a
// real physical skill from an export that predates the column.
func (t AttackType) Known() bool { return t&(AttackPhysical|AttackMagical) != 0 }

// WeaponRange picks the ends of a weapon's damage roll for a blow of the given
// type, and is the ONE place that decision is made. It used to live inline in
// session.attackerDamage with a copy of itself in the test, which is how the
// test went on asserting the old rule after the rule changed.
//
// str and intel are the wielder's Strength and Intellect. WHICH STAT GOES WITH
// WHICH HALF IS RECOVERED, from the parameter graph GObjPC_InitStats (004e3200)
// declares edge by edge:
//
//	1 (str) -> 17 -> 13    phys low      34 -> 17 at slot 3
//	1 (str) -> 18 -> 14    phys high     36 -> 18 at slot 3
//	2 (int) -> 19 -> 15    mag low       35 -> 19 at slot 3
//	2 (int) -> 20 -> 16    mag high      37 -> 20 at slot 3
//
// Params 13-16 are named "phys/mag damage low/high" in the recovered registry,
// and the two mitigation formulas read exactly these pairs -- 0040db50 reads
// param `(max ? 1 : 0) + 13`, 0040dc10 reads `+ 15`. Param 2 carries the game's
// own tag `int`, so Intellect is named by the binary rather than by position.
//
// The magical half therefore scales with INTELLECT, not Strength. This code
// passed `str` into both halves until 2026-09-16 -- a real bug, and one that
// symmetry alone would not have justified fixing, which is why the edge list
// was read instead of assumed.
//
// Slot 3 is the percent scale (ParamKeeper_EvaluateParam divides it by 100), so
// each derived term is stat*reinforce/100 -- see ReinforceDamage.
//
// The INSTANCE decides where in each stat's (lo, hi) pair the weapon sits:
// Char_BuildAggregateStats (0x00495d60) interpolates the damage pairs by
// variance group 4 (physical) / 5 (magical) and the reinforce pairs by group
// 1 / 2 -- durability.WeaponPhysDamageGroup and its siblings, each cited to
// its `mov esi,N`. NoInstance (or an item exported before the hi columns
// existed, whose hi ends are zero) reads the lo end alone, which is what this
// function did for every weapon until 2026-09-19 (round 244).
// WeaponAttackRate is the weapon's own attack rate, its contribution to param
// 11 (hit rate): READ, Char_BuildAggregateStats interpolates the ref's
// +0x288/+0x28c (itemdata columns 113/114, refdata HitRateMin/Max) by variance
// group 3 (durability.WeaponAttackRateGroup, `mov esi,3` at 0x496376) into
// item+0x1d8, and Char_PublishCombatStats publishes +0x1d8 as param 11
// (0x497ace..0x497add). The instance rule is WeaponRange's: NoInstance, or a
// row without its hi end, reads the lo end. The per-plus increment (column
// 115) is not added: OpenSRO instances carry no plus level.
func WeaponAttackRate(item *refdata.Item, inst Instance) float64 {
	if item == nil {
		return 0
	}
	lo, hi := item.HitRateMin, item.HitRateMax
	if !inst.Tracked || hi <= lo {
		return lo
	}
	return durability.WhiteStat(lo, hi, inst.Variance, durability.WeaponAttackRateGroup)
}

func WeaponRange(item *refdata.Item, inst Instance, str, intel int, atk AttackType) (min, max int) {
	if item == nil {
		return 0, 0
	}
	stat := func(lo, hi float64, group int) float64 {
		if !inst.Tracked || hi <= lo {
			return lo
		}
		return durability.WhiteStat(lo, hi, inst.Variance, group)
	}
	physMin := stat(item.PhysAttackMin, item.PhysAttackMinHi, durability.WeaponPhysDamageGroup)
	physMax := stat(item.PhysAttackMax, item.PhysAttackMaxHi, durability.WeaponPhysDamageGroup)
	magMin := stat(item.MagAttackMin, item.MagAttackMinHi, durability.WeaponMagDamageGroup)
	magMax := stat(item.MagAttackMax, item.MagAttackMaxHi, durability.WeaponMagDamageGroup)
	rPhysMin := stat(item.ReinforcePhysMin, item.ReinforcePhysMinHi, durability.WeaponPhysReinforceGroup)
	rPhysMax := stat(item.ReinforcePhysMax, item.ReinforcePhysMaxHi, durability.WeaponPhysReinforceGroup)
	rMagMin := stat(item.ReinforceMagMin, item.ReinforceMagMinHi, durability.WeaponMagReinforceGroup)
	rMagMax := stat(item.ReinforceMagMax, item.ReinforceMagMaxHi, durability.WeaponMagReinforceGroup)

	min = int(math.Round(physMin)) + ReinforceDamage(str, rPhysMin)
	max = int(math.Round(physMax)) + ReinforceDamage(str, rPhysMax)

	switch {
	// A MAGICAL blow reads the magical columns and nothing else, even when the
	// weapon has none -- then the weapon contributes zero.
	//
	// THIS CORRECTS THE PREVIOUS TICK, which made the reroute conditional on
	// `item.MagAttackMax > 0` and gave two reasons for holding back. Both were
	// measured afterwards and both were wrong.
	//
	// The first was "the engine refuses the cast first, via ReqCast_Weapon".
	// It does have that gate -- FUN_0058d480 compares `weaponTID >> 11` against
	// the skill's two required-weapon bytes and returns error 0x300d on a
	// mismatch -- but **4,144 of the 10,465 magical attack skills require no
	// weapon at all** (both bytes 0xff), including every CH elemental nuke. So
	// for 40% of exactly the skills in question the engine does not refuse, and
	// the justification did not hold.
	//
	// The second was "it would drop a caster holding a sword to 1 damage". Also
	// wrong: the skill's own flat `att` damage is added to the bound inside the
	// builder regardless of the weapon (0040dc10 reads the descriptor's +0xc),
	// and for those 4,144 skills the median flat is 2,068 against a median
	// percent of 263. The weapon contribution is the small term, not the whole
	// blow. OpenSRO adds that flat separately as damageBonus, so the shape
	// already matches.
	//
	// What IS true, and is what makes the zero correct: the magical half draws
	// params 15/16, Char_PublishCombatStats (00497830) writes params 34-37
	// UNCONDITIONALLY (the only branch substitutes 0.0, it never skips the
	// write), so a physical-only weapon writes param 35 = 0 rather than leaving
	// it at the registry default of 100, and slot 3 scales Intellect to
	// nothing. Measured: all 574 physical-only items carry no magical
	// reinforce, no exceptions.
	case atk.IsMagical():
		min = int(math.Round(magMin)) + ReinforceDamage(intel, rMagMin)
		max = int(math.Round(magMax)) + ReinforceDamage(intel, rMagMax)

	// A blow with no known mask on a weapon that has no physical damage: 448 of
	// 1,582 real attack-carrying items are magical-only, and reading only the
	// physical columns would give them 0 and land every swing on the floor of 1.
	//
	// This is a STAND-IN, not the engine's rule. The engine has no maskless
	// blow: a plain swing runs the weapon's own basic-attack skill, and that
	// skill carries the matching mask (SKILL_CH_SWORD_BASE_01 is physical,
	// SKILL_EU_STAFF_BASE_01 magical).
	//
	// Since round 505 OpenSRO's plain swing does run that skill
	// (session.plainSwingOf) and passes its mask, so with a real base row a
	// staff's swing arrives magical and takes the case above. This case is
	// KEPT for the swings that still have no mask to pass: no base row (a
	// store that cannot look skills up, or a weapon type the default-attack
	// table does not list) or a skill export predating the AttackType
	// column. plainSwingOf falls back to AttackPhysical for those, and a
	// magical-only weapon would otherwise land every such swing on the floor.
	case max <= 0 && item.MagAttackMax > 0:
		min = int(math.Round(magMin)) + ReinforceDamage(intel, rMagMin)
		max = int(math.Round(magMax)) + ReinforceDamage(intel, rMagMax)
	}
	return min, max
}

// Instance is the part of a worn weapon WeaponRange needs: its variance and
// whether it has one. A weapon without an instance (NoInstance -- a row from
// before durability existed, or a store with no reference data to roll from)
// reads every stat at its lo end.
type Instance struct {
	Variance uint64
	Tracked  bool
}

// NoInstance reads every weapon stat at its lo end.
var NoInstance = Instance{}

// Weapon type codes, the values a skill's ReqCastWeapon bytes and an item's
// TypeID4 both carry. RECOVERED, and confirmed independently by three sources
// that were not asked to agree:
//
//   - itemdata: every weapon row is (TypeID1,2,3) = (3,1,6), and under that
//     category each ITEM_<race>_<type>_* family lands on exactly one TypeID4 --
//     112 rows apiece, no family split across two codes.
//   - skilldata: grouping all 36,389 rows by the family in their Basic_Code puts
//     all 24 families on the code their own name says (SKILL_EU_AXE -> 9,
//     SKILL_CH_SPEAR -> 4 and 5, ...).
//   - the engine: FUN_0058d480 compares `equippedTID >> 11` against the skill's
//     two bytes, and TID4 occupies bits 11-15 (the masks 0x780 for TID3 and
//     0xf800 for TID4 appear all over the binary's item tests).
//
// The names are itemdata's own, not inferred from the skill families that
// require them -- a distinction that matters, because reading them off the skill
// names got three wrong: code 10 is DARKSTAFF (not "wand"), 11 is TSTAFF (not
// "staff"), and 15 is STAFF (not "cleric rod"). The skill family that requires a
// code is not the item's name for it.
const (
	WeaponBareHand    = 1 // SKILL_PUNCH_01 requires exactly this
	WeaponCHSword     = 2
	WeaponCHBlade     = 3
	WeaponCHSpear     = 4
	WeaponCHTBlade    = 5
	WeaponCHBow       = 6
	WeaponEUSword     = 7
	WeaponEUTSword    = 8
	WeaponEUAxe       = 9
	WeaponEUDarkStaff = 10
	WeaponEUTStaff    = 11
	WeaponEUCrossbow  = 12
	WeaponEUDagger    = 13
	WeaponEUHarp      = 14
	WeaponEUStaff     = 15
	WeaponFortress    = 16 // ITEM_FORT_FORTRESS_HAMMER / _AXE

	// WeaponTypeIDCategory is TypeID3 for the weapon category. An item with a
	// different TypeID3 is not a weapon and cannot satisfy a requirement.
	WeaponTypeIDCategory = 6

	// MaxTID4Code bounds the vocabulary: TypeID4 is 5 bits (the 0xf800 field),
	// so 31 is the largest value one can hold. equipment.MaxTID4 states the
	// same bound from ReferenceData.cpp's own assert.
	MaxTID4Code = 31

	// ReqWeaponUnused is the value in a required-weapon slot that carries no
	// requirement. Both slots unused means the skill may be cast with anything.
	ReqWeaponUnused = 0xff
)

// SkillAllowsWeapon reports whether a skill may be cast with the given equipped
// weapon, reproducing FUN_0058d480:
//
//	if (skill[199] == -1 && skill[200] == -1) return 0;   // no requirement
//	code = equippedTID >> 11;                             // == TypeID4
//	if (code == 0) code = 1;                              // bare hand
//	for (p = skill+199; p - skill < 201; p++)
//	    if (*p != 0xff && code == *p) goto ok;
//	return 0x300d;                                         // wrong weapon
//
// weaponTypeID3/4 are the equipped weapon's type fields; pass 0,0 for an empty
// hand, which the engine's own `code == 0` branch turns into WeaponBareHand --
// and SKILL_PUNCH_01, the unarmed attack, requires exactly that code, which is
// the data confirming the branch.
//
// UNKNOWN INPUTS PERMIT THE CAST, and that is a compatibility rule rather than a
// claim about the engine. Zero is *invalid* in the real table -- the row loader
// SkillGlobal::FUN_005893e0 refuses a row whose bytes are zero with "ReqWeapon
// Error [RefSkill ID: %d]" -- so a zero here can only mean an export predating
// the columns. Refusing on it would lock every skill on every existing
// deployment.
func SkillAllowsWeapon(req1, req2, weaponTypeID3, weaponTypeID4 int) bool {
	if req1 == 0 && req2 == 0 {
		return true // export predates the columns; 0 is not a real requirement
	}
	if req1 == ReqWeaponUnused && req2 == ReqWeaponUnused {
		return true // no requirement -- 4,144 magical attack skills are here
	}
	code := weaponTypeID4
	// Only the weapon category carries a meaningful TypeID4. Anything else --
	// an empty hand, or a non-weapon somehow in the slot -- reads as bare hand,
	// which is the engine's `code == 0` branch.
	if weaponTypeID3 != WeaponTypeIDCategory || code == 0 {
		code = WeaponBareHand
	}
	return (req1 != ReqWeaponUnused && req1 == code) ||
		(req2 != ReqWeaponUnused && req2 == code)
}

// CastRequirement is one entry of a skill's cast-requirement list -- the
// five-slot list at CRefSkill+0x3a0 that the skill's `reqi` parameter fills
// (`mov [esi+edx*4+0x3a0],eax` at 00588f79). Each entry is a two-word record.
//
// Kind is a TypeID3 CATEGORY and Value a TypeID4 TYPE within it, with 0 meaning
// "any". That reading is the engine's own: FUN_0058d480 compares Kind against
// `(itemTID >> 7) & 0xf`, which is the TypeID3 field, and Value against
// `itemTID >> 11`, which is TypeID4.
//
// Measured over 1,552 real records, and the kinds land exactly on the TypeID3
// vocabulary refdata.Item already documents:
//
//	kind  6  weapon        1,216 records, values 2-15 (the weapon TypeID4 set)
//	kind  4  shield          179 records, values 1-2
//	kind 10  EU light armour  94 records, value 0 (any)
//	kind  9  EU robe          34 records, value 0 (any)
//	kind 14  NOT equipment    23 records -- an item-mall flag, see Satisfied
//
// The switch also handles kinds 1, 2, 3 and 11 (China's garment/protector/
// armour and Europe's heavy), which no shipped skill uses.
type CastRequirement struct {
	Kind  int // a TypeID3 category
	Value int // a TypeID4 type, or 0 for any
}

// EquippedType is one worn item's type fields, as the requirement check needs
// them.
type EquippedType struct{ TypeID3, TypeID4 int }

// Satisfied reports whether worn equipment meets this requirement.
//
// KIND 14 IS ALWAYS SATISFIED, and that is a disclosed gap rather than a
// reading of the engine. Its case tests a character flag through vtable +0x584
// and FUN_00498610, not equipment at all; 23 records carry it, all on item-mall
// and event skills (SKILL_MALL_NASRUN, SKILL_EVENT_NASRUN). Modelling it would
// need the flag, which is not recovered -- so it passes rather than refusing a
// cast on a condition this project cannot evaluate.
//
// A BROKEN ITEM SATISFIES NOTHING, and the caller models it by leaving the item
// out of worn (session.equippedTypes, round 486). Skill_CheckCastRequirement
// (0x0058d480) reads each slot's type through a getter -- Equip_GetWeaponTID
// 0x004ead40, Equip_GetShieldTID 0x004ead80, Equip_GetArmourPartTID
// 0x004eadc0 -- and each writes TID 0 when the item's +0x190 broken flag is set
// (4ead63 / 4eada3 / 4eadf5 `cmp [..+0x190],0 ; jne`), so a broken item is an
// empty slot to this check and the refusal is 0x300d, not 0x300f. The vtable
// calls after each match (0x5d0, 0x63c, 0x640) read the same flag and are
// redundant for every entry with a TypeID4.
//
// NOT MODELLED, disclosed, and not checked against any real skill: (1) a
// weapon or shield entry with Value 0 compares `TID >> 11 == 0`, which in the
// engine matches an EMPTY slot, not any item -- no shipped record has one;
// (2) an armour entry with Value 0 scans parts 1..6 in order (58d5c0) and
// stops at the first part not of the Kind, so it answers for the first part
// rather than for any part; (3) an ALL-of list with all five entries filled
// and matching falls out of the loop with the match flag cleared and returns
// 0x300d (58d681 -> 58d695); (4) an armour entry WITH a Value reads the part
// at index Value (58d571 passes it in eax to 0x004eadc0) and compares only
// `TID >> 11`, never the Kind -- no shipped record has one either (the armour
// kinds above carry Value 0 only).
func (r CastRequirement) Satisfied(worn []EquippedType) bool {
	if r.Kind == CastReqFlagKind {
		return true
	}
	for _, w := range worn {
		if w.TypeID3 == r.Kind && (r.Value == 0 || w.TypeID4 == r.Value) {
			return true
		}
	}
	return false
}

// CastReqFlagKind is the one requirement kind that is not about equipment.
const CastReqFlagKind = 14

// SkillAllowsEquipment reports whether worn equipment satisfies a skill's
// cast-requirement list.
//
// requireAll is the skill's `reqn` parameter (field 0x3b4). It changes the list
// from ANY-of to ALL-of, which is the engine's own branch:
//
//	if (skill[0x3b4] != 0) {          // reqn present
//	    if (!matched) goto fail;      // every entry must match
//	    matched = false; matches++;
//	}
//	...
//	while (i < 5);
//	if (!matched) goto fail;          // no reqn: one match is enough
//
// Measured: 966 skills use the ANY form and 128 the ALL form.
//
// An EMPTY LIST allows the cast. That is not this function's decision to make:
// the engine only reaches this code when the list is non-empty, and the caller
// applies ReqCastWeapon instead when it is empty. See SkillAllowsWeapon.
func SkillAllowsEquipment(reqs []CastRequirement, requireAll bool, worn []EquippedType) bool {
	if len(reqs) == 0 {
		return true
	}
	for _, r := range reqs {
		ok := r.Satisfied(worn)
		if requireAll && !ok {
			return false
		}
		if !requireAll && ok {
			return true
		}
	}
	return requireAll
}

// ParseCastRequirements decodes the packed `kind:value;kind:value` form the
// refdata export carries. A malformed entry is skipped rather than failing the
// parse, so a bad row costs one requirement and not the whole skill.
func ParseCastRequirements(packed string) []CastRequirement {
	if packed == "" {
		return nil
	}
	var out []CastRequirement
	for _, part := range strings.Split(packed, ";") {
		k, v, ok := strings.Cut(part, ":")
		if !ok {
			continue
		}
		kind, err1 := strconv.Atoi(strings.TrimSpace(k))
		val, err2 := strconv.Atoi(strings.TrimSpace(v))
		if err1 != nil || err2 != nil {
			continue
		}
		out = append(out, CastRequirement{Kind: kind, Value: val})
	}
	return out
}

// CanPaySkillHealth reports whether a character can pay a skill's health cost.
//
// RECOVERED from the skill-use precondition check at 0058e279 in
// SR_GameServer.exe (the SERVER binary: /var/tmp/srv.asm on the RE box, where
// each of these is an instruction start; the same addresses in the client's
// image are unrelated bytes, which a round-551 review lookup in
// sro_client.asm mistook for a bad citation), read in assembly because the
// comparison is the whole content; re-read 2026-09-24:
//
//	58e279  cmp DWORD PTR [esp+0x10],0x0   ; the cost
//	58e27e  jle 58e29d                     ; a cost <= 0 is not checked at all
//	58e280  mov edx,[ebx]
//	58e282  mov eax,[edx+0x108]            ; vtable slot 66 = IGObj::GetCurHP
//	58e28a  call eax
//	58e28c  cmp eax,[esp+0x10]             ; current HP vs cost
//	58e290  jge 58e29d                     ; passes on EQUAL
//	58e292  mov ax,0x3013                  ; else 0x3013, which the client names
//	                                       ; UIIT_SKILL_USE_FAIL_NOTENOUGHHP
//
// So the bar is `currentHP >= cost`, not "must survive": a cast that spends the
// caster's last point is allowed through. The MP check directly below it is the
// same shape against slot 67 (GetCurMP; `mov eax,[edx+0x10c]` at 58e2a3, `cmp
// eax,edi; jge` at 58e2ad/58e2af, `mov ax,0x3004` at 58e2b1), which is how the
// ordering here is known -- the engine tests health first.
//
// WHAT HAPPENS AT EXACTLY ZERO IS NOT RECOVERED. The comparison permitting
// `currentHP == cost` is read; whether the engine then treats the caster as
// dead is not (the cost is taken later, by EngageSkill's slot 0x308, and no
// OnDeath call was traced from there). OpenSRO's rule, disclosed: the caster
// is left ALIVE at 0 -- life state 1, no penalty, no respawn -- and the next
// monster or duel blow whose damage lands on her is her death
// (session/monsterstrike.go's killLock, round 551). Round 550's arbiter, the
// store's transition flag, made her unkillable instead; round 551 closed it.
// It is reachable only when HP equals the cost exactly.
func CanPaySkillHealth(currentHP, cost int) bool {
	if cost <= 0 {
		return true
	}
	return currentHP >= cost
}
