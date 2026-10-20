package jobs

import "testing"

// The join's order (kind, the guild's NPC, then the level) is the session
// handler's (session/jobguild.go jobJoin, tested in job799_test.go).
func TestMinJobLevel(t *testing.T) {
	if MinJobLevel != 0x14 {
		t.Errorf("MinJobLevel is %d; the comparison is `< 0x14`", MinJobLevel)
	}
	if Kind(0).Valid() || Kind(4).Valid() {
		t.Error("kinds 0 and 4 are refused 0x4828")
	}
}

// Kind 1's id is 20 and MinJobLevel is 20, and they are different things. This
// test exists to make that explicit rather than to check arithmetic.
func TestKindIDsAreNotLevels(t *testing.T) {
	for _, c := range []struct {
		k  Kind
		id int
	}{{KindA, 0x14}, {KindB, 0x15}, {KindC, 0x16}} {
		id, ok := c.k.ID()
		if !ok || id != c.id {
			t.Errorf("kind %d maps to %#x (ok=%v), want %#x", c.k, id, ok, c.id)
		}
	}
	idA, _ := KindA.ID()
	if idA != MinJobLevel {
		t.Skip("the coincidence this test documents has gone away")
	}
	// They are equal, and that is a coincidence, not a relationship.
	if KindB.Valid() != true || KindC.Valid() != true {
		t.Error("kinds 2 and 3 must stay valid")
	}
	for _, k := range []Kind{0, 4, 5, 255} {
		if k.Valid() {
			t.Errorf("kind %d should be rejected", k)
		}
	}
}

func TestFleaMarketSlots(t *testing.T) {
	if FleaMarketSlots != 8 {
		t.Errorf("FleaMarketSlots is %d, want 8", FleaMarketSlots)
	}
}

func TestRefusalCodesAreDistinct(t *testing.T) {
	seen := map[int]bool{}
	for _, c := range []int{
		ErrSpecialtyNotTrade, ErrOnlyTraderCanBuy, ErrJobGuildNotFound,
		ErrJobGuildLevel, ErrUnknownJobKind, ErrFleaMarketFull,
		ErrFleaMarketHostLeft, ErrFleaMarketHostClose,
	} {
		if seen[c] {
			t.Errorf("code %#x listed twice", c)
		}
		seen[c] = true
	}
	if len(seen) != 8 {
		t.Errorf("%d distinct codes, want 8", len(seen))
	}
	if len(Procs) != 7 {
		t.Errorf("%d procedures, want 7", len(Procs))
	}
}
