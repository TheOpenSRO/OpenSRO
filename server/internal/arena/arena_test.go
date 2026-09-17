package arena

import "testing"

func TestFourModesEachWithAnEntryClass(t *testing.T) {
	if len(Modes) != 4 {
		t.Errorf("%d modes, want 4", len(Modes))
	}
	seen := map[Mode]bool{}
	vts := map[uint32]string{}
	for _, m := range Modes {
		if seen[m.Mode] {
			t.Errorf("mode %s listed twice", m.Mode)
		}
		seen[m.Mode] = true
		if m.MatchVTable == m.EntryVTable {
			t.Errorf("mode %s: the match and entry classes share a vtable", m.Mode)
		}
		for _, vt := range []uint32{m.MatchVTable, m.EntryVTable} {
			if prev, dup := vts[vt]; dup {
				t.Errorf("vtable %#x is claimed by both %s and %s", vt, prev, m.Mode)
			}
			vts[vt] = string(m.Mode)
		}
		// Every pair is 0x30 apart in .rdata, entry first -- they are laid out
		// as adjacent pairs, which is what makes the pairing structural.
		if m.MatchVTable-m.EntryVTable != 0x30 {
			t.Errorf("mode %s: match and entry vtables are %#x apart, want 0x30",
				m.Mode, m.MatchVTable-m.EntryVTable)
		}
	}
}

func TestThreeScoringKinds(t *testing.T) {
	if len(Scorings) != 3 {
		t.Errorf("%d scoring kinds, want 3", len(Scorings))
	}
	for _, s := range []Scoring{ScoringOccupy, ScoringPoint, ScoringFlag} {
		if _, ok := Scorings[s]; !ok {
			t.Errorf("%s has no vtable recorded", s)
		}
	}
	// They are laid out consecutively, 0x2c apart.
	if Scorings[ScoringPoint]-Scorings[ScoringOccupy] != 0x2c ||
		Scorings[ScoringFlag]-Scorings[ScoringPoint] != 0x2c {
		t.Error("the three scoring vtables are no longer consecutive")
	}
}

// The arena currency is an inventory item, not a scalar. That distinction is
// what a reimplementation would get wrong.
func TestArenaCoinIsAnItemKind(t *testing.T) {
	if ArenaCoinItemKind != 10 || ArenaCoinFlagBit != 0x400 {
		t.Errorf("arena coin is kind %d / bit %#x, want 10 / 0x400",
			ArenaCoinItemKind, ArenaCoinFlagBit)
	}
	if OtherCoinItemKind != 9 || OtherCoinFlagBit != 0x200 {
		t.Errorf("the neighbouring currency is kind %d / bit %#x, want 9 / 0x200",
			OtherCoinItemKind, OtherCoinFlagBit)
	}
	// The two branches are adjacent bits and adjacent kinds, which is how they
	// were told apart; if that stops holding the reading needs revisiting.
	if ArenaCoinFlagBit != OtherCoinFlagBit<<1 || ArenaCoinItemKind != OtherCoinItemKind+1 {
		t.Error("the two currency branches are no longer adjacent")
	}
}

func TestRefusalCodesAreDistinct(t *testing.T) {
	seen := map[int]bool{}
	for _, c := range []int{ErrNotEnoughArenaCoin, ErrNotEnoughCoin, ErrCantPartyWithOpponent} {
		if seen[c] {
			t.Errorf("code %#x listed twice", c)
		}
		seen[c] = true
	}
	if len(seen) != 3 {
		t.Errorf("%d distinct codes, want 3", len(seen))
	}
}

func TestWorldIsSeparate(t *testing.T) {
	if WorldSlots != 55 {
		t.Errorf("the arena world has %d slots, want 55", WorldSlots)
	}
	if WorldClass == "" || ContextController == "" {
		t.Error("the world and controller class names must stay recorded")
	}
}
