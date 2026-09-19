package combat

import "math"

// The attack-distance rule, read off the server's plain-attack action tick
// (CGCharAutoCommandActor::Tick_Attack, 0x004ad8e0, phases 0 and 3 -- round
// 247 called it ActionTick_UseSkill; round 256 found the skill tick is its
// sibling 0x004ae590, which computes the same band with the skill's own
// Range) on 2026-09-19. Neither client nor server refuses a blow for distance
// -- the server WALKS the attacker into reach and fires when it gets there:
//
//	base   = casterBC + targetBC                      ; both IGObj slot 344, the
//	                                                   ; ref row's BCRadius (col 50)
//	range  = skill.Range (CRefSkill+0x92)             ; 0 for every basic attack
//	       or round(param 33) when that is 0          ; = the weapon's Range column
//	                                                   ; (itemdata 94; sword 6, spear 18,
//	                                                   ; bow 180, dagger 3), published
//	                                                   ; by Char_PublishCombatStats from
//	                                                   ; the item ref's +0x224
//	range += two conditional bonuses                   ; skill params CBRA (+0x50c) and WIRU
//	                                                   ; (+0x4e8): value[0] names a state in
//	                                                   ; the caster's active-effect map
//	                                                   ; (pc+0xa30), whose +4 is added
//	range *= 1 - param183/100                          ; the Myopia (short-sight) state's
//	                                                   ; percent (status_effects.md); 0 here
//	reach  = base + range                              ; action+0x18
//	stop   = base + f(range)                           ; action+0x14, where the
//	                                                   ; approach walks to
//	f(r)   = r          for r <= 4
//	       = r - 2      for 4 < r < 10
//	       = 0.7 * r    for r > 10
//	       = 0          at exactly 10 (the engine's own hole: the r >= 10 branch
//	                                   only acts on r > 10)
//
// Phase 1 then tests Action_IsTargetWithinReach (0x004ad4a0):
// int(distance) <= int(reach) + 2, the distance being the region-aware
// separation of the two objects (the same FUN_00430ba0 every other distance
// here uses) -- and when it fails, GObjPC::MoveTowardObject(target,
// round(stop)) (0x004b0350) starts the walk. The comparison takes the table's
// tenths-of-a-metre numbers as world units with no conversion, which is the
// use-site round 233 was waiting for: 1 world unit = 0.1 m.
//
// Constants: 4.0 at 0xb45dc0, 2.0 at 0xb46010 (the r <= 2 test, unreachable
// inside r > 4) and 0xb45f30 (the -2), 10.0 at 0xb45b44, 0.7 at 0xb45ef8.
const (
	// ReachSlack is the +2 units Action_IsTargetWithinReach allows.
	ReachSlack = 2
	// ReachShortBand is the range at or below which the walk stops exactly
	// at reach.
	ReachShortBand = 4.0
	// ReachLongBand is the range above which the walk stops at 70 % of it.
	ReachLongBand = 10.0
	// ReachMidBackoff is what the walk stops short of reach by in the middle
	// band.
	ReachMidBackoff = 2.0
	// ReachLongFactor is the fraction of the range the walk covers in the long
	// band.
	ReachLongFactor = 0.7
	// PlayerBCRadius is the BCRadius of every playable body row -- all 52
	// CHAR_* rows in the retail characterdata read 4 (col 50).
	PlayerBCRadius = 4
)

// ApproachBand is the (stop, reach) pair the action carries at +0x14/+0x18:
// how close the attacker walks, and how far away the blow still lands.
// casterBC/targetBC are the two BCRadius values, rangeUnits the effective
// range after the skill/weapon choice (world units = tenths of a metre).
func ApproachBand(casterBC, targetBC int, rangeUnits float64) (stop, reach float64) {
	base := float64(casterBC + targetBC)
	reach = base + rangeUnits
	switch {
	case rangeUnits > ReachLongBand:
		stop = base + ReachLongFactor*rangeUnits
	case rangeUnits > ReachShortBand && rangeUnits < ReachLongBand:
		stop = base + rangeUnits - ReachMidBackoff
	case rangeUnits <= ReachShortBand:
		stop = base + rangeUnits
	default: // exactly ReachLongBand: the engine adds nothing
		stop = base
	}
	return stop, reach
}

// EffectiveRange picks the range a blow uses: the skill's own Range column
// when it has one, else the attacker's weapon range (param 33 -- itemdata
// column 94; 0 unarmed, since nothing publishes it then).
func EffectiveRange(skillRange, weaponRange int) float64 {
	if skillRange != 0 {
		return float64(skillRange)
	}
	return float64(weaponRange)
}

// InReach is Action_IsTargetWithinReach: the truncated distance against the
// truncated reach plus the slack.
func InReach(distance, reach float64) bool {
	return int(math.Trunc(distance)) <= int(math.Trunc(reach))+ReachSlack
}
