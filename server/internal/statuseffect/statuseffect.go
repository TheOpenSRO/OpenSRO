// Package statuseffect carries the abnormal-state rules recovered from
// SR_GameServer.exe (round 275, 2026-09-20), with every number cited. Since
// round 659 it is also the system: apply.go lands a skill's status runs
// (Resolve), holder.go keeps an object's records and ticks them (Holder), and
// session/status.go wires both to monsters and characters.
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
	// SlotDecay and SlotWeakness are the defence curses, 'cspd' and 'csmd'
	// (round 875, READ: the OR sites s:0x592b85 / s:0x592d8e).
	SlotDecay    = 17
	SlotWeakness = 18
	// Round 881 (effects.go): the slots whose appliers were read then.
	SlotDark         = 13 // 'dn'
	SlotDisease      = 15 // 'ds'
	SlotPowerless    = 19 // 'cssr'
	SlotDissociation = 20 // 'csit'
	SlotPanic        = 21 // 'cshp'
	SlotCombustion   = 22 // 'csmp'
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

// How long a state lasts -- read 2026-09-20 (round 276).
//
// The record carries its duration at +0xc and the tick when it started at
// +0x64 (+0x68 being the LAST-tick stamp, which is a different field).
// AbnormalState_UpdateOwnerClear (0x4a4390) walks all 32 slots each pass and,
// for an active one, removes it when either
//
//	the owner's mask (pc+4) no longer holds the record's own bit (+0x8), or
//	GetTickCount() - record+0x64 > record+0xc
//
// otherwise it ORs the slot's mask into the new owner mask and calls the
// applier with mode 1. So the mask is the authority: clearing a bit there
// removes the state on the next pass.
//
// The duration itself comes from a CFormulae switch (0x410b40) that every one
// of the six elemental blocks calls the same way:
//
//	mov cx, WORD PTR [ebx+0x1a]     ; the resist-reduced STRENGTH it just computed
//	mov al, <slot>                  ; freeze 0, frostbite 1, burn 2,
//	call 0x410b40                   ;   electric shock 3, poison 4, zombie 5
//	mov [ebx+0xc], eax              ; the duration, in milliseconds
//
// CORRECTED in round 659: record+0x1a is value[0] after resistance, not the
// chance the state lands with. The landing chance is value[1], rolled BEFORE
// this through GObjPC::RollChance (0x5a1a20) with the chance-memory dice --
// see apply.go. Round 276 read "+0x1a" as the chance and concluded that the
// number which decides whether a state lands also decides how long it lasts;
// it does not. The kind byte is the SLOT, not the client bit -- burn passes 2
// and electric shock 3 -- which is a fourth independent agreement with the
// mask table (see MaskForSlot).

// DurationUnitMs is the milliseconds per point of strength a slot's states
// last.
// The six values are the engine's own literals in the switch: 0x61, 0xfa,
// 0x2ee (twice), 500 and 1000. Slots 2 and 5 share one case.
func DurationUnitMs(slot int) (int, bool) {
	switch slot {
	case SlotFreeze:
		return 97, true // 0x61
	case SlotFrostbite:
		return 250, true // 0xfa
	case SlotBurn, SlotZombie:
		return 750, true // 0x2ee
	case SlotElectricShock:
		return 500, true
	case SlotPoison:
		return 1000, true
	}
	// Every other slot asserts in the engine: only the six elemental blocks
	// take their duration from this formula.
	return 0, false
}

// DurationMs is the state's lifetime: the strength the block computed
// (value[0] after resistance, record+0x1a) times the slot's unit. The engine
// masks it to 16 bits before multiplying.
func DurationMs(slot, strength int) (int, bool) {
	unit, ok := DurationUnitMs(slot)
	if !ok {
		return 0, false
	}
	if strength < 0 {
		return 0, true
	}
	return (strength & 0xffff) * unit, true
}

// DefaultTickIntervalMs is what a block writes into record+0x10 when the skill
// carries no 'puls' value (`mov DWORD PTR [ebx+0x10], 0x7d0`). Only bleeding
// reads that field; burn, electric shock and poison hard-code TickIntervalMs.
const DefaultTickIntervalMs = 2000

// Expired is the removal test, with the engine's comparison kept exactly:
// a state lives while the elapsed time is at most its duration.
func Expired(nowMs, startMs uint32, durationMs uint32) bool {
	return nowMs-startMs > durationMs
}

// The non-elemental states -- read 2026-09-20 (round 277).
//
// The eleven-plus blocks after the six elemental ones in
// Combat_ApplyStatusEffects work the other way round. They store **no chance**
// (`mov WORD PTR [ebx+0x1a],0x0` in all 17 of them), so the elemental
// `chance x unit` duration cannot apply; instead the block computes the
// duration AND the chance from two authored values, both scaled down by how
// far the target's level is above the status's reach.
//
// Read as assembly, because the decompiler drops the whole FPU chain into
// argument-less `FUN_009fbb40()` (the ftol helper) -- the sleep block at
// 0x590f06..0x590ff9. The stack balances to empty, which is the reading's own
// check:
//
//	d   = max(GetLevel() - 10*(value2 + bonus), 0)     ; the OVERSHOOT
//	dur = max(ftol(value0 * (1 - 0.025*d)), ftol(0.5 * value0))   -> record+0xc
//	chn = max(ftol(value1 * (1 - 0.05*d)),  ftol(0.1 * value1))   -> rolled, not stored
//	record+0x18 = (byte)value2                        ; the status level
//
// So value0 is the duration in milliseconds and value1 the chance, each with
// its own falloff and its own floor.
const (
	// LevelReachPerStatusLevel is the 10 in the overshoot: a status of level n
	// reaches a target of level 10n before it starts weakening
	// (`lea edi,[eax+eax*4]` then `add edi,edi`).
	LevelReachPerStatusLevel = 10

	// The falloffs, as fractions per level of overshoot, and the floors they
	// stop at. 0.025 is the engine's 2.5 divided by its 100; 0.05 is its 5*d
	// divided by the same 100.
	DurationFalloffPerLevel = 0.025
	DurationFloorRatio      = 0.5
	ChanceFalloffPerLevel   = 0.05
	ChanceFloorRatio        = 0.1
)

// LevelOvershoot is how far a target's level exceeds a status's reach, floored
// at 0. `statusLevel` is the block's value2 plus whatever level bonus the cast
// carried.
func LevelOvershoot(targetLevel, statusLevel int) int {
	if d := targetLevel - LevelReachPerStatusLevel*statusLevel; d > 0 {
		return d
	}
	return 0
}

// scaleWithFloor is the shared shape: the value falls by `falloff` a level and
// never below `floor` of itself. ftol truncates toward zero, and so does this.
func scaleWithFloor(value int, overshoot int, falloff, floor float64) int {
	if value <= 0 {
		return 0
	}
	scaled := int(float64(value) * (1 - falloff*float64(overshoot)))
	if f := int(floor * float64(value)); scaled < f {
		return f
	}
	return scaled
}

// NonElementalDurationMs is the state's lifetime: value0, down 2.5% a level of
// overshoot, never below half.
func NonElementalDurationMs(value0, overshoot int) int {
	return scaleWithFloor(value0, overshoot, DurationFalloffPerLevel, DurationFloorRatio)
}

// NonElementalChance is the value the block rolls against: value1, down 5% a
// level of overshoot, never below a tenth. It is NOT stored on the record.
func NonElementalChance(value1, overshoot int) int {
	return scaleWithFloor(value1, overshoot, ChanceFalloffPerLevel, ChanceFloorRatio)
}

// The whole state vocabulary -- read 2026-09-20 (round 278).
//
// Three numberings and two names meet here, and they were joined from both
// binaries rather than by resemblance:
//
//   - the SKILL CODE and its field offset in CRefSkill (docs/protocol/
//     skill_fields.md, from the param parser);
//   - the KIND, the literal each block loads into ECX as `kind << 24` before
//     asking the target's effect map whether the state may be applied
//     (`mov ecx,0xN000000` before `call 0x5a1a20`, all 23 sites in
//     Combat_ApplyStatusEffects) -- kind is bit + 1 up to stun, not after
//     (round 875, below);
//   - the client's mask BIT, its icon file, and the LABEL the client carries
//     beside the icon (`0x7fdab0` in sro_client.exe).
//
// The labels settle it without arithmetic: the client calls the six elemental
// states FZ, FB, ES, BU, PS and ZB, and dark DN -- the skilldata codes in
// upper case. Fifteen of the twenty-three agree letter for letter, at both
// ends of the run and throughout, which leaves no room for the table to be
// off by a row.
//
// CORRECTED IN ROUND 875: from `ds` on, the client bit is NOT kind - 1. Each
// block ORs its state's SLOT bit into the result, and the slot is the one
// AbnormalState_UpdateOwnerClear (s:0x4a4390) indexes the applier table and
// the slot->mask table (0xc63ec8, the identity but for slots 2/3) with --
// READ, the OR sites s:0x592339 (ds 0x8000), s:0x59256a (ca 0x10000),
// s:0x592b85 (cspd 0x20000), s:0x592d8e (csmd 0x40000), s:0x592773 (cssr
// 0x80000), s:0x59297c (csit 0x100000), s:0x592fb1 (cshp 0x200000),
// s:0x5931d2 (csmp 0x400000), s:0x59351f (tb 0x1000000). MEASURED: a
// monster's `cspd` arrives as mask 0x20000 and the client says "You are under
// decay status". So the letters DO mean what they say -- `cspd` curses the
// physical defence, `csmd` the magical -- and the round-278 note that they
// did not ("the trap") had read the kind as the bit.
type State struct {
	Code  string // the skilldata param code, and its CRefSkill field
	Field int    // that field's offset
	Kind  int    // the `kind << 24` literal (= Bit + 1 up to stun only)
	Bit   int    // the client's mask bit
	Icon  string // icon\stateodd\s_<Icon>_icon.ddj
	Label string // the client's own label beside the icon
}

// States are the twenty-three the skill table can apply, in field order.
// Bits 12, 15 and 23 are absent: 15 (disease, DISEASE) exists as a state but
// no skill block applies it -- it is the gate param 169 the applier reads
// first -- and 12 and 23 have no block at all.
var States = []State{
	{"fz", 0x30c, 1, 0, "freeze", "FZ"},
	{"fb", 0x310, 2, 1, "frostbite", "FB"},
	{"es", 0x314, 3, 2, "electricshock", "ES"},
	{"bu", 0x318, 4, 3, "burn", "BU"},
	{"ps", 0x31c, 5, 4, "poisoning", "PS"},
	{"zb", 0x320, 6, 5, "zombi", "ZB"},
	{"se", 0x430, 7, 6, "sleep", "SLEEP"},
	{"rt", 0x434, 8, 7, "root", "ROOT"},
	{"sl", 0x438, 9, 8, "blunting", "SLOW"},
	{"fe", 0x43c, 10, 9, "fear", "FEAR"},
	{"my", 0x440, 11, 10, "myopia", "MYOPIA"},
	{"bl", 0x444, 12, 11, "bleeding", "BLOOD"},
	{"dn", 0x44c, 14, 13, "dark", "DN"},
	{"st", 0x450, 15, 14, "stun", "STUN"},
	{"ds", 0x454, 17, 15, "disease", "DISEASE"},
	{"ca", 0x458, 18, 16, "confusion", "CHAOS"},
	{"cssr", 0x45c, 19, 19, "powerless", "CURSE_STR"},
	{"csit", 0x460, 20, 20, "dissociation", "CURSE_INT"},
	{"cspd", 0x464, 21, 17, "decay", "CURSE_PD"},
	{"csmd", 0x468, 22, 18, "weakness", "CURSE_MD"},
	{"cshp", 0x46c, 23, 21, "panic", "CURSE_HP"},
	{"csmp", 0x470, 24, 22, "combustion", "CURSIE_MP"}, // the engine's own typo
	{"tb", 0x474, 25, 24, "incubation", "TIME_BOMB"},
}

// StateByCode finds a state by its skilldata param code.
func StateByCode(code string) (State, bool) {
	for _, s := range States {
		if s.Code == code {
			return s, true
		}
	}
	return State{}, false
}

// StateByBit finds a state by the client's mask bit.
func StateByBit(bit int) (State, bool) {
	for _, s := range States {
		if s.Bit == bit {
			return s, true
		}
	}
	return State{}, false
}
