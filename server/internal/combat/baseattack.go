package combat

// The plain swing is a SKILL in the real game: every weapon type has one
// `_BASE_01` row in skilldata whose ReqCast_Weapon1 names the type (memory
// note "skilldata columns"; the bytes are itemdata TypeID4 values). The server
// runs it through the same action machine as any cast (round 247), and its
// ActionDuration == ReuseDelay is the attack cadence -- read from the retail
// table 2026-09-19 (round 255):
//
//	SKILL_PUNCH_01              (1)  1500 ms      SKILL_EU_TSWORD_BASE_01    (8)  2000 ms
//	SKILL_CH_SWORD_BASE_01    (2,3)  1200 ms      SKILL_EU_AXE_BASE_01       (9)  1500 ms
//	SKILL_CH_SPEAR_BASE_01    (4,5)  1166 ms      SKILL_EU_WAND_WARLOCK_BASE (10) 1666 ms
//	SKILL_CH_BOW_BASE_01        (6)   840 ms      SKILL_EU_STAFF_BASE_01     (11) 1666 ms
//	SKILL_EU_SWORD_BASE_01      (7)  1333 ms      SKILL_EU_CROSSBOW_BASE_01  (12) 1333 ms
//	SKILL_EU_DAGGER_BASE_01    (13)  1000 ms      SKILL_EU_HARP_BASE_01      (14) 2000 ms
//	SKILL_EU_WAND_CLERIC_BASE  (15)  1666 ms
//
// Only the IDS are kept here (structural: which row is a weapon type's base
// attack); the delay itself is read from the imported skill table at run time
// so it stays the operator's data, not a constant.

// BaseAttackSkillFor is the skilldata id of the plain attack a weapon type
// (itemdata TypeID4; 1 = bare hand) performs, or 0 for a type with none.
func BaseAttackSkillFor(typeID4 int) int64 {
	switch typeID4 {
	case 1:
		return 1 // SKILL_PUNCH_01
	case 2, 3:
		return 2 // SKILL_CH_SWORD_BASE_01 (sword and blade)
	case 4, 5:
		return 40 // SKILL_CH_SPEAR_BASE_01 (spear and glaive)
	case 6:
		return 70 // SKILL_CH_BOW_BASE_01
	case 7:
		return 8419 // SKILL_EU_SWORD_BASE_01
	case 8:
		return 8420 // SKILL_EU_TSWORD_BASE_01
	case 9:
		return 8421 // SKILL_EU_AXE_BASE_01
	case 10:
		return 10625 // SKILL_EU_WAND_WARLOCK_BASE_01 (dark staff)
	case 11:
		return 9944 // SKILL_EU_STAFF_BASE_01 (two-handed staff)
	case 12:
		return 9354 // SKILL_EU_CROSSBOW_BASE_01
	case 13:
		return 9355 // SKILL_EU_DAGGER_BASE_01
	case 14:
		return 11162 // SKILL_EU_HARP_BASE_01
	case 15:
		return 11526 // SKILL_EU_WAND_CLERIC_BASE_01 (cleric rod)
	}
	return 0
}

// BareHandTypeID4 is the weapon type the engine reports for an empty hand
// (ReqCast_Weapon byte 1 -- SKILL_PUNCH_01 requires it).
const BareHandTypeID4 = 1
