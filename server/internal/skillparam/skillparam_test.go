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
