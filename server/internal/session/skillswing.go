package session

// The plain swing's share of round 785: a swing is its weapon's base attack
// skill (PrepareAction 0x4ad030, round 505), so it takes the running imbue's
// add (0x59b480 copies the imbue's row into every action, READ), the buffs'
// damage percent, and answers with the action block as a cast does.

import (
	"context"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
)

// swingHit is one hit of a plain swing, as performAttack resolved it.
type swingHit struct {
	dmg     int
	crit    bool
	blocked bool
}

// plainSwingExtras adds the buffs' damage percent and the imbue to a
// swing's hits and returns the new total (berserk already in net).
func plainSwingExtras(ctx context.Context, skills skill.Store, eq equipment.Store, items combat.ItemLookup,
	characterID int64, m combat.Monster, hits []swingHit, net, str, intel, level int) int {
	total := applyBuffDamage(characterID, false, net)
	base, ok := baseAttackOf(ctx, characterID, eq, items)
	if !ok {
		return total
	}
	it := imbueFor(ctx, skills, characterID, base)
	if it == nil {
		return total
	}
	d := combatDeps{eq: eq, items: items, skills: skills}
	for i := range hits {
		if hits[i].blocked {
			continue
		}
		add := imbueHit(ctx, d, characterID, it, m, str, intel, level)
		hits[i].dmg += add
		total += add
	}
	return total
}

// swingAction is a plain swing's action block, waiting for the kill bit.
type swingAction struct{ b *ActionBlock }

// swingBlock builds the block for a swing whose hits sum (after berserk and
// the extras) to net: each hit's part scaled so the parts sum to net.
func swingBlock(monsterID int64, hits []swingHit, net int) swingAction {
	raw := 0
	for _, h := range hits {
		raw += h.dmg
	}
	b := &ActionBlock{Target: uint32(monsterID), TargetKind: ActionTargetMonster, HitCount: uint8(len(hits))}
	tg := ActionTarget{UID: uint32(monsterID), Kind: ActionTargetMonster}
	left := net
	for i, h := range hits {
		ah := ActionHit{Kind: HitKindDamage, Flags: HitFlagNormal}
		if h.crit {
			ah.Flags = HitFlagCritical
		}
		part := h.dmg
		if raw > 0 && raw != net {
			part = h.dmg * net / raw
		}
		if i == len(hits)-1 {
			part = left
		}
		if h.blocked {
			ah.Kind, ah.Flags, part = HitKindBlocked, 0, 0
		}
		if part < 0 {
			part = 0
		}
		left -= part
		ah.Damage = uint32(part)
		tg.Hits = append(tg.Hits, ah)
	}
	b.Targets = []ActionTarget{tg}
	return swingAction{b}
}

// died marks the killing hit (the last that dealt damage) and returns the
// block.
func (s swingAction) died(dead bool) *ActionBlock {
	if s.b == nil || !dead || len(s.b.Targets) == 0 {
		return s.b
	}
	hs := s.b.Targets[0].Hits
	for i := len(hs) - 1; i >= 0; i-- {
		if hs[i].Kind&0x7f != HitKindBlocked {
			hs[i].Kind |= HitDied
			break
		}
	}
	return s.b
}
