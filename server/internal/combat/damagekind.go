package combat

// DamageKind is the byte Combat_ResolveDamage (0x0058e5f0) switches on to decide
// HOW a blow's damage is produced. It lives at +5 of the per-hit record, is left
// 0 by the allocator, and is set to 1..4 only by the selector below -- so kind 0
// is the default and everything this package had recovered before 2026-09-18
// (mitigation, the floor, the skill percentage) is kind 0 and only kind 0.
//
// THE SELECTOR, read off the function and named with the game's own data:
//
//	if (attacker->IsPC()) {                                   // IGObj slot 7
//	    if (attacker[0x308] ... its skill's 'msch' value[0] == 1)   kind = 1;
//	    else if (target->IsFortressStructure() == 1 ||              // CGObj slot 248
//	             target->IsFortressFlag()      == 1)        kind = 3;   // CGObj slot 244
//	    else if ((Equip_GetWeaponTID() & 0xf800) == 0x8000)   kind = 4;
//	    else if (target->IsMonster() &&                             // IGObj slot 10
//	             EventMobList_Contains(target id))            kind = 2;
//	}
//
// A blow from anything that is not a PC is always kind 0.
//
// HOW EACH CONDITION WAS GROUNDED -- the binary gives a pattern, real data names
// it, and neither was taken on its own:
//
//   - Slots 244 and 248 each have ONE implementation shared by all 30 object
//     classes, and both are TID bit tests. Against real characterdata, TypeID
//     (1,2,4,2) is exactly 5 rows, every one STRUCTURE_*_FLAG, and TypeID
//     (1,2,5,*) is exactly 71 rows, every one STRUCTURE_* (fort stones, towers,
//     gates, headquarters, barricades). Zero exceptions either way.
//   - `TID >> 11` is TypeID4 -- already proven by the weapon gate -- so
//     `& 0xf800 == 0x8000` is TypeID4 == 16, which docs/protocol/skill_params.md
//     had already recorded as the fortress weapon (SKILL_*_FORTRESSWEAPON).
//     Equip_GetWeaponTID reads storage slot 6, which EQUIP_SLOTS.md has as the
//     weapon slot.
//   - The event list has exactly one record builder in the binary, and it looks
//     up the literal code name "MOB_EV_WINTER_SNOWMAN". Real characterdata has
//     that monster: level 1, MaxHP 11.
//   - 'msch' is skill+0x4a4 (skillparam.Field). 25 real skills carry it and
//     exactly ONE has value[0] == 1: SKILL_ETC_TRANS_MONSTER_01, the
//     transform-into-a-monster skill.
type DamageKind int

const (
	// KindOrdinary: the computed blow -- mitigation, skill percentage, floor.
	KindOrdinary DamageKind = 0
	// KindTransformed: the attacker is under the monster transform. Damage is
	// Formula_RollLevelDamage, a roll built from the two levels and no weapon,
	// which is what a player who has become a monster would need. NOT MODELLED:
	// OpenSRO has no transform, and what attacker[0x308] is has not been read
	// beyond "an object whose skill record carries 'msch'".
	KindTransformed DamageKind = 1
	// KindEventMob: the target is on the hard-coded event list. Damage is the
	// list's own 16-bit value, ignoring every formula. In this build that is
	// the winter snowman and the value is 1 -- eleven blows from anyone kill
	// it, whatever they are holding.
	KindEventMob DamageKind = 2
	// KindStructure: the target is a fortress structure or flag. Damage is
	// FUN_0040f990 (736 bytes), NOT READ, so this kind is identified but not
	// implemented.
	KindStructure DamageKind = 3
	// KindFortressWeapon: the attacker wields a fortress weapon against
	// something that is not a structure. Damage is exactly 1.
	KindFortressWeapon DamageKind = 4
)

// FortressWeaponTypeID4 is the TypeID4 of a fortress weapon: the engine tests
// `(weaponTID & 0xf800) == 0x8000`, and TID >> 11 is TypeID4.
const FortressWeaponTypeID4 = 16

// EventMobFixedDamage is the hard-coded event list: code name to the damage
// every blow deals. One entry in this build, written by
// EventMobList_BuildWinterSnowman (0x00615b20) -- the code name is a string
// literal in that function and the 1 is the value it stores at record+0x1c.
var EventMobFixedDamage = map[string]int{
	"MOB_EV_WINTER_SNOWMAN": 1,
}

// IsFortressFlag is CGObj slot 244: TypeID (1,2,4,2).
func IsFortressFlag(t1, t2, t3, t4 int) bool {
	return t1 == 1 && t2 == 2 && t3 == 4 && t4 == 2
}

// IsFortressStructure is CGObj slot 248: TypeID (1,2,5,*), TypeID4 left free.
func IsFortressStructure(t1, t2, t3 int) bool {
	return t1 == 1 && t2 == 2 && t3 == 5
}

// KindInput is what the selector reads.
type KindInput struct {
	AttackerIsPC bool
	// AttackerTransformed: the attacker's attached object carries 'msch' with
	// value[0] == 1. Always false in OpenSRO today.
	AttackerTransformed bool
	// The target's TypeID1..4. A zero TypeID1 means unknown, and an unknown
	// target is not a structure.
	TargetTypeID1, TargetTypeID2, TargetTypeID3, TargetTypeID4 int
	// TargetCodeName is the target's characterdata code name.
	TargetCodeName string
	// WeaponTypeID4 is the TypeID4 of the item in the attacker's weapon slot, 0
	// when there is none or it is unknown.
	WeaponTypeID4 int
}

// SelectDamageKind reproduces the engine's selector, in the engine's order.
// The order is part of the rule: a transformed attacker is kind 1 even against
// a structure, and a fortress weapon swung at a structure is kind 3, not 4.
func SelectDamageKind(in KindInput) DamageKind {
	if !in.AttackerIsPC {
		return KindOrdinary
	}
	if in.AttackerTransformed {
		return KindTransformed
	}
	if IsFortressStructure(in.TargetTypeID1, in.TargetTypeID2, in.TargetTypeID3) ||
		IsFortressFlag(in.TargetTypeID1, in.TargetTypeID2, in.TargetTypeID3, in.TargetTypeID4) {
		return KindStructure
	}
	if in.WeaponTypeID4 == FortressWeaponTypeID4 {
		return KindFortressWeapon
	}
	if _, listed := EventMobFixedDamage[in.TargetCodeName]; listed {
		return KindEventMob
	}
	return KindOrdinary
}

// FixedDamagePerHit returns the damage each hit deals for the kinds whose
// damage is a constant, and ok=false for the kinds that compute it (ordinary)
// or that OpenSRO does not model (transformed, structure).
//
// It is per HIT: the kind switch sits inside the engine's per-hit loop, so a
// three-hit skill swung with a fortress weapon deals 1 three times.
func FixedDamagePerHit(kind DamageKind, targetCodeName string) (damage int, ok bool) {
	switch kind {
	case KindFortressWeapon:
		return 1, true
	case KindEventMob:
		d, listed := EventMobFixedDamage[targetCodeName]
		return d, listed
	}
	return 0, false
}
