package trade

import (
	"sync"
	"testing"
)

func openTrade(t *testing.T) *Hub {
	t.Helper()
	h := NewHub()
	a, b := Member{CharacterID: 1, Name: "Aria"}, Member{CharacterID: 2, Name: "Bram"}
	if _, err := h.Request(a, b); err != nil {
		t.Fatalf("Request: %v", err)
	}
	if _, err := h.Respond(b, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	return h
}

// Round 743: both-confirmed is answered once per trade, however many
// confirms race -- the executing latch. Before it, every confirm after both
// sides had confirmed answered true, and each ran the trade.
func TestConfirmLatchesOnce(t *testing.T) {
	for trial := 0; trial < 50; trial++ {
		h := openTrade(t)
		if _, both, err := h.Confirm(1); err != nil || both {
			t.Fatalf("Aria's first confirm: both=%v err=%v", both, err)
		}
		var wg sync.WaitGroup
		var mu sync.Mutex
		latched := 0
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				_, both, err := h.Confirm(int64(1 + i%2))
				if err != nil {
					t.Errorf("Confirm: %v", err)
				}
				if both {
					mu.Lock()
					latched++
					mu.Unlock()
				}
			}(i)
		}
		wg.Wait()
		if latched != 1 {
			t.Fatalf("trial %d: %d confirms answered both-confirmed, want 1", trial, latched)
		}
	}
}

// While the trade executes, the offers cannot change and a cancel cannot end
// it; Finish does.
func TestExecutingTradeHoldsUntilFinish(t *testing.T) {
	h := openTrade(t)
	if _, err := h.SetOffer(1, Offer{Gold: 5, ItemSlot: -1}); err != nil {
		t.Fatalf("SetOffer: %v", err)
	}
	h.Confirm(1)
	snap, both, _ := h.Confirm(2)
	if !both || snap.OfferA.Gold != 5 || snap.ID == 0 {
		t.Fatalf("latching confirm: both=%v snapshot=%+v", both, snap)
	}
	if _, err := h.SetOffer(1, Offer{Gold: 500, ItemSlot: -1}); err != ErrExecuting {
		t.Fatalf("SetOffer while executing: %v, want ErrExecuting", err)
	}
	if snap.OfferA.Gold != 5 {
		t.Fatalf("the executor's snapshot changed: %+v", snap.OfferA)
	}
	if _, ok := h.End(2); ok {
		t.Fatal("End ended a trade being executed")
	}
	if !h.Established(1) {
		t.Fatal("the trade vanished while executing")
	}
	h.Finish(1)
	if h.Established(1) || h.Established(2) || h.Busy(1) || h.Busy(2) {
		t.Fatal("Finish left the trade open")
	}
}
