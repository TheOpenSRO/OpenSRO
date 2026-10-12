package session

import (
	"context"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/skillparam"
)

// rowHasMAAT reports whether ref carries 'getv MAAT', the only writer of
// CRefSkill+0x574 (SkillGlobal::RefSkill_ParseParams 0x587630, READ), which
// Skill_GetRequiredMasteryLevel (0x59e770) tests before it answers anything
// but 0. An export before the Params column (round 785) cannot tell, and
// keeps the older rule: any row with a mastery slot.
func rowHasMAAT(ref *refdata.Skill) bool {
	if ref == nil {
		return false
	}
	if !ref.HasParams() {
		return ref.Mastery1 != 0
	}
	_, ok := ref.Runs().GetvValue(skillparam.Code("MAAT"))
	return ok
}

// skillMasteryPercent is stage 1's percentage for a blow of ref:
// Skill_GetRequiredMasteryLevel (0x59e770, READ round 785): 0 without
// MAAT; otherwise a = level(Mastery1) when the slot is set, else 1, b the
// same for Mastery2 (+0xa4), and the larger. A mastery the caster does not
// hold reads 0 (0x59e750 -> 0x59d6f0). The main blow takes it unclamped
// (0x58f148); the imbue's add clamps (combat.ClampMasteryPercent).
func skillMasteryPercent(ctx context.Context, skills skill.Store, characterID int64, ref *refdata.Skill) int {
	if !rowHasMAAT(ref) || skills == nil {
		return 0
	}
	levels, err := skills.MasteryLevels(ctx, characterID)
	if err != nil {
		levels = nil
	}
	return combat.MasteryDamagePercent(true, ref.Mastery1 != 0, ref.Mastery2 != 0,
		levels[ref.Mastery1], levels[ref.Mastery2])
}
