package grounditem

import (
	"testing"
	"time"
)

func newTestHub(start time.Time) (*Hub, *time.Time) {
	now := start
	h := NewHub()
	h.now = func() time.Time { return now }
	return h, &now
}

func TestDropAndListByZone(t *testing.T) {
	h, _ := newTestHub(time.Unix(1000, 0))
	a := h.Drop("jangan", 4, 2, false, 1, 0, 2, 7)
	h.Drop("donwhang", 11, 1, false, 5, 0, 5, 7)
	got := h.InZone("jangan")
	if len(got) != 1 || got[0].ID != a.ID || got[0].ItemID != 4 || got[0].Quantity != 2 {
		t.Fatalf("InZone(jangan) = %+v, want just item %d (4 x2)", got, a.ID)
	}
	if _, ok := h.Get(a.ID); !ok {
		t.Fatalf("Get(%d) missing", a.ID)
	}
}

// PickRange is the engine's 10.0 (.rdata 0xb45b44) on a plain 3-D distance:
// 9.9 away picks, 10.1 away is refused with error 4.
func TestPickRangeIsTenUnitsEuclidean(t *testing.T) {
	h, _ := newTestHub(time.Unix(1000, 0))
	it := h.Drop("jangan", 4, 1, false, 0, 0, 0, 7)
	if _, code := h.PickCheck(it.ID, 7, 0, 0, 10.1, nil); code != ErrTooFar {
		t.Fatalf("10.1 away: code %#x, want ErrTooFar (4)", code)
	}
	if _, code := h.PickCheck(it.ID, 7, 6, 0, 8, nil); code != 0 { // sqrt(36+64) = 10.0
		t.Fatalf("exactly 10 away: code %#x, want 0", code)
	}
}

// Ownership: the owner picks inside the window, a stranger is refused
// (0x1812), and at 30 s (0xb45e58) the item is free for anyone.
func TestOwnershipWindowIsThirtySeconds(t *testing.T) {
	start := time.Unix(1000, 0)
	h, now := newTestHub(start)
	it := h.Drop("jangan", 4, 1, false, 0, 0, 0, 7)

	if _, code := h.PickCheck(it.ID, 9, 0, 0, 0, nil); code != ErrNotOwner {
		t.Fatalf("stranger inside the window: code %#x, want ErrNotOwner", code)
	}
	if got := it.OwnerAt(start.Add(29 * time.Second)); got != 7 {
		t.Fatalf("OwnerAt(29s) = %d, want 7", got)
	}
	if got := it.OwnerAt(start.Add(30 * time.Second)); got != 0 {
		t.Fatalf("OwnerAt(30s) = %d, want 0 (released)", got)
	}
	*now = start.Add(30 * time.Second)
	released := h.ReleaseOwnerships()
	if len(released) != 1 || released[0].ID != it.ID || released[0].OwnerID != 0 {
		t.Fatalf("ReleaseOwnerships at 30s = %+v, want item %d with owner 0", released, it.ID)
	}
	if again := h.ReleaseOwnerships(); len(again) != 0 {
		t.Fatalf("second ReleaseOwnerships returned %d items, want 0 (each once)", len(again))
	}
	if _, code := h.PickCheck(it.ID, 9, 0, 0, 0, nil); code != 0 {
		t.Fatalf("stranger after the window: code %#x, want 0", code)
	}
}

// A party member may pick an owned drop when the party shares items.
func TestPartyMemberMayPickWhenSharing(t *testing.T) {
	h, _ := newTestHub(time.Unix(1000, 0))
	it := h.Drop("jangan", 4, 1, false, 0, 0, 0, 7)
	shares := func(a, b int64) bool { return (a == 7 && b == 8) || (a == 8 && b == 7) }
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 0, shares); code != 0 {
		t.Fatalf("party member with sharing: code %#x, want 0", code)
	}
	h.Release(it.ID)
	if _, code := h.PickCheck(it.ID, 9, 0, 0, 0, shares); code != ErrNotOwner {
		t.Fatalf("non-member: code %#x, want ErrNotOwner", code)
	}
}

// A pick in progress marks the item busy (CGItem+0x14c): a second picker
// gets 0x1813 until the first pick is released or completed.
func TestBusyFlag(t *testing.T) {
	h, _ := newTestHub(time.Unix(1000, 0))
	it := h.Drop("jangan", 4, 1, false, 0, 0, 0, 0)
	if _, code := h.PickCheck(it.ID, 7, 0, 0, 0, nil); code != 0 {
		t.Fatalf("first pick: code %#x", code)
	}
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 0, nil); code != ErrBusy {
		t.Fatalf("second pick while busy: code %#x, want ErrBusy", code)
	}
	h.Release(it.ID)
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 0, nil); code != 0 {
		t.Fatalf("after release: code %#x, want 0", code)
	}
	if _, ok := h.Remove(it.ID); !ok {
		t.Fatal("Remove: missing")
	}
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 0, nil); code != ErrCannotPick {
		t.Fatalf("after removal: code %#x, want ErrCannotPick", code)
	}
}

// Without reference data every drop gets the disclosed fallback.
func TestExpireAfterFallbackLifetime(t *testing.T) {
	start := time.Unix(1000, 0)
	h, now := newTestHub(start)
	old := h.Drop("jangan", 4, 1, false, 0, 0, 0, 0)
	*now = start.Add(FallbackLifetime - time.Second)
	fresh := h.Drop("jangan", 4, 1, false, 0, 0, 0, 0)
	if gone := h.Expire(); len(gone) != 0 {
		t.Fatalf("Expire before lifetime removed %d, want 0", len(gone))
	}
	*now = start.Add(FallbackLifetime)
	gone := h.Expire()
	if len(gone) != 1 || gone[0].ID != old.ID {
		t.Fatalf("Expire at lifetime = %+v, want just %d", gone, old.ID)
	}
	if _, ok := h.Get(fresh.ID); !ok {
		t.Fatal("fresh item expired too early")
	}
}

// With reference data, each drop lives for ITS row's DecayTime (itemdata
// column 13, milliseconds): the engine's rule, in which an ordinary 10 s drop
// is gone before its 30 s ownership window ends, and a row with no DecayTime
// (0) still gets the fallback.
func TestExpireUsesEachItemsOwnDecayTime(t *testing.T) {
	start := time.Unix(1000, 0)
	h, now := newTestHub(start)
	h.SetDecayLookup(func(itemID int64) int {
		switch itemID {
		case 3: // gold
			return 10000
		case 500: // a 3-minute item
			return 180000
		}
		return 0 // unknown / old export
	})
	gold := h.Drop("jangan", 3, 57, true, 0, 0, 0, 42)
	long := h.Drop("jangan", 500, 1, false, 0, 0, 0, 42)
	unknown := h.Drop("jangan", 999, 1, false, 0, 0, 0, 42)
	if got := gold.ExpiresAt.Sub(gold.DroppedAt); got != 10*time.Second {
		t.Fatalf("gold lifetime %v, want 10s", got)
	}
	if got := long.ExpiresAt.Sub(long.DroppedAt); got != 180*time.Second {
		t.Fatalf("180000 ms item lifetime %v, want 3m", got)
	}
	if got := unknown.ExpiresAt.Sub(unknown.DroppedAt); got != FallbackLifetime {
		t.Fatalf("unknown item lifetime %v, want the fallback %v", got, FallbackLifetime)
	}

	*now = start.Add(10 * time.Second)
	gone := h.Expire()
	if len(gone) != 1 || gone[0].ID != gold.ID {
		t.Fatalf("at 10 s Expire = %+v, want just the gold %d", gone, gold.ID)
	}
	// The gold vanished while still owned: the window (30 s) outlasts it.
	if gold.OwnerAt(start.Add(10*time.Second)) != 42 {
		t.Fatal("gold should still have been reserved for its owner when it vanished")
	}
	*now = start.Add(180 * time.Second)
	gone = h.Expire()
	if len(gone) != 2 || gone[0].ID != long.ID || gone[1].ID != unknown.ID {
		t.Fatalf("at 180 s Expire = %+v, want the 3-minute item and the fallback one", gone)
	}
}
