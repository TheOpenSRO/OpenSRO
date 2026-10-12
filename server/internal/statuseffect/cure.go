package statuseffect

// Cures (round 785): FUN_004a56c0(holder, elem6, curt, curl, rcur), run at
// the end of Skill_ApplyEffectsAndNotify on every target of a cast (READ, asm
// 0x4a56c0..0x4a5768; docs/protocol/skill_support.md "Cures"), and -- round
// 786 -- by the cure pills, CGItemExpendable slot 308 (0x49b710) for TypeID
// 3/3/2 (docs/protocol/cure_pills.md):
//
//   - the candidates are the active slots whose bit (MaskForSlot) is in
//     curl[0] (arg 4, tested first, 0x4a5722) or curt[0] (arg 3, 0x4a5730),
//     or -- when arg 2, the universal pill's six Params, is given -- any
//     active slot 0..5, the elemental six (0x4a573e `cmp [esp+0x48],ecx`,
//     0x4a5744 `cmp bl,0x5; ja`). A skill passes 0 there;
//   - rcur[0], when present, shuffles them (0x4a6560) and tries only
//     min(n, rcur[0]);
//   - curl [mask, chance, level]: chance = curl[1] when the state's level
//     (+0x18) is <= curl[2], else curl[1] / (level - curl[2]) (integer); a
//     roll that comes up ends the state;
//   - curt [mask, strength], for a bit curl does not cover: the state's start
//     moves back by strength x the slot's duration unit (DurationUnitMs,
//     0x410b40, which takes the strength as a 16-bit cx);
//   - elem6, for a slot 0..5 neither covers: the same move with Param[slot]
//     as the strength (the jump table at 0x4a59d0 picks it, 0x4a58b4..
//     0x4a58cc); a zero Param skips the slot (0x4a58cf `test edi,edi; je`);
//   - curt and elem6 join at 0x4a58ef: a zero move skips the slot, otherwise
//     the start moves back and the state ends when the elapsed time is ABOVE
//     its duration (0x4a5908 `sub eax,[esi+0x64]`, 0x4a590b `cmp eax,
//     [esi+0xc]`, 0x4a590e `jbe` keeps it) -- round 786 corrected round 785's
//     `>=`, which ended a state the engine keeps at exactly its duration.

// CureRule is a cast's or a pill's cure runs (zero values for absent runs).
type CureRule struct {
	CurlMask, CurlChance, CurlLevel uint32
	HasCurl                         bool
	CurtMask, CurtStrength          uint32
	HasCurt                         bool
	Rcur                            int // 0: try every candidate
	// Elem is FUN_004a56c0's second argument (round 786): the universal
	// pill's Param1..6, a strength for each elemental slot 0..5 in slot
	// order. HasElem says it is passed (a skill passes 0).
	Elem    [6]uint32
	HasElem bool
}

// Cure applies r to h at nowMs. roll answers a percent chance; shuffle
// permutes the candidate list in place (nil: kept in slot order). It reports
// whether any state ended.
func (h *Holder) Cure(r CureRule, nowMs uint32, roll func(chance int) bool, shuffle func([]int)) bool {
	var cands []int
	for slot, rec := range h.recs {
		if rec == nil {
			continue
		}
		bit := MaskForSlot(slot)
		if (r.HasCurl && r.CurlMask&bit != 0) || (r.HasCurt && r.CurtMask&bit != 0) || (r.HasElem && slot <= 5) {
			cands = append(cands, slot)
		}
	}
	if r.Rcur > 0 && shuffle != nil {
		shuffle(cands)
	}
	if r.Rcur > 0 && len(cands) > r.Rcur {
		cands = cands[:r.Rcur]
	}
	ended := false
	for _, slot := range cands {
		rec := h.recs[slot]
		bit := MaskForSlot(slot)
		if r.HasCurl && r.CurlMask&bit != 0 {
			chance := int(r.CurlChance)
			if lvl := uint32(rec.Level); lvl > r.CurlLevel {
				chance = int(r.CurlChance / (lvl - r.CurlLevel))
			}
			if roll != nil && roll(chance) {
				h.recs[slot] = nil
				ended = true
			}
			continue
		}
		var strength uint32
		switch {
		case r.HasCurt && r.CurtMask&bit != 0:
			strength = r.CurtStrength
		case r.HasElem && slot <= 5:
			strength = r.Elem[slot]
			if strength == 0 {
				continue
			}
		default:
			continue
		}
		unit, ok := DurationUnitMs(slot)
		if !ok {
			continue
		}
		back := (strength & 0xffff) * uint32(unit)
		if back == 0 {
			continue
		}
		rec.StartMs -= back
		if Expired(nowMs, rec.StartMs, rec.DurationMs) {
			h.recs[slot] = nil
			ended = true
		}
	}
	return ended
}
