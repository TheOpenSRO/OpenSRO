package statuseffect

// What the remaining states do to their owner (round 881). Each is its
// slot's applier in SR_GameServer.exe, READ as assembly; the record fields
// are the ones the state's own block in Combat_ApplyStatusEffects writes.
//
//   - darkness ('dn', slot 13, AbnormalState_Dark_Apply13 s:0x4a4e20): param
//     11, the attack rate, gets a percent entry of -value[3] (record+0x48,
//     written at s:0x591e15; `push 5; push 1`, the abnormal context's
//     additive-percent slot), removed with the state. Every row carries 30.
//   - disease ('ds', slot 15, s:0x4a4f20): param 169 = value[3] (record
//     +0x44, s:0x5922f3), 0 again at the end. Combat_ApplyStatusEffects
//     reads it first (s:0x5906e6): Target.Disease.
//   - powerless ('cssr', slot 19, s:0x4a5000): params 178 and 179 get a
//     multiplier entry of -value[3] (record+0x38, s:0x59272d; `push 5; push
//     2`). They are the ATTACKER's physical and magical damage factors
//     (Formula_MitigatePhysicalDamage s:0x40e761, the magical twin
//     s:0x40eb13): the owner's blows land x (1 - value[3]/100).
//   - dissociation ('csit', slot 20, s:0x4a50b0): params 180 and 181 get a
//     multiplier entry of +value[3] (record+0x38, s:0x592936). They are the
//     DEFENDER's factors, read right after 178/179 (s:0x40e793,
//     s:0x40eb45): the owner takes x (1 + value[3]/100).
//   - panic ('cshp', slot 21, s:0x4a5320) and combustion ('csmp', slot 22,
//     s:0x4a54a0), twins over HP and MP: param 3 (max HP) / 4 (max MP) gets
//     the abnormal context's scale entry max(100 - value[3], 1) percent
//     (record+0x2c; `push 5; push 3`), 100 again at the end; param 143 / 144
//     = value[4] (record+0x34), the percent ApplyHPMPDelta (s:0x4a86a0)
//     takes off every HP / MP the owner recovers; and record+0x30 = the low
//     word of ftol(max HP / max MP as just cut x value[5] / 100), which the
//     tick hands to ConsumeHpMp (s:0x4a8770) as its MP argument once more
//     than 2000 ms have passed since the last (`cmp eax,0x7d0; jbe`). Both
//     ticks pass (0, amount, 2): panic's drain is worked from the max HP but
//     comes off the MP, as combustion's does. (MEASURED: 161 of the table's
//     178 'cshp' rows are `0,50,0` -- no cut of the max, half the recovery,
//     no drain -- and 5 more have no drain either.)

// DrainIntervalMs is the gap panic's and combustion's tick waits for:
// strictly more than this many ms.
const DrainIntervalMs = 2000

// HitRatePercent is the percent entry darkness adds to the owner's attack
// rate (param 11): -value[3], 0 without one.
func (h *Holder) HitRatePercent() int {
	if r := h.recs[SlotDark]; r != nil {
		return -r.Value3
	}
	return 0
}

// Disease is the owner's param 169: a disease's value[3], 0 without one.
func (h *Holder) Disease() int {
	if r := h.recs[SlotDisease]; r != nil {
		return r.Value3
	}
	return 0
}

// DealtFactor multiplies every blow the owner deals (params 178 / 179):
// 1 - value[3]/100 under powerless, 1 without it.
func (h *Holder) DealtFactor() float64 {
	if r := h.recs[SlotPowerless]; r != nil {
		return 1 - float64(r.Value3)/100
	}
	return 1
}

// TakenFactor multiplies every blow the owner takes (params 180 / 181):
// 1 + value[3]/100 under dissociation, 1 without it.
func (h *Holder) TakenFactor() float64 {
	if r := h.recs[SlotDissociation]; r != nil {
		return 1 + float64(r.Value3)/100
	}
	return 1
}

// maxScale is max(100 - value[3], 1) for a slot's record, 100 without one.
func (h *Holder) maxScale(slot int) int {
	r := h.recs[slot]
	if r == nil {
		return 100
	}
	if v := 100 - r.Value3; v > 0 {
		return v
	}
	return 1
}

// MaxHPScale is the percent panic leaves of the owner's max HP (100: none).
func (h *Holder) MaxHPScale() int { return h.maxScale(SlotPanic) }

// MaxMPScale is the percent combustion leaves of the owner's max MP.
func (h *Holder) MaxMPScale() int { return h.maxScale(SlotCombustion) }

// RecoverCut is the percent taken off the HP (param 143, panic) or the MP
// (param 144, combustion) the owner recovers; 0 without the state. The
// params are capped at 100.
func (h *Holder) RecoverCut(mp bool) int {
	slot := SlotPanic
	if mp {
		slot = SlotCombustion
	}
	r := h.recs[slot]
	if r == nil || r.Value4 <= 0 {
		return 0
	}
	if r.Value4 > 100 {
		return 100
	}
	return r.Value4
}

// Recovered is an amount of HP or MP after a recover cut of `cut` percent:
// ftol((1 - cut/100) x amount) (ApplyHPMPDelta s:0x4a86c9..0x4a86d7).
func Recovered(amount, cut int) int {
	if cut == 0 || amount <= 0 {
		return amount
	}
	return int((1 - float64(cut)/100) * float64(amount))
}

// DrainOf is the amount a panic or a combustion drains a tick: the low word
// of ftol(max x value[5] / 100), max the owner's max HP (panic) or max MP
// (combustion) with the state's own cut already in it.
func DrainOf(max, value5 int) int {
	if max <= 0 || value5 <= 0 {
		return 0
	}
	return int(float64(max)*(float64(value5)/100)) & 0xffff
}

// DrainSpec is what SetDrain needs of a panic or a combustion on the holder:
// its value[5], and whether the state is on.
func (h *Holder) DrainSpec(slot int) (value5 int, on bool) {
	if slot != SlotPanic && slot != SlotCombustion {
		return 0, false
	}
	if r := h.recs[slot]; r != nil {
		return r.Value5, true
	}
	return 0, false
}

// SetDrain files a panic's or a combustion's amount a tick on its record
// (record+0x30), once the state has landed and the owner's max is known.
func (h *Holder) SetDrain(slot, amount int) {
	if slot != SlotPanic && slot != SlotCombustion {
		return
	}
	if r := h.recs[slot]; r != nil {
		r.DrainMP = amount
	}
}
