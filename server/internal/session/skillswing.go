package session

// The plain swing's share of round 785: a swing is its weapon's base attack
// skill (PrepareAction 0x4ad030, round 505), so it takes the running imbue's
// add (0x59b480 copies the imbue's row into every action, READ), the buffs'
// damage percent, and answers with the action block as a cast does. From
// the round 785 review its hits are resolved by the cast's own per-hit
// path (performAttack -> castContext.strike / apply, skillhit.go); what is
// left here is the older block builder for a list of summed hits.

// swingHit is one hit of a plain swing, as performAttack resolved it.
type swingHit struct {
	dmg     int
	crit    bool
	blocked bool
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
