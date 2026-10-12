package session

// The imbue (round 785): an action-kind-3 row with Basic_Activity 1 and
// 'att' -- the China *_GIGONGTA_* Forces. EngageSkill files its record at
// book+0x1e4 and every action dispatched while it runs carries its row
// (0x59b480 -> ctx+0x78), skills and plain swings alike; Combat_ResolveDamage
// adds its damage per hit (0x58f28d..0x58f491, READ).
// docs/protocol/skill_attack.md "The imbue".

import (
	"context"
	"math"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
)

// isImbueRow reports whether ref is an imbue: kind 3, Activity 1, 'att'.
func isImbueRow(ref *refdata.Skill) bool {
	if ref == nil || ref.ActionKind != 3 || ref.Activity != 1 {
		return false
	}
	if ref.HasParams() {
		return ref.Runs().Has("att")
	}
	return ref.AttackPercent > 0
}

// imbueOf is characterID's running imbue row, nil for none: the row of an
// active record that is an imbue (one at a time, book+0x1e4; the recast
// rule's state byte 1 keeps two from running, round 636).
func imbueOf(characterID int64) *refdata.Skill {
	for _, r := range buffBooks.Active(characterID) {
		if row := rowOf(false, characterID, r.SkillID); isImbueRow(row) {
			return row
		}
	}
	return nil
}

// attValue is the row's 'att' value[i], 0 without it (or an old export).
func attValue(ref *refdata.Skill, i int) int {
	if ref == nil || !ref.HasParams() {
		return 0
	}
	return int(ref.Runs().Value("att", i))
}

// imbueTerms is what one cast needs to add its imbue to each hit.
type imbueTerms struct {
	row     *refdata.Skill
	mastery int // ClampMasteryPercent(MAAT(blow), MAAT(imbue))
	scale   int // the blow row's att value[4]
}

// imbueFor resolves the imbue that applies to a blow of blowRow, or nil:
// only a blow whose row carries a non-zero 'att' value[4] takes it
// (0x58f28d, READ). China rows carry value[4] = value[1]; most Europe rows 0.
func imbueFor(ctx context.Context, skills skill.Store, characterID int64, blowRow *refdata.Skill) *imbueTerms {
	scale := attValue(blowRow, 4)
	if scale == 0 {
		return nil
	}
	row := imbueOf(characterID)
	if row == nil {
		return nil
	}
	p1 := skillMasteryPercent(ctx, skills, characterID, blowRow)
	p2 := skillMasteryPercent(ctx, skills, characterID, row)
	return &imbueTerms{row: row, mastery: combat.ClampMasteryPercent(p1, p2), scale: scale}
}

// imbueHit is the imbue's add to one hit on m: the imbue row's own blow --
// its magical half, the weapon's magical roll scaled by the clamped mastery,
// the row's flat range, mitigated, at its own 'att' percent, with no
// critical (magic never crits, READ) and no block (the hit's own block
// decided) -- then round(x * blowAtt.value[4] / 100).
func imbueHit(ctx context.Context, d combatDeps, characterID int64, it *imbueTerms, m combat.Monster, str, intel, level int) int {
	if it == nil {
		return 0
	}
	atk := combat.AttackType(attValue(it.row, 0))
	if !atk.Known() {
		atk = combat.AttackMagical
	}
	base, err := attackerDamageOf(ctx, characterID, str, intel, d.eq, d.items, atk, level, m.Level, combat.MonsterRate(m.Level))
	if err != nil {
		return 0
	}
	base = combat.ApplyMasteryScale(base, it.mastery)
	flat := 0
	if lo, hi := attValue(it.row, 2), attValue(it.row, 3); hi > 0 {
		flat = rollDamage(lo, hi)
	}
	def := m.Defense - statusFX.monsterDefenceCut(m.ID)
	blow := resolveBlow(base+flat, m.DefensePercent, def, 0, 0, level, m.Level, characterID, m.ID)
	dmg := combat.ApplySkillPercent(blow.Damage, attValue(it.row, 1))
	return int(math.Round(float64(dmg) * float64(it.scale) / 100))
}
