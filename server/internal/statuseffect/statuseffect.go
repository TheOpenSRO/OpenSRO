// Package statuseffect carries the abnormal-state rules recovered from
// SR_GameServer.exe (round 275, 2026-09-20). srrevamp has no status-effect
// system yet; this is the spec for one, with every number cited.
//
// See docs/protocol/status_effects.md for the evidence.
//
// # Where a state lives
//
// A character holds a FIXED ARRAY of 32 state records, stride 0x70, starting at
// pc+0xc, with the applier for record i at pc+0xe0c+4*i (installed by
// GObjPC_InstallParamContributionCallbacks, 0x4a40c0). An applier is called
// with a mode byte -- 0 apply, 1 tick, 2 remove -- and the record.
//
// The character's mask (pc+4), which is what the client turns into icons, is
// rebuilt by OR-ing MaskForSlot(i) for every slot whose active byte is set
// (AbnormalState_DeactivateSlotAndRebuildMask, 0x4a5660).
package statuseffect

// MaskTable is the engine's own table at 0xc63ec8: the client-facing mask bit
// each of the 32 server slots carries. It is the identity 1<<i everywhere
// EXCEPT slots 2 and 3, which are SWAPPED -- slot 2 carries 0x8 (the client's
// burn) and slot 3 carries 0x4 (electric shock).
//
// That swap is not a curiosity. Round 248 aligned the appliers with the
// client's icons by slot number and got those two the wrong way round; the
// table is the engine stating the alignment itself, and three independent
// data-flow pairs agree with it (see BurnTickDamage, ElectricShockParryPercent
// and PoisonTickDamage below, each reading the field its own state's block
// writes).
func MaskForSlot(slot int) uint32 {
	switch {
	case slot < 0 || slot > 31:
		return 0
	case slot == 2:
		return 0x8
	case slot == 3:
		return 0x4
	}
	return 1 << uint(slot)
}

// SlotForBit inverts MaskForSlot: the server slot that drives a client icon
// bit.
func SlotForBit(bit int) int {
	switch {
	case bit < 0 || bit > 31:
		return -1
	case bit == 2:
		return 3
	case bit == 3:
		return 2
	}
	return bit
}

// The slots whose appliers are read. Named by the mask table, not by
// plausibility.
const (
	SlotFreeze        = 0
	SlotFrostbite     = 1
	SlotBurn          = 2 // mask 0x8 -- the client's bit 3
	SlotElectricShock = 3 // mask 0x4 -- the client's bit 2
	SlotPoison        = 4
	SlotZombie        = 5 // its applier pointer is the shared 3-byte `return 0`
	SlotBleeding      = 11
)

// TickIntervalMs is the period the three damaging states check against their
// own last-tick stamp (record+0x68): `GetTickCount() - stamp < 0x7d1` returns,
// so a tick lands once 2001 ms have passed. It is hard-coded in each applier
// -- burn, electric shock and poison do NOT use the record's own interval at
// +0x10 the way bleeding does.
const TickIntervalMs = 2001

// BurnTickDamage is burn's damage per tick (AbnormalState_Apply02, 0x4a46f0):
//
//	damage = table[value2] / (1 + param8/100) * factor
//
// `table` is the 140-entry word table at 0xc63c94 that the skill's `bu`
// block indexes with its third status value; `factor` is the float at
// record+0x20, which the applier block writes as 1.0; and param8 is the
// character's ParamKeeper param 8, which the registry leaves unnamed (0..10000)
// -- so it is quoted here as what it is, a percentage the tick divides by, and
// not given a meaning it has not earned.
//
// The tick is dealt through the damage virtual with the effect's source, and
// burn CAN kill: the applier only drops the source when the blow would not be
// fatal (`if damage < curHP { source = nil }`), which is how a killing tick
// gets credited.
func BurnTickDamage(tableValue, param8 int, factor float64) int {
	if tableValue <= 0 {
		return 0
	}
	d := float64(tableValue) / (1 + float64(param8)/100) * factor
	if d <= 0 {
		return 0
	}
	return int(d)
}

// PoisonTickDamage is poison's damage per tick (AbnormalState_Apply04,
// 0x4a4940), and the shape is the interesting part:
//
//	loss   = max(curHP - value2, 1)
//	damage = curHP - loss          == min(value2, curHP-1)
//
// so **poison cannot kill**: it stops at 1 HP. The applier also clears the
// source unconditionally, so a poison tick is never credited to anyone.
func PoisonTickDamage(value2, curHP int) int {
	if curHP < 1 || value2 <= 0 {
		return 0
	}
	loss := curHP - value2
	if loss < 1 {
		loss = 1
	}
	if d := curHP - loss; d > 0 {
		return d
	}
	return 0
}

// ElectricShockParryPercent is what electric shock contributes to param 9, the
// parry rate (AbnormalState_Apply03_p9, 0x4a4850): `clamp(100 - value2, 0,
// 100)`, written into the abnormal-state ParamKeeper slot on apply and set back
// to 100 on removal.
//
// The neutral value being 100 is the useful part: a param-9 contribution from
// this slot is a PERCENT OF NORMAL, not a flat delta.
const ParryPercentNeutral = 100

func ElectricShockParryPercent(value2 int) int {
	v := ParryPercentNeutral - value2
	if v < 0 {
		return 0
	}
	if v > ParryPercentNeutral {
		return ParryPercentNeutral
	}
	return v
}
