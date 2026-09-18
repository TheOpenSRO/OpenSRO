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
		if len(c) != 4 {
			t.Errorf("code %q has %d characters; the dispatcher compares four", c, len(c))
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
	if len(Codes) < 150 {
		t.Errorf("only %d codes; the parser compares 156 distinct four-character immediates", len(Codes))
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
	// The two absences are deliberate and named, so a silent third one is a bug.
	var missing []Code
	for _, c := range Codes {
		if _, ok := Field[c]; !ok {
			missing = append(missing, c)
		}
	}
	if len(missing) != 2 {
		t.Errorf("codes without a field: %v; expected exactly getv and setv, whose branches loop", missing)
	}
	for _, c := range missing {
		if c != "getv" && c != "setv" {
			t.Errorf("%q has no field but is not one of the two known loop branches", c)
		}
	}
}
