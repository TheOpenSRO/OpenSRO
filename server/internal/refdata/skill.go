package refdata

import (
	"strconv"
	"strings"
)

// Skill is this project's own, deliberately curated subset of the real
// _RefSkill table's 118 columns (all confirmed as of 2026-08-22, see
// docs/protocol/refdata_schema.md) -- this keeps only the ones with
// reasonably confirmed semantics, the same curation approach refdata.Item
// already uses (it drops _RefObjItem columns like ER_*/PAR_*/BR_* whose
// exact meaning isn't decoded either). Real column groups not represented
// here at all: most of the targeting-rule bitset (Target_Required,
// TargetType_Land and TargetGroup_Self/Ally/Party are curated since round
// 616; the rest are not), and the 50 generic Param slots beyond the runs the
// columns below extract -- real, but not curated in yet.
//
// CORRECTED 2026-09-18. This note used to say that no column encodes what a
// skill does in combat, and that the data "plausibly lives in a separate,
// uncatalogued ability/effect system this project hasn't found yet". That
// system is found: it is the **Params block**, and the engine parses it in
// SkillGlobal::RefSkill_ParseParams. See internal/skillparam for the recovered
// vocabulary -- 187 parameter codes, 184 of them resolved to the skill-record
// field the code fills.
//
// The damage is in there. skillparam.PhysDamage ('pdmg') lands at skill+0x234,
// which is the field Formulae::Formula_SkillPhysDamage reads -- two readings
// from different functions agreeing. 'pmdg', its magical counterpart, is at
// 0x340. And AttackPercent/DamageMin/DamageMax below already come from the
// 'att' parameter of that same block, so this file was using the system its
// own header said had not been found.
//
// RESOLVED 2026-09-18. This said 'att' was one of three codes skillparam could
// not place, because its branch "loops instead of storing once". It does not
// loop: it stores through the _Dst pointer the parser's prologue sets to
// skill+0x230, which a per-leaf reading could not see. 'att' is a fixed run of
// six words at field 0x230 -- the code plus the five values
// (type, percent, min, max, percent) that AttackPercent/DamageMin/DamageMax
// below already come from, which is the second, independent reading agreeing.
//
// skill.Catalog's own DamageBonus remains an own-design choice, but it is now
// a fallback over a system that IS mapped rather than over an unknown one.
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

	// ReqCastListCount is how many entries the skill puts in the five-slot list
	// at CRefSkill+0x3a0, filled by its 'reqi' parameter.
	//
	// It matters because THE WEAPON GATE DOES NOT APPLY WHEN IT IS NON-ZERO.
	// FUN_0058d480 opens with `if (skill[0x3a0] == 0)` and only checks
	// ReqCastWeapon1/2 inside that branch; a skill with a list takes an entirely
	// different path. 1,094 real skills carry 'reqi', and 517 of them also carry
	// a weapon requirement the engine therefore never applies.
	//
	// What the list HOLDS is not recovered, so srrevamp does not model the other
	// branch -- it simply declines to apply a check the engine would not.
	ReqCastListCount int

	// ReqCastList is the same list's records, packed as `kind:value;kind:value`
	// -- a TypeID3 category and a TypeID4 type, 0 meaning any. See
	// combat.CastRequirement, which holds the recovery.
	//
	// ReqCastAll is the skill's 'reqn' parameter (field 0x3b4): it turns the list
	// from ANY-of into ALL-of. 128 real skills set it, 966 do not.
	ReqCastList string
	ReqCastAll  bool

	// NoCombatParam is true when Combat_ResolveDamage (0x0058e5f0) would return
	// WITHOUT RESOLVING A BLOW for this skill, because it carries none of the 33
	// parameters that function tests and no 'efr' whose second value is 6. See
	// skillparam.CombatParameters.
	//
	// 1,797 of the 32,367 real skill rows that walk cleanly (5.6%) are like
	// this -- the buffs, heals and passives. Before this column srrevamp gave
	// every one of them an invented per-level damage bonus, because
	// session.skillDamageBonus fell back to the disclosed value whenever
	// AttackPercent was zero.
	//
	// Negative on purpose: an export predating the column loads false, which
	// means "this skill does resolve a blow" -- the behaviour every older
	// export already had.
	NoCombatParam bool

	// ZeroDamage is true when Combat_ResolveDamage's `local_d0` would be 1 for
	// this skill: it carries neither 'att' nor 'ck', so the ordinary damage
	// kind writes zero to BOTH halves of the blow and the total is their sum.
	// See skillparam.DamageParameters.
	//
	// Wider than NoCombatParam and containing it -- 2,482 real rows against
	// 1,813 -- because that one decides whether a blow is resolved at all and
	// this one decides whether a resolved blow carries damage. Both are kept
	// because the distinction is real, even though srrevamp models both as no
	// damage today.
	//
	// This is what finally removes DisclosedSkillDamagePerLevel from real data:
	// every skill without 'att' now has a grounded answer instead of an
	// invented per-level bonus. The constant survives only for the own-design
	// skill.Catalog, which has no real row at all.
	ZeroDamage bool

	// FloorBlow is true when every blow this skill lands is exactly the engine's
	// floor of 1: the blow is computed (the skill carries 'att' or 'ck') but the
	// computation is identically zero -- an 'att' percent of 0, an 'att' with
	// neither damage bit, or 'ck' with no 'att' at all -- and
	// Combat_ResolveDamage floors a computed zero at 1. See
	// skillparam.BlowIsFloor for the three cases and their citations.
	//
	// 446 real rows, 420 of them the mall pets' elemental skills. With
	// NoCombatParam and ZeroDamage this closes the set: on a fresh export every
	// one of the 33,632 real rows has a grounded damage answer, and
	// DisclosedSkillDamagePerLevel applies to none of them -- only to an export
	// predating these columns and to the own-design skill.Catalog.
	FloorBlow bool
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

	// The learn PREREQUISITES, skilldata columns 40..45 (ReqLearn_Skill1..3 /
	// ReqLearn_SkillLevel1..3): up to three skill GROUP ids that must be known
	// at at least the given level before this skill can be learned. In the
	// retail table 3,305 of 33,632 rows carry one -- e.g. Power Strike's B
	// series (SKILL_CH_SWORD_SMASH_B_01, mastery level 27) requires group 174
	// (the A series) at level 9. Zero = no prerequisite in that slot. Within
	// one group the levels chain structurally: a group has one learned level
	// and the next level is the only one learnable (session.LearnSkillHandler).
	ReqLearnSkill1, ReqLearnSkillLevel1 int64
	ReqLearnSkill2, ReqLearnSkillLevel2 int64
	ReqLearnSkill3, ReqLearnSkillLevel3 int64

	// SelfHealHP and SelfHealMP are what one cast restores to the CASTER: the
	// skill's 'heal' value[0] (HP) and value[2] (MP), exported only for the
	// shape whose result is exact -- action kind 0, Target_Required 0, a
	// completed Param walk with no combat parameter and none of 'efr', 'nmh',
	// 'mwhh', 'mwmh' or getv 'HLRU', and a zero +% bonus (value[1] for HP,
	// value[3] for MP). See skillparam.SelfHealAmounts for the path through
	// Skill_ApplyEffectsAndNotify (0x593f50) and Skill_ApplyHealToObject
	// (0x5a0850) and docs/protocol/heal.md. The 49 SKILL_CH_WATER_SELFHEAL
	// rows carry an HP amount, the 8 SKILL_EU_BARD_RECOVERA_ABNORMALTIME rows an
	// MP one.
	//
	// Zero means no self-heal, which is also what an export predating the
	// columns loads -- the behaviour srrevamp had before round 503.
	SelfHealHP int
	SelfHealMP int

	// CooldownGroup is the high byte of Action_Overlap (CRefSkill+0x8f; the
	// u32 at +0x8c is skilldata column 18, docs/protocol/skill_fields.md).
	// Skills sharing a non-zero group share ONE re-use timer:
	// SkillCooldowns::IsReady (0x64c1a0), for a row with a ReuseDelay, reads
	// this byte and, when it is non-zero, answers from the group map at
	// block+0x2c alone (the per-id map at +0x1c is consulted only for an
	// ungrouped row); the arm FUN_0064c700 (called from
	// Skill_BuildUseContext_A/B 0x5857b0/0x586700 and SkillAction_Buff
	// 0x5830b0) files the new timer under the same byte. On the real class
	// skills (SKILL_CH_/SKILL_EU_) the groups run 1..106 and 2,436 of 6,123
	// rows carry one -- Smash A and Smash D are both group 2.
	//
	// Zero means no group, which is also what an export predating the column
	// loads -- the per-skill timer srrevamp had before round 504.
	CooldownGroup int

	// SitGate is which of the skill-use gate's motion-state refusals apply
	// (round 607; docs/protocol/opcodes/motion.md), a bit mask:
	// SitGateActionOff (1) -- the skill carries 'ao' or 'pw', so a PC may not
	// cast it sitting or getting up or down (0x58e0ad..0x58e0cd);
	// SitGateTransform (2) -- 'msch' value[0] == 1, refused sitting
	// (0x58de46..0x58ded4). Zero: the gate does not refuse the skill for its
	// caster's motion state at all.
	SitGate int

	// The buff and self-cast columns (round 616, docs/protocol/skill_buffs.md),
	// a strict suffix: an export predating them loads every one as zero, which
	// is exactly the behaviour srrevamp had before -- no buff, no ground cast,
	// every cast resolved as an instant action.
	//
	// ActionKind is the first raw Param word, CRefSkill+0x168, the index
	// SkillActionHandler (0x589b50) dispatches on: 0 instant, 1 projectile,
	// 3 a timed buff (SkillAction_Buff 0x5830b0), 4 a stance
	// (skillparam.ActionKind*).
	ActionKind int
	// TargetRequired (+0x94, skilldata column 22), TargetLand (+0x96,
	// column 24) and TargetSelf/Ally/Party (+0x98/+0x99/+0x9a, columns
	// 26-28), docs/protocol/skill_fields.md.
	TargetRequired bool
	TargetLand     bool
	TargetSelf     bool
	TargetAlly     bool
	TargetParty    bool
	// DuraMs is 'dura' value[0] (+0x280), the buff's duration in ms:
	// SkillAction_Buff ends the record when elapsed > dura[0] + the cast
	// context's extension (skillparam.BuffEndsAt). Zero: the row has no
	// 'dura'.
	DuraMs int
	// The four marker codes the buff paths test (docs/protocol/skill_params.md,
	// the marker section): 'cbuf' (+0x358), 'nbuf' (+0x35c) -- the dispel
	// FUN_0059eff0 refuses a record of such a skill that the owner did not
	// cast itself -- 'bbuf' (+0x360) and 'lnks' (+0x370).
	Cbuf, Nbuf, Bbuf, Lnks bool
	// Tele0 and Tele1 are 'tele' (+0x2ec) value[0] and value[1]. FUN_005862e0
	// clamps a ground cast's destination to Tele1 world units from the caster
	// (Ghost Walk B lv1: 500, 100). Tele0 is not read there (OPEN). Both
	// zero: the row has no 'tele'.
	Tele0, Tele1 int
	// BuffParams is every run of the row whose code publishes a ParamKeeper
	// param (skillparam.Contributions), as `code:v0,v1,...;code:...` -- the
	// values after the code word, in order. See Skill.BuffParam.
	BuffParams string
	// Lks2 is the row's 'lks2' marker (+0x374, round 616's review): the
	// recast rule (FUN_0059d870) skips its GroupID branch for a row that
	// carries it. A suffix after BuffParams; an older export loads false.
	Lks2 bool
	// TargetHealHP and TargetHealMP are what one cast restores to EACH
	// character it names (round 622; skillparam.TargetHealAmounts): a
	// Target_Required 1 row's flat 'heal', the branch of
	// Skill_ApplyEffectsAndNotify (0x593f50) that heals every living target
	// in the use context's vector (0x59461b). Heal A lv1 (id 149): 369 HP.
	// A suffix after Lks2; an older export loads 0, no heal on a target.
	TargetHealHP int
	TargetHealMP int
	// The recast-rule columns (round 636; CSV 64..76, cmd/export-refdata
	// stackColumns, docs/protocol/skill_buffs.md "The recast rule"):
	// ActionOverlap is Action_Overlap (+0x8c) AND 0xffffff, the three state
	// bytes FUN_0059db10 tests and SkillBook::SetGroupBits sets; Ovl2 'ovl2'
	// value[0] (+0x37c); HasDttp/Dttp0/Dttp1 'dttp' (+0x424); Efr2 an 'efr'
	// of kind 2 (+0x290); Offensive FUN_00589d20's answer; Msch1 'msch'
	// value[0] == 1 (+0x4a4); Hide 'hide' (+0x428); SkcEnd 'skc' value[1]'s
	// low byte (+0x490 -> +4); BasicGroup Basic_Group (+0x44); Activity
	// Basic_Activity (+0x65); Dtt 'dtt' (+0x420). A suffix after
	// TargetHealMP; an older export loads zero/empty for all of them.
	ActionOverlap int64
	Ovl2          int64
	HasDttp       bool
	Dttp0, Dttp1  int64
	Efr2          bool
	Offensive     bool
	Msch1         bool
	Hide          bool
	SkcEnd        int
	BasicGroup    string
	Activity      int
	Dtt           bool
	// FUN_0059dc80's columns (the review of round 636; CSV 77..81,
	// cmd/export-refdata linkColumns): LnksGroup and LnksMax are 'lnks'
	// value[0] and value[2] (+0x370), Efr3 an 'efr' of kind 3 (+0x294), Qest
	// 'qest' (+0x49c), Trap 'trap' (+0x4a0). A suffix after Dtt; an older
	// export loads zero for all of them, and the check never refuses.
	LnksGroup int64
	LnksMax   int64
	Efr3      bool
	Qest      bool
	Trap      bool
	// Efr1 is an 'efr' of kind 1 (+0x28c; CSV 82, round 636's review
	// follow-up): with a Basic_Activity other than 1 SkillAction_Buff's
	// sub-state 0 collects targets and charges before any bit test
	// (0x5830b0, READ). An older export loads false.
	Efr1 bool
	// Pw is 'pw' value[0..3] (+0x2b4; round 640, CSV 83..86, cmd/
	// export-refdata wallColumns): the protection wall's damage-type mask
	// (bit 4 physical, bit 8 magical), its HP, its flat defence and its
	// defence percent -- all READ, docs/protocol/skill_buffs.md "The
	// protection walls". All zero on a row without the run (HasWall false).
	Pw0, Pw1, Pw2, Pw3 int64

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

// BuffParam returns the values of the row's publishing param run code (see
// BuffParams), and whether the row carries it.
func (s *Skill) BuffParam(code string) ([]int, bool) {
	if s == nil || s.BuffParams == "" {
		return nil, false
	}
	for _, run := range strings.Split(s.BuffParams, ";") {
		c, vals, ok := strings.Cut(run, ":")
		if !ok || c != code {
			continue
		}
		var out []int
		for _, v := range strings.Split(vals, ",") {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil {
				return nil, false
			}
			out = append(out, n)
		}
		return out, true
	}
	return nil, false
}

// HasWall reports whether the row carries 'pw', a protection wall (round
// 640). The mask is never 0 on a real row (7 or 11, MEASURED); a zero mask is
// an export predating the columns.
func (s *Skill) HasWall() bool { return s != nil && s.Pw0 != 0 }

// HasTele reports whether the row carries 'tele', the ground-cast move.
func (s *Skill) HasTele() bool { return s != nil && (s.Tele0 != 0 || s.Tele1 != 0) }

// The SitGate bits.
const (
	SitGateActionOff = 1
	SitGateTransform = 2
)
