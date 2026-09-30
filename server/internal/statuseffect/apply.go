package statuseffect

import (
	"strconv"
	"strings"
)

// How a skill's status run lands on a target -- round 659, read in
// Combat_ApplyStatusEffects (0x590680) of SR_GameServer.exe. Labels: READ
// (the binary), MEASURED (the archives), INFERRED, OURS (a choice of this
// project), OPEN.
//
// # The elemental six (fz fb es bu ps zb): value[1] is the CHANCE
//
// The freeze block, 0x590756..0x590889, is the pattern all six follow:
//
//	mov eax,[p+4]            ; value[1]
//	add eax,edi              ; + the target's param 169 (the disease gate, 0 unless diseased)
//	mov ecx,0x1000000        ; kind << 24, the dice key
//	lea edx,[esi+0xa30]      ; the TARGET's accumulator map
//	call 0x5a1a20            ; GObjPC::RollChance -- the chance-memory dice
//	je  skip
//	GetParam(27) -> resist%  ; >= 100: skip
//	strength = ftol((100 - resist%) / 100.0 * value[0]) - ftol(GetParam(145))
//	jle skip
//	record+0x1a = strength, record+0x14 = value[1]
//	record+0xc  = CFormulae 0x410b40(slot, strength)   ; the duration
//
// So value[1] is the percent chance the state lands, rolled through the same
// chance-memory dice as a critical (FUN_00599cc0, combat.RollChanceTracked),
// keyed by the state's kind on the TARGET. It is not a level: round 249 read
// it as one, and round 276 then called record+0x1a "the chance" -- that field
// is value[0] after resistance, the STRENGTH, and it is what the duration
// multiplies. The real rows agree (MEASURED, 33,698 skilldata rows):
// MSKILL_CH_WATERGHOST_ATTACK02 carries ps:34,100,16 -- a poison that always
// lands (100), lasts 34 s and takes 16 a tick -- and SKILL_CH_COLD_GIGONGTA_A_01
// carries fz:30,5 and fb:30,25, a 5 % freeze and a 25 % frostbite.
//
// value[2], where the run has one, is the state's own number: burn's index
// into the 0xc63c94 damage table, electric shock's parry cut, poison's damage
// a tick.
//
// # The other seventeen: value[0] duration, value[1] chance, value[2] level
//
// The sleep block, 0x590f06..0x5910f9, is NonElementalDurationMs and
// NonElementalChance (round 277) and then, READ this round, the same dice:
// `mov ecx,0x7000000; lea edx,[esi+0xa30]; call 0x5a1a20` with the chance in
// EAX, after three terms srrevamp holds as zero -- a lookup in the target's
// effect map (0x59de50, what the target's own buffs take off the chance), its
// percent cut, and the disease bonus. record+0x18 = (byte)value[2], the
// state's level, which is the byte the client's 0x3057 carries for every
// non-elemental bit (LevelBits).
//
// Bleeding (0x591a11..0x591c52) also writes record+0x38 = value[3], the damage
// a tick, record+0x40 = value[4], the flat defence it takes off, and
// record+0x10 = the row's 'puls' value[0], else 2000 ms (0x591bd7).
//
// OPEN, and not modelled: the extra halving loop the slow, bleeding and stun
// blocks run on the chance before the roll (`sar eax,1` per step at
// 0x591bc0), whose count is unread -- so srrevamp's chance for those three is
// the base one, which is never lower than retail's; the stun block's own
// guards (`[esp+0x43]`, and its skip when the call's fifth argument is set);
// the incubation block ('tb', +0x474), which has neither the 2.5 nor the 0.5
// -- it is NOT applied; and 'csmp' (bit 23), which has no applier and no icon
// -- NOT applied either.

// Run is one status run off a skill's Param block: its code and the values
// after the code word.
type Run struct {
	Code   string
	Values []int
}

// Value returns value[i], or 0 when the run is shorter.
func (r Run) Value(i int) int {
	if i < 0 || i >= len(r.Values) {
		return 0
	}
	return r.Values[i]
}

// ParseRuns reads refdata.Skill.StatusParams, `code:v0,v1;code:...`. A run
// that does not parse is skipped.
func ParseRuns(s string) []Run {
	var out []Run
	for _, part := range strings.Split(s, ";") {
		code, vals, ok := strings.Cut(strings.TrimSpace(part), ":")
		if !ok || code == "" {
			continue
		}
		r := Run{Code: code}
		good := true
		for _, v := range strings.Split(vals, ",") {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil {
				good = false
				break
			}
			r.Values = append(r.Values, n)
		}
		if good {
			out = append(out, r)
		}
	}
	return out
}

// PulsMs is the row's 'puls' value[0], the bleeding tick interval, and whether
// the row has one.
func PulsMs(runs []Run) (int, bool) {
	for _, r := range runs {
		if r.Code == "puls" && r.Value(0) > 0 {
			return r.Value(0), true
		}
	}
	return 0, false
}

// IsElemental reports whether a state is one of the six whose duration is
// strength x unit (the resist-reading blocks).
func IsElemental(code string) bool {
	switch code {
	case "fz", "fb", "es", "bu", "ps", "zb":
		return true
	}
	return false
}

// Applied reports whether srrevamp applies a code at all: every state the
// table names except 'tb' (its block's computation is unread) and 'csmp'
// (bit 23: no applier, no icon). See the package notes above.
func Applied(code string) bool {
	s, ok := StateByCode(code)
	if !ok {
		return false
	}
	return s.Code != "tb" && s.Code != "csmp"
}

// Target is what the roll needs to know about whoever the run lands on.
type Target struct {
	// Level is the target's level, which the non-elemental overshoot reads
	// (GetLevel, vslot 0x124).
	Level int
	// ResistPercent and ResistFlat are the target's params 27..32 and
	// 145..150 for an elemental state, indexed by its slot (0..5). Zero for
	// every monster (characterdata cols 61-66 are 0 on every row, MEASURED)
	// and, today, for every character: srrevamp publishes no resist params
	// (OPEN).
	ResistPercent [6]int
	ResistFlat    [6]int
}

// Roller is the chance-memory dice for one target: roll `chance` percent
// under the state's kind, and say whether it came up. The engine keys the
// accumulator by `kind << 24` in the TARGET's map (see above).
type Roller func(chance, kind int) bool

// Record is one state on an object: srrevamp's version of the engine's
// 0x70-byte record (see the field table in docs/protocol/status_effects.md).
type Record struct {
	Code string
	Slot int // the applier slot, and the record's index
	Bit  int // the client's mask bit (MaskForSlot(Slot) == 1<<Bit)
	// Level is record+0x18, the byte 0x3057 carries for a non-elemental bit;
	// 0 for the elemental six, whose bits carry none.
	Level int
	// Strength is record+0x1a for the elemental six: value[0] after
	// resistance, the number the duration multiplies. 0 for the others.
	Strength   int
	StartMs    uint32 // record+0x64
	DurationMs uint32 // record+0xc
	// LastTickMs is record+0x68. The engine's first value is not read; OURS:
	// the start, so the first tick is one interval after the state lands.
	LastTickMs uint32
	// TickIntervalMs is record+0x10, which only bleeding reads.
	TickIntervalMs int
	// TickValue is the per-tick number: poison's value[2], bleeding's
	// value[3], burn's table entry (0 without a table: see SetBurnTable).
	TickValue int
	// ParryPercent is electric shock's contribution to param 9.
	ParryPercent int
	// DefenceCut is bleeding's value[4], taken off both flat defences.
	DefenceCut int
	// SourceID is who applied it (record+0x4c): a character id, or a monster
	// id when SourceIsMonster.
	SourceID        int64
	SourceIsMonster bool
}

// Resolve decides one run against a target at nowMs: whether it lands, and
// the record it lands as. roll is asked exactly once for a run that reaches
// its roll, in the engine's order (the elemental roll comes BEFORE the resist
// test; the non-elemental one after the duration and chance are computed).
func Resolve(run Run, t Target, nowMs uint32, roll Roller) (Record, bool) {
	st, ok := StateByCode(run.Code)
	if !ok || !Applied(run.Code) {
		return Record{}, false
	}
	slot := SlotForBit(st.Bit)
	rec := Record{Code: st.Code, Slot: slot, Bit: st.Bit, StartMs: nowMs, LastTickMs: nowMs}
	if IsElemental(run.Code) {
		// The disease bonus (param 169) is 0: srrevamp applies no disease.
		if roll == nil || !roll(run.Value(1), st.Kind) {
			return Record{}, false
		}
		resist := t.ResistPercent[slot]
		if resist >= 100 {
			return Record{}, false
		}
		strength := int(float64(100-resist)/100.0*float64(run.Value(0))) - t.ResistFlat[slot]
		if strength <= 0 {
			return Record{}, false
		}
		dur, _ := DurationMs(slot, strength)
		rec.Strength = strength
		rec.DurationMs = uint32(dur)
		switch slot {
		case SlotPoison:
			rec.TickValue = run.Value(2)
		case SlotBurn:
			rec.TickValue = BurnTableValue(run.Value(2))
		case SlotElectricShock:
			rec.ParryPercent = ElectricShockParryPercent(run.Value(2))
		}
		return rec, true
	}
	d := LevelOvershoot(t.Level, run.Value(2))
	dur := NonElementalDurationMs(run.Value(0), d)
	chance := NonElementalChance(run.Value(1), d)
	if roll == nil || !roll(chance, st.Kind) {
		return Record{}, false
	}
	if dur <= 0 {
		return Record{}, false
	}
	rec.DurationMs = uint32(dur)
	rec.Level = run.Value(2) & 0xff
	if slot == SlotBleeding {
		rec.TickValue = run.Value(3)
		rec.DefenceCut = run.Value(4)
		rec.TickIntervalMs = DefaultTickIntervalMs
	}
	return rec, true
}

// burnTable is the 0xc63c94 word table burn's tick divides (BurnTickDamage).
// It is the operator's to supply (SetBurnTable): the table is read out of
// the server binary and is not copied into this repository (docs/LEGAL.md).
// Without it a burn lands, shows and expires but deals 0 a tick (OPEN).
var burnTable []int

// SetBurnTable installs the 0xc63c94 table (the low word of each of its
// 4-byte entries, index 0 first).
func SetBurnTable(t []int) { burnTable = append([]int(nil), t...) }

// BurnTableValue is table[i], or 0 outside it or without a table.
func BurnTableValue(i int) int {
	if i < 0 || i >= len(burnTable) {
		return 0
	}
	return burnTable[i]
}

// LevelBits is the mask of client bits whose state carries a level byte in
// 0x3057's abnormal block: MsgStreamBuffer::FUN_009d2220 (sro_client.exe)
// reads one byte for each set bit b, low to high, with (1 << b) & 0x17fefc0
// -- every non-elemental state that has an applier, not the elemental six,
// not 12 and not 23. READ.
const LevelBits uint32 = 0x17fefc0
