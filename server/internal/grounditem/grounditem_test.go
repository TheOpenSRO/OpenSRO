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
	// Gone: CheckCanPickUp's opening `*param_2 = 3` is what an id that
	// resolves to no object answers -- not 0x1839, which is CanPick's.
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 0, nil); code != ErrNotThere {
		t.Fatalf("after removal: code %#x, want ErrNotThere (3)", code)
	}
}

// The engine tests the range BEFORE the busy flag (CheckCanPickUp: result 4
// at the distance compare, 0x1813 only after the life-state test), so a
// second picker standing too far from an item already being picked hears
// "too far", and one in reach hears "busy".
func TestRangeIsTestedBeforeBusy(t *testing.T) {
	h, _ := newTestHub(time.Unix(1000, 0))
	it := h.Drop("jangan", 4, 1, false, 0, 0, 0, 0)
	if _, code := h.PickCheck(it.ID, 7, 0, 0, 0, nil); code != 0 {
		t.Fatalf("first pick: code %#x", code)
	}
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 50, nil); code != ErrTooFar {
		t.Fatalf("second picker 50 away while busy: code %#x, want ErrTooFar (4)", code)
	}
	if _, code := h.PickCheck(it.ID, 8, 0, 0, 1, nil); code != ErrBusy {
		t.Fatalf("second picker in reach while busy: code %#x, want ErrBusy", code)
	}
}

// An item whose row clears CanPick (itemdata column 21, flags bit 5) is
// refused 0x1839 by CheckCanPickUp's first test on a found item -- vtable
// slot 53, CGObj::CanPick 0x00483e50 -- which comes before the range, the
// busy flag and the owner. So its owner standing on it is refused, a
// stranger 500 units away hears 0x1839 rather than "too far" or "not
// yours", and a repeat is still 0x1839 (a refused pick never marks the item
// busy). A pickable item beside it is unaffected, and a hub with no lookup
// refuses nothing.
func TestCanPickClearRefusesBeforeRangeBusyAndOwner(t *testing.T) {
	h, _ := newTestHub(time.Unix(1000, 0))
	h.SetPickLookup(func(itemID int64) bool { return itemID != 99 })
	bad := h.Drop("jangan", 99, 1, false, 0, 0, 0, 7)
	ok := h.Drop("jangan", 4, 1, false, 0, 0, 0, 7)

	if _, code := h.PickCheck(bad.ID, 7, 0, 0, 0, nil); code != ErrCannotPick {
		t.Fatalf("owner on a CanPick=0 item: code %#x, want ErrCannotPick (0x1839)", code)
	}
	if _, code := h.PickCheck(bad.ID, 8, 0, 0, 500, nil); code != ErrCannotPick {
		t.Fatalf("stranger 500 away from a CanPick=0 item: code %#x, want ErrCannotPick, not ErrTooFar or ErrNotOwner", code)
	}
	if _, code := h.PickCheck(bad.ID, 7, 0, 0, 0, nil); code != ErrCannotPick {
		t.Fatalf("repeat on a CanPick=0 item: code %#x, want ErrCannotPick, not ErrBusy", code)
	}
	if _, code := h.PickCheck(ok.ID, 7, 0, 0, 0, nil); code != 0 {
		t.Fatalf("owner on a pickable item: code %#x, want 0", code)
	}

	plain, _ := newTestHub(time.Unix(1000, 0))
	it := plain.Drop("jangan", 99, 1, false, 0, 0, 0, 7)
	if _, code := plain.PickCheck(it.ID, 7, 0, 0, 0, nil); code != 0 {
		t.Fatalf("no pick lookup: code %#x, want 0 (every drop pickable)", code)
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

// An untradeable drop keeps its owner past the 30 s window, until it decays:
// GObjPC::FUN_004901c0 (0x004901c0) asks CGObj::CanTrade (slot 49, 0x00483d50)
// before it clears +0x150 and sends 0x304D, and does neither on 0. A tradeable
// drop and one the reference data does not know are released as before.
//
// Item 500 stands for an untradeable item OUTSIDE TypeID 3/3/9 -- one of the
// 97 bound ITEM_QNO_ rows with TypeID3 13, 1, 2 or 3, such as
// ITEM_QNO_CH_EUROPE_1_02 (3/3/13) -- because for that class the engine's
// party rule really applies and the party-member assertion below is the
// engine's answer. For a 3/3/9 item (736 of the 833 bound rows) the engine
// refuses a party member 0x1812 at 0x4a934d, before the party test; srrevamp
// does not model that (PickCheck, docs/protocol/ground_items.md "Picking up"
// step 3), so no assertion here covers it.
func TestBoundDropStaysReservedPastWindow(t *testing.T) {
	start := time.Unix(1000, 0)
	h, now := newTestHub(start)
	h.SetTradeLookup(func(itemID int64) (bool, bool) {
		switch itemID {
		case 500: // untradeable, not TypeID 3/3/9: CanTrade clear
			return false, true
		case 4: // HP_POTION_01: CanTrade set
			return true, true
		}
		return true, false // not in the reference data
	})
	bound := h.Drop("jangan", 500, 1, false, 0, 0, 0, 7)
	free := h.Drop("jangan", 4, 1, false, 0, 0, 0, 7)
	unknown := h.Drop("jangan", 999, 1, false, 0, 0, 0, 7)
	if !bound.Bound || free.Bound || unknown.Bound {
		t.Fatalf("Bound: untradeable %v, potion %v, unknown %v; want true, false, false",
			bound.Bound, free.Bound, unknown.Bound)
	}

	*now = start.Add(31 * time.Second)
	released := h.ReleaseOwnerships()
	if len(released) != 2 || released[0].ID != free.ID || released[1].ID != unknown.ID {
		t.Fatalf("ReleaseOwnerships at 31 s = %+v, want just the potion %d and the unknown %d",
			released, free.ID, unknown.ID)
	}
	if got := bound.OwnerAt(*now); got != 7 {
		t.Fatalf("bound OwnerAt(31 s) = %d, want 7 (never released)", got)
	}
	if cur, _ := h.Get(bound.ID); cur.OwnerID != 7 || cur.OwnerAt(*now) != 7 {
		t.Fatalf("bound item on the ground after the sweep: owner %d / OwnerAt %d, want 7",
			cur.OwnerID, cur.OwnerAt(*now))
	}
	if _, code := h.PickCheck(bound.ID, 9, 0, 0, 0, nil); code != ErrNotOwner {
		t.Fatalf("stranger on a bound drop at 31 s: code %#x, want ErrNotOwner", code)
	}
	// The party rule (CheckCanPickUp 0x4a9360: same PartyID, flags & 2),
	// which the engine reaches for this non-3/3/9 item.
	shares := func(a, b int64) bool { return (a == 7 && b == 8) || (a == 8 && b == 7) }
	if _, code := h.PickCheck(bound.ID, 8, 0, 0, 0, shares); code != 0 {
		t.Fatalf("party member on a bound non-3/3/9 drop at 31 s: code %#x, want 0", code)
	}
	h.Release(bound.ID)
	if _, code := h.PickCheck(bound.ID, 7, 0, 0, 0, nil); code != 0 {
		t.Fatalf("owner on a bound drop at 31 s: code %#x, want 0", code)
	}
	h.Release(bound.ID)
	if _, code := h.PickCheck(free.ID, 9, 0, 0, 0, nil); code != 0 {
		t.Fatalf("stranger on the released potion at 31 s: code %#x, want 0", code)
	}

	*now = start.Add(60 * time.Second)
	if again := h.ReleaseOwnerships(); len(again) != 0 {
		t.Fatalf("ReleaseOwnerships at 60 s = %+v, want nothing (the bound drop is never released)", again)
	}
	if got := bound.OwnerAt(*now); got != 7 {
		t.Fatalf("bound OwnerAt(60 s) = %d, want 7", got)
	}
}

// Without a trade lookup nothing is Bound and every drop is released at 30 s,
// so a deployment with no reference data does not lock its drops.
func TestNoTradeLookupReleasesEverything(t *testing.T) {
	start := time.Unix(1000, 0)
	h, now := newTestHub(start)
	a := h.Drop("jangan", 500, 1, false, 0, 0, 0, 7)
	b := h.Drop("jangan", 4, 1, false, 0, 0, 0, 7)
	if a.Bound || b.Bound {
		t.Fatalf("Bound without a lookup: %v, %v; want false, false", a.Bound, b.Bound)
	}
	*now = start.Add(30 * time.Second)
	released := h.ReleaseOwnerships()
	if len(released) != 2 || released[0].ID != a.ID || released[1].ID != b.ID {
		t.Fatalf("ReleaseOwnerships at 30 s = %+v, want both drops", released)
	}
	if a.OwnerAt(*now) != 0 || b.OwnerAt(*now) != 0 {
		t.Fatal("OwnerAt(30 s) without a lookup should be 0 for every drop")
	}
	if _, code := h.PickCheck(a.ID, 9, 0, 0, 0, nil); code != 0 {
		t.Fatalf("stranger at 30 s without a lookup: code %#x, want 0", code)
	}
}
