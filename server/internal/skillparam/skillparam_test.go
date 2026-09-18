package skillparam

import (
	"slices"
	"testing"
)

// TestPhysDamageFieldMatchesTheFormula is the cross-check that makes the rest of
// the table credible: Formulae::Formula_SkillPhysDamage was annotated, from a
// different function and an earlier session, as being called "when the skill
// carries 'pdmg' (skill+0x234)". This table was built by walking
// RefSkill_ParseParams' branches without reference to that.
func TestPhysDamageFieldMatchesTheFormula(t *testing.T) {
	if PhysDamageField != 0x234 {
		t.Fatalf("PhysDamageField = %#x, want 0x234 -- the formula's own annotation", PhysDamageField)
	}
	if !slices.Contains(Codes, PhysDamage) {
		t.Fatalf("%q is not in Codes; it is the one code tied to a formula", PhysDamage)
	}
}

// TestCodesAreFourCharacters keeps the table honest about what a code is: the
// dispatcher compares 32-bit multi-character literals, so every key is exactly
// four printable characters. A truncated or mis-decoded key would show here --
// the stat-tag table was published twice with three-byte truncation before that
// was caught.
func TestCodesAreFourCharacters(t *testing.T) {
	for _, c := range Codes {
		if len(c) < 2 || len(c) > 4 {
			t.Errorf("code %q has %d characters; the dispatcher compares two to four", c, len(c))
		}
		for _, r := range c {
			if r < 0x21 || r > 0x7e {
				t.Errorf("code %q holds a non-printable character %q", c, r)
			}
		}
	}
}

// TestCodesAreDistinctAndPlausiblyComplete keeps the list from silently shrinking
// or gaining a duplicate if it is ever regenerated.
func TestCodesAreDistinctAndPlausiblyComplete(t *testing.T) {
	seen := map[Code]bool{}
	for _, c := range Codes {
		if seen[c] {
			t.Errorf("code %q appears twice", c)
		}
		seen[c] = true
	}
	if len(Codes) < 180 {
		t.Errorf("only %d codes; the parser compares 187 distinct two-to-four-character immediates "+
			"and an earlier four-character-only decoder wrongly reported 156", len(Codes))
	}
	// 'att' is the code export-refdata reads a skill's damage from, and it is
	// three characters -- exactly what the first decoder dropped.
	if !slices.Contains(Codes, Code("att")) {
		t.Error("'att' is missing; a length assumption in the decoder dropped the short codes once already")
	}
}

// TestFieldOffsetsAreDistinct is the guard that caused the first version of this
// table to be withheld: two codes resolving to one offset means a branch walk ran
// past its leaf into the next one. It is kept because it is the only thing that
// detects that failure -- the table looked entirely plausible with the bad row in
// it, and the pdmg cross-check passed anyway.
func TestFieldOffsetsAreDistinct(t *testing.T) {
	seen := map[int]Code{}
	for c, off := range Field {
		if prev, dup := seen[off]; dup {
			t.Errorf("codes %q and %q both resolve to skill+%#x; a leaf walk overran", prev, c, off)
		}
		seen[off] = c
	}
}

// TestEveryFieldKeyIsAKnownCode stops the map and the list drifting apart.
func TestEveryFieldKeyIsAKnownCode(t *testing.T) {
	known := map[Code]bool{}
	for _, c := range Codes {
		known[c] = true
	}
	for c := range Field {
		if !known[c] {
			t.Errorf("Field has %q, which is not in Codes", c)
		}
	}
	// Exactly one code has no field, and it is 'getv', which genuinely has
	// none: it is a two-word prefix whose SECOND word selects the field, so
	// its 40 fields live in GetvSub rather than here.
	//
	// This used to be three. 'att' and 'setv' were unresolved because their
	// branches do not store the way the others do -- 'att' stores through the
	// _Dst pointer the prologue set to skill+0x230, and 'setv' scans a
	// five-slot array at 0x388 for the first free one. Reading the parser's
	// dispatch tree rather than each leaf in isolation resolves both; see
	// paramblock.go.
	var missing []Code
	for _, c := range Codes {
		if _, ok := Field[c]; !ok {
			missing = append(missing, c)
		}
	}
	if len(missing) != 1 || missing[0] != "getv" {
		t.Errorf("codes without a field: %v; expected exactly [getv]", missing)
	}
}

// TestDrivesParamsAgreesWithTheStatTags is the cross-check that makes the rest
// of DrivesParams credible. These five come from a different function, read
// before this table existed, and the two readings agree.
func TestDrivesParamsAgreesWithTheStatTags(t *testing.T) {
	for _, c := range []struct {
		code  Code
		param int
	}{{"stri", 1}, {"inti", 2}, {"hpi", 3}, {"mpi", 4}} {
		got, ok := DrivesParams[c.code]
		if !ok || len(got) != 1 || got[0] != c.param {
			t.Errorf("DrivesParams[%q] = %v (present %v), want [%d] -- the stat tags "+
				"give the same param to the matching tag", c.code, got, ok, c.param)
		}
	}
}

// TestBgraDrivesTheWholeResistRun ties this table to a separately recovered one:
// 'bgra' must write exactly the six params 'rals' (MATTR_RESIST_ALL_SET) writes.
// If either changes without the other, one of them is wrong.
func TestBgraDrivesTheWholeResistRun(t *testing.T) {
	got, ok := DrivesParams["bgra"]
	if !ok {
		t.Fatal("'bgra' is absent; it is the entry tying this table to the resist run")
	}
	want := []int{27, 28, 29, 30, 31, 32} // combat.ResistParams, duplicated to avoid an import cycle
	if len(got) != len(want) {
		t.Fatalf("'bgra' drives %v, want the resist run %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("'bgra' drives %v, want the resist run %v", got, want)
		}
	}
}

// TestDrivesParamsKeysAreKnownCodes keeps this table from drifting from Codes.
func TestDrivesParamsKeysAreKnownCodes(t *testing.T) {
	for c := range DrivesParams {
		if !slices.Contains(Codes, c) {
			t.Errorf("DrivesParams has %q, which is not a code the parser recognises", c)
		}
	}
}

// TestFlatAndRatioPairsShareTheirParams is the structural check that makes
// Contributions credible: the binary pairs a flat code with a ratio code over
// the same params, and nothing in the extraction assumed that. If a slot were
// misread the pairing would break.
func TestFlatAndRatioPairsShareTheirParams(t *testing.T) {
	for _, p := range []struct{ flat, ratio Code }{{"apau", "apru"}, {"defp", "defr"}} {
		f, ok1 := Contributions[p.flat]
		r, ok2 := Contributions[p.ratio]
		if !ok1 || !ok2 {
			t.Fatalf("%q/%q: one of the pair is missing", p.flat, p.ratio)
		}
		flatParams := map[int]bool{}
		for _, c := range f {
			if c.Slot != SlotBase {
				t.Errorf("%q writes param %d in slot %d, want the base slot", p.flat, c.Param, c.Slot)
			}
			flatParams[c.Param] = true
		}
		// every param the flat code touches must also be touched by the ratio
		// code, through the percentage slot.
		for param := range flatParams {
			found := false
			for _, c := range r {
				if c.Param == param && c.Slot == SlotPct {
					found = true
				}
			}
			if !found {
				t.Errorf("%q covers param %d but %q does not cover it in the percentage slot",
					p.flat, param, p.ratio)
			}
		}
	}
}

// TestContributionsAgreeWithDrivesParams keeps the two views of one reading
// from drifting apart.
func TestContributionsAgreeWithDrivesParams(t *testing.T) {
	for code, cs := range Contributions {
		want := map[int]bool{}
		for _, p := range DrivesParams[code] {
			want[p] = true
		}
		for _, c := range cs {
			if !want[c.Param] {
				t.Errorf("Contributions[%q] has param %d, absent from DrivesParams", code, c.Param)
			}
		}
	}
}

// TestSlotsAreInRange guards the slot read: ParamKeeper_EvaluateParam combines
// exactly four accumulators, so anything outside 0..3 means the wrong push was
// taken for the argument.
func TestSlotsAreInRange(t *testing.T) {
	for code, cs := range Contributions {
		for _, c := range cs {
			if c.Slot < SlotBase || c.Slot > SlotScale {
				t.Errorf("Contributions[%q] uses slot %d; the keeper has four", code, c.Slot)
			}
		}
	}
}

// TestPhysDamageInputsMatchTheCallSite pins the two parameters
// Formula_SkillPhysDamage is actually handed. Combat_ResolveDamage reads
// skill+0x234 into ECX as the base and skill+0x538 as the bonus selector; if
// either constant drifts from the Field table, the formula's inputs are wrong.
func TestPhysDamageInputsMatchTheCallSite(t *testing.T) {
	if PhysDamageField != 0x234 {
		t.Errorf("PhysDamageField = %#x, want 0x234 -- the offset ECX is loaded from", PhysDamageField)
	}
	if PhysDamageBonusField != 0x538 {
		t.Errorf("PhysDamageBonusField = %#x, want 0x538 -- the offset EAX is loaded from", PhysDamageBonusField)
	}
	if got := Field[PhysDamage]; got != PhysDamageField {
		t.Errorf("Field[%q] = %#x, want %#x", PhysDamage, got, PhysDamageField)
	}
	if got := Field[PhysDamageBonus]; got != PhysDamageBonusField {
		t.Errorf("Field[%q] = %#x, want %#x", PhysDamageBonus, got, PhysDamageBonusField)
	}
	if PhysDamage == PhysDamageBonus {
		t.Error("the base and the bonus selector are two different parameters")
	}
}

// TestAltDamageInputsMatchTheCallSite pins the second skill-damage formula's
// inputs the same way the physical one's are pinned. Combat_ResolveDamage tests
// skill+0x400 first and only falls through to the pdmg path when it is zero.
func TestAltDamageInputsMatchTheCallSite(t *testing.T) {
	for _, c := range []struct {
		code  Code
		field int
	}{{AltDamage, AltDamageField}, {AltDamageExtra, AltDamageExtraField}, {AltDamageBonus, AltDamageBonusField}} {
		got, ok := Field[c.code]
		if !ok || got != c.field {
			t.Errorf("Field[%q] = %#x (present %v), want %#x", c.code, got, ok, c.field)
		}
	}
	// The two formulas must not share inputs: they are alternatives, and the
	// selector being the same field would mean one of the reads is wrong.
	if AltDamage == PhysDamage || AltDamageField == PhysDamageField {
		t.Error("the two skill-damage formulas must take different base parameters")
	}
}

// TestTimedEffectCodesMatchTheFieldsQueued pins the eight parameters
// QueueTimedSkillEffect copies, by the offsets it reads them from.
func TestTimedEffectCodesMatchTheFieldsQueued(t *testing.T) {
	want := map[Code]int{
		"pmhp": 0x338, "pmmp": 0x33c, "pmdg": 0x340, "pmdp": 0x344,
		"php1": 0x348, "pmp1": 0x34c, "pao": 0x350, "pcdu": 0x364,
	}
	if len(TimedEffectCodes) != len(want) {
		t.Fatalf("TimedEffectCodes has %d entries, want %d", len(TimedEffectCodes), len(want))
	}
	for _, c := range TimedEffectCodes {
		off, expected := want[c]
		if !expected {
			t.Errorf("%q is not one of the eight the function queues", c)
			continue
		}
		if got := Field[c]; got != off {
			t.Errorf("Field[%q] = %#x, want %#x -- the offset the function reads", c, got, off)
		}
	}
	// 'pmdg' belongs here and NOT to a damage formula: it is not the magical
	// counterpart of 'pdmg', which an earlier note in this project claimed.
	if PhysDamage == "pmdg" || AltDamage == "pmdg" {
		t.Error("'pmdg' is a timed-effect parameter, not a damage-formula base")
	}
}

// TestTimedEffectLayoutIsSelfConsistent pins the record layout the queue and
// tick functions agree on. The eight pointers are contiguous with stride 4, so
// the last one must land where the queue writes it.
func TestTimedEffectLayoutIsSelfConsistent(t *testing.T) {
	last := TimedEffectFirstParamPtr + 4*(len(TimedEffectCodes)-1)
	if last != 0x30 {
		t.Errorf("the eighth parameter pointer lands at %#x, want 0x30 -- the queue writes +0x14..+0x30", last)
	}
	if TimedEffectStartTickOffset >= TimedEffectFirstParamPtr {
		t.Error("the start tick is written before the parameter pointers in the record")
	}
	if TimedEffectDurationOffset != 0 {
		t.Errorf("the duration is the parameter record's first dword, got %#x", TimedEffectDurationOffset)
	}
	if TimedEffectModeOffset != 0x0c {
		t.Errorf("the mode is field [3], %#x, got %#x", 0x0c, TimedEffectModeOffset)
	}
}
