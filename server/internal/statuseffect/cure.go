package statuseffect

// Cures (round 785): FUN_004a56c0(holder, 0, curt, curl, rcur), run at the
// end of Skill_ApplyEffectsAndNotify on every target of a cast (READ, asm
// 0x4a56c0..0x4a5768; docs/protocol/skill_support.md "Cures"):
//
//   - the candidates are the active slots whose bit (MaskForSlot) is in
//     curl[0] or curt[0];
//   - rcur[0], when present, shuffles them (0x4a6560) and tries only
//     min(n, rcur[0]);
//   - curl [mask, chance, level]: chance = curl[1] when the state's level
//     (+0x18) is <= curl[2], else curl[1] / (level - curl[2]) (integer); a
//     roll that comes up ends the state;
//   - curt [mask, strength], for a bit curl does not cover (the six
//     elemental states): the state's start moves back by strength x the
//     slot's duration unit (DurationUnitMs, 0x410b40), and it ends when that
//     puts it past its duration.

// CureRule is a cast's cure runs (zero values for absent runs).
type CureRule struct {
	CurlMask, CurlChance, CurlLevel uint32
	HasCurl                         bool
	CurtMask, CurtStrength          uint32
	HasCurt                         bool
	Rcur                            int // 0: try every candidate
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
		if (r.HasCurl && r.CurlMask&bit != 0) || (r.HasCurt && r.CurtMask&bit != 0) {
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
			if roll(chance) {
				h.recs[slot] = nil
				ended = true
			}
			continue
		}
		unit, ok := DurationUnitMs(slot)
		if !ok {
			continue
		}
		back := r.CurtStrength * uint32(unit)
		rec.StartMs -= back
		if nowMs-rec.StartMs >= rec.DurationMs {
			h.recs[slot] = nil
			ended = true
		}
	}
	return ended
}
