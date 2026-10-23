package session

import (
	"context"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// Which learned skills a player may hold and cast (the round 691 review).
//
// Retail never puts a skill into a player's book that the learn check
// FUN_0059e450 would refuse, except the defaults _AddNewChar writes (the race's
// base attacks, `_RefCharDefault_Skill`). OpenSRO's learn gate refused too
// little before round 691 and its review -- no 0x3409, no race clause -- so a
// character can hold a monster's skill or another race's. The cast path checks
// only that a skill is known, so such a skill would cast. playerHoldRefusal is
// the learn check's rules applied to a held skill, and the cast and the skill
// state both apply it; a skill that fails is dropped (purgeUnholdable).

// baseAttackSkills is every weapon type's base attack (combat.BaseAttackSkillFor,
// READ from SkillGlobal::PostLoadSkillTable): the only rows with a ReqLearn_SP of
// 0 a player holds -- `_RefCharDefault_Skill` gives each race its own.
var baseAttackSkills = func() map[int64]bool {
	out := map[int64]bool{}
	for t := 1; t <= 15; t++ {
		if id := combat.BaseAttackSkillFor(t); id != 0 {
			out[id] = true
		}
	}
	return out
}()

// playerHoldRefusal is why a character of the given Country may not hold or cast
// ref, or "" when it may: the learn check's race clause (0x3405), its held
// mastery (0x3401) and, for a row with no mastery, its ReqLearn_SP (0x3409:
// every monster/pet/guard/trap row), with the base attacks exempt. A nil ref (an own-design catalog skill) is not judged.
func playerHoldRefusal(ref *refdata.Skill, country int) string {
	if ref == nil {
		return ""
	}
	if !skill.LearnRaceAllows(ref.ReqLearnRace, country) {
		return "not your race's skill"
	}
	if ref.Mastery1 > 0 && !skill.HoldsMastery(country, ref.Mastery1) {
		return "not your race's mastery"
	}
	// No mastery and no learn cost is the shape of every monster, pet, guard,
	// trap and event row (26,646 MSKILL_..GSKILL_ rows MEASURED on round 691's
	// re-export, plus 47 SKILL_ event/mall rows) and of
	// the base attacks; a class skill with no cost (a chain link such as
	// SKILL_CH_SWORD_KNOCKDOWN_E2_01; 205 sit on the skill boards, and the
	// export holds 801 China and 462 Europe zero-cost rows with a mastery in
	// all, MEASURED in round 691's review) is unlearnable too, but it is its
	// race's own and a cast of it is a class skill's, so only the mastery-less
	// shape is refused here (OURS: one held from before the fix stays castable
	// and MasteryLevel1 is not re-checked at cast); the learn gate refuses both
	// (0x3409).
	if ref.ReqLearnSP <= 0 && ref.Mastery1 == 0 && !baseAttackSkills[ref.ID] {
		return "not a player skill"
	}
	return ""
}

// forgetUnholdable drops skillID from characterID when the store can, and logs
// it. The skill's refusal is the reason logged.
func forgetUnholdable(ctx context.Context, skills skill.Store, characterID, skillID int64, reason string) {
	f, ok := skills.(skill.Forgetter)
	if !ok {
		slog.Warn("skill held that no player may hold; the store cannot drop it",
			"character_id", characterID, "skill", skillID, "reason", reason)
		return
	}
	if err := f.Forget(ctx, characterID, skillID); err != nil {
		slog.Warn("dropping a skill no player may hold failed",
			"character_id", characterID, "skill", skillID, "reason", reason, "err", err)
		return
	}
	slog.Warn("dropped a learned skill no player may hold",
		"character_id", characterID, "skill", skillID, "reason", reason)
}

// purgeUnholdable drops every skill characterID knows that playerHoldRefusal
// refuses for its Country, and returns the skills it keeps. Skills the
// reference data does not carry (the own-design catalog) are kept.
func purgeUnholdable(ctx context.Context, skills skill.Store, skillRef SkillRefStore, characterID int64, country int, known []int64) []int64 {
	if skillRef == nil {
		return known
	}
	kept := known[:0:0]
	for _, id := range known {
		ref, err := skillRef.GetSkill(ctx, id)
		if err == nil && ref != nil {
			if reason := playerHoldRefusal(ref, country); reason != "" {
				forgetUnholdable(ctx, skills, characterID, id, reason)
				continue
			}
		}
		kept = append(kept, id)
	}
	return kept
}
