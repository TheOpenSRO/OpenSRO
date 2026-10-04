package party

import (
	"bytes"
	"testing"
)

// 0x3068 against the golden fixtures (round 712).
func TestItemNoticeFixtures(t *testing.T) {
	for _, c := range []struct {
		file string
		n    ItemNotice
	}{
		{"3068_expendable", ItemNotice{RecipientJID: 201, RefItemID: 62, Class: ItemNoticeExpendable, Amount: 5}},
		{"3068_other", ItemNotice{RecipientJID: 101, RefItemID: 3617, Class: ItemNoticeOther, Amount: 1}},
		{"3068_gold", ItemNotice{RecipientJID: 201, RefItemID: 1, Class: ItemNoticeGold, Amount: 1234}},
	} {
		want := fixture(t, c.file)
		if got := c.n.Encode(); !bytes.Equal(got, want) {
			t.Errorf("%s: encoded % x, want % x", c.file, got, want)
		}
		back, err := DecodeItemNotice(want, c.n.Class)
		if err != nil || back != c.n {
			t.Errorf("%s: decoded %+v, %v; want %+v", c.file, back, err, c.n)
		}
	}
}

// The item round robin (GObjPC::FUN_004d4840): front to back; a joiner at the
// back; a leaver out.
func TestNextInRotation(t *testing.T) {
	h := NewHub()
	p, err := h.Form(Member{CharacterID: 1, Level: 10}, Member{CharacterID: 2, Level: 10}, FlagItemShare|FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.Add(p.ID, Member{CharacterID: 3}); err != nil {
		t.Fatal(err)
	}
	var got []int64
	for i := 0; i < 4; i++ {
		id, _ := h.NextInRotation(p.ID)
		got = append(got, id)
	}
	if want := []int64{1, 2, 3, 1}; !equalIDs(got, want) {
		t.Fatalf("rotation %v, want %v", got, want)
	}
	if _, err := h.Remove(2, ReasonLeave); err != nil {
		t.Fatal(err)
	}
	got = got[:0]
	for i := 0; i < 3; i++ {
		id, _ := h.NextInRotation(p.ID)
		got = append(got, id)
	}
	// After 1,2,3,1 the list was 2,3,1; 2 left: 3,1.
	if want := []int64{3, 1, 3}; !equalIDs(got, want) {
		t.Fatalf("after a leave %v, want %v", got, want)
	}
	if _, ok := h.NextInRotation(999); ok {
		t.Fatal("a party that does not exist answered")
	}
}

func equalIDs(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
