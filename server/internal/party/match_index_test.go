package party

import (
	"testing"
	"time"
)

// TestListingOwnerFollowsTheListings: the Hub's entry index (ListingOwner's
// lookup) follows a registration, a leader's departure (the entry moves to
// the new leader), a dissolution (the entry goes) and a delete.
func TestListingOwnerFollowsTheListings(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	l, err := m.Register(1, entry(PurposeHunting, 1, 110, FlagExpShare))
	if err != nil {
		t.Fatal(err)
	}
	if o, ok := h.ListingOwner(l.Number); !ok || o != 1 {
		t.Fatalf("owner %d %v, want 1", o, ok)
	}
	p, err := h.Form(member(1), member(2), FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.Add(p.ID, member(3)); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Remove(1, 0); err != nil {
		t.Fatal(err)
	}
	if o, ok := h.ListingOwner(l.Number); !ok || o != 2 {
		t.Fatalf("after the leader left: owner %d %v, want 2", o, ok)
	}
	if _, err := h.Remove(3, 0); err != nil {
		t.Fatal(err)
	}
	if o, ok := h.ListingOwner(l.Number); ok {
		t.Fatalf("a dissolved party's entry still has owner %d", o)
	}
	l2, err := m.Register(4, entry(PurposeHunting, 1, 110, 0))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Delete(4, l2.Number); err != nil {
		t.Fatal(err)
	}
	if _, ok := h.ListingOwner(l2.Number); ok {
		t.Fatal("a deleted entry still has an owner")
	}
}

// TestSweepOfManyEntriesIsLinear: 10,000 entries expiring in one sweep, and a
// page over 10,000, finish quickly (each was O(entries^2) through a
// ListingOwner scan: about 50 M map steps under the Hub's lock; MEASURED
// on a 16-thread box, a 339 ms page and a 222 ms sweep before, 3.9 ms and
// 1.8 ms after).
func TestSweepOfManyEntriesIsLinear(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	const n = 10000
	for c := int64(1); c <= n; c++ {
		if _, err := m.Register(c, entry(PurposeHunting, 1, 110, 0)); err != nil {
			t.Fatal(err)
		}
	}
	start := time.Now()
	pages, _, rows, err := m.Page(1, 3, allOnline, race0)
	if err != nil || pages != MaxPages || len(rows) != PageSize+1 {
		t.Fatalf("page: %d pages, %d rows, %v", pages, len(rows), err)
	}
	pageTook := time.Since(start)
	gone := m.Sweep(m.Now().Add((ExpireAfterMinutes + 1) * time.Minute))
	if len(gone) != n {
		t.Fatalf("swept %d, want %d", len(gone), n)
	}
	t.Logf("page over %d: %s; sweep of %d: %s", n, pageTook, n, time.Since(start)-pageTook)
	if d := time.Since(start); d > 250*time.Millisecond { // the old scan: 560 ms here
		t.Fatalf("a page and a sweep over %d entries took %s", n, d)
	}
}
