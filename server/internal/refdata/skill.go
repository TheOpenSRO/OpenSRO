package refdata

// Skill is this project's own, deliberately curated subset of the real
// _RefSkill table's 118 columns (all confirmed as of 2026-08-22, see
// docs/protocol/refdata_schema.md) -- this keeps only the ones with
// reasonably confirmed semantics, the same curation approach refdata.Item
// already uses (it drops _RefObjItem columns like ER_*/PAR_*/BR_* whose
// exact meaning isn't decoded either). Real column groups not represented
// here at all: the full targeting-rule bitset (Target_*/TargetGroup_*),
// weapon-cast requirements, and the 50 generic Param slots -- real, but not
// curated in yet.
//
// Notably absent: any damage/effect value. No confirmed _RefSkill column
// encodes what a skill actually does in combat, even after all 118 columns
// were catalogued -- that data plausibly lives in a separate, uncatalogued
// ability/effect system this project hasn't found yet. skill.Catalog's own
// DamageBonus stays an own-design choice layered on top of whichever real
// skill this identifies, not replaced by real data the way refdata.Item's
// stats are.
type Skill struct {
	ID      int64
	GroupID int64

	// BasicCode is an internal symbolic identifier (plausibly a SKILL_*
	// constant name), not display text. BasicName is a second confirmed
	// string column, but -- per refdata_schema.md's still-open "where do
	// display names live" question -- it's not confirmed to be real
	// human-readable text either, just a second internal string; treat it
	// the same way, not as something safe to show a player yet.
	BasicCode string
	BasicName string

	BasicLevel       int
	BasicChainCode   int64
	BasicRecycleCost int

	// Real timing/behavior fields, all in milliseconds unless noted.
	PreparingTimeMs  int
	CastingTimeMs    int
	ActionDurationMs int
	ReuseDelayMs     int
	CoolTimeMs       int
	FlyingSpeed      float64
	Interruptable    bool
	Overlap          bool
	AutoAttackType   int

	// Range is the real skill range (Action_Range), same unit convention as
	// everything else in this project's real distance fields (unconfirmed
	// scale, see the standing real-world-scale open item in
	// docs/protocol/MAPO_FORMAT.md).
	Range int

	// Real resource cost to use the skill (Consume_HP/Consume_MP) -- not
	// previously known before the 2026-08-22 full-column pass.
	ConsumeHP int
	ConsumeMP int

	// AttackPercent is the share of the wielder's weapon damage this skill
	// deals, and DamageMin/DamageMax a flat range added on top. REAL, from
	// the skill's own 'att' parameter (see cmd/export-refdata's attackParam):
	// a Sword Smash is 143% plus 15-18 at level 1, a plain swing 60% plus
	// nothing. Zero for the many skills that are buffs, heals or passives.
	AttackPercent int
	DamageMin     int
	DamageMax     int

	// AttackType is 'att' value[0], the damage-TYPE mask -- the word this
	// project discarded until 2026-09-16 while reading the three numbers
	// after it. REAL, and load-bearing in the engine: each half of a blow is
	// gated on one of its bits.
	//
	// Bit 4 enables the physical half, bit 8 the magical one, and no real
	// skill sets both (0 of 31,605 rows). Bits 1 and 2 are a separate axis
	// that selects which flat-absorption param the defender pays.
	//
	// 0 means the export predates the column, NOT "no damage" -- see
	// combat.AttackType, which treats an unknown mask as physical so an old
	// export behaves exactly as it did before the column existed.
	AttackType int

	// ReqCastWeapon1/2 are the two weapon types this skill may be cast with,
	// as TypeID4 codes (see refdata.Item.TypeID4). 255 marks an unused slot,
	// and both 255 means the skill has no weapon requirement -- 4,144 of the
	// 10,465 magical attack skills are in that state, including every CH
	// elemental nuke.
	//
	// RECOVERED, and named by the binary rather than by a schema listing: the
	// row loader SkillGlobal::FUN_005893e0 refuses a row whose CRefSkill+199 or
	// +200 is zero, logging "ReqWeapon Error [RefSkill ID: %d]". So ZERO IS NOT
	// "no requirement" in the real table -- it is invalid, and here it means
	// an export predating these columns. combat.SkillAllowsWeapon treats it
	// that way and permits the cast.
	ReqCastWeapon1, ReqCastWeapon2 int
	// HitCount is how many times one cast strikes: 1 for most skills, up to 5.
	//
	// CONFIRMED INDEPENDENTLY 2026-09-16: the client's own localisation key for
	// this param is PARAM_MC_COUNT. HitsFor was recovered from the `mc` param's
	// (2, N) shape alone, with no reference to the client, so the client
	// calling it a COUNT is agreement from a separate source rather than a
	// restatement. See docs/protocol/param_names.md.
	// REAL, from the skill's own 'mc' parameter (docs/protocol/skill_params.md,
	// field 0x288, a three-word run carrying the pair (2, N)).
	//
	// Settled by a use-site rather than by the name. Combat_ResolveDamage
	// (0058e5f0) initialises a per-attack record's +5 byte to 1, overwrites it
	// with the second 'mc' value when the first is 2, asserts it is non-zero,
	// and then runs its whole damage resolution inside
	//
	//	do { ... } while (i < *(byte *)(record + 5));
	//
	// with +6 as the iteration counter. The loop body contains the damage-kind
	// switch and the mitigation calls, so each iteration is an INDEPENDENT blow
	// -- its own damage roll, its own critical and block rolls -- not one blow
	// multiplied. That is why this is a count and not a multiplier.
	//
	// 0 is invalid (the engine asserts), so a missing or zero value reads as 1.
	// In the real table 24,368 skills are 1-hit, 3,855 are 2, 265 are 3, 59 are
	// 4 and 6 are 5.
	HitCount int

	// Real cost/prerequisite to learn the skill (ReqLearn_SP/ReqLearn_Race).
	ReqLearnSP   int
	ReqLearnRace int

	// The mastery this skill belongs to and the mastery level required to learn
	// it (ReqCommon_Mastery1 / ReqCommon_MasteryLevel1). These are what the
	// skill window gates a skill on -- a skill is learnable once the character's
	// level in Mastery1 reaches MasteryLevel1. The real table has a second
	// mastery/level pair too; only the first is curated in here for now.
	Mastery1      int64
	MasteryLevel1 int

	// UISkillName is a real, plausible candidate for the skill's actual
	// display name (UI_SkillName) -- distinct from BasicCode/BasicName, but
	// still not 100% confirmed to hold literal player-facing text rather
	// than another internal lookup key. Treat with the same caution as
	// BasicName until confirmed either way.
	UISkillName string
}

// HitsFor returns how many times a cast of this skill strikes: the skill's own
// HitCount, or one when the export predates the column or carries a value the
// engine would reject.
//
// The engine asserts the count is non-zero and its own default is 1, so 0 and
// anything negative read as a single strike rather than as "no attack".
func (s *Skill) HitsFor() int {
	if s == nil || s.HitCount < 1 {
		return 1
	}
	return s.HitCount
}
