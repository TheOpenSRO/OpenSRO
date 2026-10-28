package session

// A character's buffs in its stats (round 785): every stat function reads
// its gear's value and passes it through buffStat with the param it is,
// which applies the active records' writes the way EvaluateParam
// (0x4b3740) combines entries -- (gear + flat) x (1 + pct/100) x mult
// (buff/stats.go). docs/protocol/skill_stats.md has the table.

import (
	"context"
	"math"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// buffTotal is one param's sums for characterID: its active records and
// its passives (passives.go).
func buffTotal(characterID int64, param int) (buff.Totals, bool) {
	if characterID == 0 {
		return buff.Totals{}, false
	}
	t, ok := charTotals(characterID)[param]
	return t, ok
}

// charTotals merges a character's buff records' sums with its passives'
// and, since round 789, its worn avatars' (avatarstats.go).
func charTotals(characterID int64) map[int]buff.Totals {
	return mergeTotals(buffAndPassiveTotals(characterID), avatarTotals(characterID))
}

// buffAndPassiveTotals is the buff records' sums merged with the passives'.
func buffAndPassiveTotals(characterID int64) map[int]buff.Totals {
	a := buffBooks.ParamTotals(characterID)
	p := passiveOf(characterID).totals
	if len(p) == 0 {
		return a
	}
	if len(a) == 0 {
		return p
	}
	out := make(map[int]buff.Totals, len(a)+len(p))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range p {
		t, seen := out[k]
		if !seen {
			out[k] = v
			continue
		}
		t.Flat += v.Flat
		t.Pct += v.Pct
		if v.HasMult {
			if !t.HasMult {
				t.Mult = 1
			}
			t.Mult *= v.Mult
			t.HasMult = true
		}
		out[k] = t
	}
	return out
}

// buffStat applies characterID's buffs to a param whose gear value is base.
func buffStat(characterID int64, param int, base float64) float64 {
	t, ok := buffTotal(characterID, param)
	if !ok {
		return base
	}
	return t.Apply(base)
}

// buffStatInt is buffStat rounded, for the int stats.
func buffStatInt(characterID int64, param int, base int) int {
	t, ok := buffTotal(characterID, param)
	if !ok {
		return base
	}
	return int(math.Round(t.Apply(float64(base))))
}

// buffFactor is a multiplier param's value for characterID (1 for none).
func buffFactor(characterID int64, param int) float64 {
	t, ok := buffTotal(characterID, param)
	if !ok {
		return 1
	}
	return t.Factor()
}

// buffDamagePercent is the attacker's damage-percent params (128..131,
// 'dru'/'dru2', Formula_Mitigate* 0x40e5a4 / 0x40e94a, READ): physical
// blows read 128 or 129 by the type's second axis, magical 130 or 131.
// OpenSRO's blows carry axis 1 (128 / 130).
func buffDamagePercent(characterID int64, magical bool) float64 {
	p := buff.ParamDamagePhysA
	if magical {
		p = buff.ParamDamageMagA
	}
	t, ok := buffTotal(characterID, p)
	if !ok {
		return 0
	}
	return t.Apply(0)
}

// applyBuffDamage scales a mitigated blow by the attacker's damage percent
// and its debuffed multiplier (p178/179, 'pmdg'), as the mitigation's tail
// does (0x40e5a4, 0x40e75b, READ).
func applyBuffDamage(characterID int64, magical bool, dmg int) int {
	if dmg <= 0 {
		return dmg
	}
	f := 1 + buffDamagePercent(characterID, magical)/100
	mp := buff.ParamAttackerMult
	if magical {
		mp++
	}
	f *= buffFactor(characterID, mp)
	if f == 1 {
		return dmg
	}
	out := int(float64(dmg) * f)
	if out < 1 {
		out = 1
	}
	return out
}

// applyPlayerTaken is a player defender's damage-taken multiplier (round
// 838): p174 (physical) or p176 (magical), which 'odar' writes at slot 2 --
// the damage absorption scrolls' 15,10 and 15,20 make it x0.9 and x0.8 -- and
// a worn avatar's 'dara' too (avatarstats.go). READ:
// Formula_MitigatePhysicalDamage (0x40e450) multiplies the mitigated blow by
// the DEFENDER's Formulae::SelectDaraParamForDamageType value when it is not
// 0, right after the attacker's damage percent (p128/129) and before the
// level advantage; the defender is any object, a player as a monster
// (applyMonsterTaken). Truncated, at least 1, as applyMonsterTaken does.
func applyPlayerTaken(characterID int64, magical bool, dmg int) int {
	if dmg <= 0 {
		return dmg
	}
	p := buff.ParamDefenderMult
	if magical {
		p += 2
	}
	f := buffFactor(characterID, p)
	if f == 1 {
		return dmg
	}
	out := int(float64(dmg) * f)
	if out < 1 {
		out = 1
	}
	return out
}

// buffBonus is the character.Bonus the buffs give (round 785): Str and Int
// (p1/p2 slot 0), max HP and MP flat and percent (p3/p4 slots 0 and 1),
// evade-critical (p57).
func buffBonus(characterID int64) character.Bonus {
	all := charTotals(characterID)
	if len(all) == 0 {
		return character.Bonus{}
	}
	b := character.Bonus{
		Str:       int(all[buff.ParamStr].Flat),
		Int:       int(all[buff.ParamInt].Flat),
		HP:        int(all[buff.ParamMaxHP].Flat),
		MP:        int(all[buff.ParamMaxMP].Flat),
		EvadeCrit: int(all[buff.ParamEvadeCrit].Flat),
		HPPct:     all[buff.ParamMaxHP].Pct,
		MPPct:     all[buff.ParamMaxMP].Pct,
	}
	return b
}

func init() {
	character.SetLiveBonusSource(buffBonus)
}

// buffedBlock is the block chance with the buffs' param 10 and the
// physical block bonus p136 ('br').
func buffedBlock(characterID int64, base int) int {
	v := buffStatInt(characterID, buff.ParamBlock, base)
	if t, ok := buffTotal(characterID, buff.ParamBlockByType); ok {
		v += int(math.Round(t.Apply(0)))
	}
	return v
}

// buffedWeaponRange applies the buffs' params 13/14 (physical) or 15/16
// (magical) to a rolled weapon's bounds.
func buffedWeaponRange(characterID int64, atk combat.AttackType, min, max int) (int, int) {
	lo, hi := buff.ParamPhysAtkMin, buff.ParamPhysAtkMax
	if !atk.IsPhysical() && atk.IsMagical() {
		lo, hi = buff.ParamMagAtkMin, buff.ParamMagAtkMax
	}
	return buffStatInt(characterID, lo, min), buffStatInt(characterID, hi, max)
}

// statsEnded reports whether any of recs wrote a stat.
func statsEnded(recs []buff.Record) bool {
	for _, r := range recs {
		if len(r.Stats) > 0 {
			return true
		}
	}
	return false
}

// pushOwnerStats sends a character its stats after a buff that wrote some
// started or ended (round 785; retail pushes the changed params, 0x303D --
// OpenSRO's stats result carries them all), clamping its HP and MP to a
// lowered maximum first.
func pushOwnerStats(ownerID int64) {
	d, ok := skillDeps()
	if !ok {
		return
	}
	e, in := d.hub.EntityByCharacterID(ownerID)
	if !in || e.Session == nil {
		return
	}
	ctx := context.Background()
	clampHP(ctx, d.chars, ownerID)
	c, err := d.chars.GetByID(ctx, ownerID)
	if err != nil || c == nil {
		return
	}
	if result, err := buildCharacterStats(ctx, c, c.ID, d.eq, d.items, d.skills, d.mp); err == nil {
		_ = e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
	}
}
