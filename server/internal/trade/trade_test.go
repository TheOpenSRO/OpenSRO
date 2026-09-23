package trade

import (
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

func member(id int64, name string) Member {
	return Member{Session: gateway.NewTestSession(uint64(id)), CharacterID: id, Name: name}
}

func TestRequestAndRespondAccept(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Request(alice, bob); err != nil {
		t.Fatalf("Request: %v", err)
	}
	requester, err := h.Respond(bob, true)
	if err != nil {
		t.Fatalf("Respond: %v", err)
	}
	if requester.CharacterID != alice.CharacterID {
		t.Fatalf("got requester %+v, want alice", requester)
	}

	sess, ok := h.SessionOf(alice.CharacterID)
	if !ok || sess.A.CharacterID != alice.CharacterID || sess.B.CharacterID != bob.CharacterID {
		t.Fatalf("SessionOf(alice) = %+v, %v", sess, ok)
	}
	sess2, ok := h.SessionOf(bob.CharacterID)
	if !ok || sess2 != sess {
		t.Fatalf("expected both sides to share the same *Session, got %+v vs %+v", sess, sess2)
	}
	if sess.OfferA.ItemSlot != -1 || sess.OfferB.ItemSlot != -1 {
		t.Fatalf("expected fresh offers with ItemSlot=-1, got %+v / %+v", sess.OfferA, sess.OfferB)
	}
}

func TestRequestAndRespondDecline(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Request(alice, bob); err != nil {
		t.Fatalf("Request: %v", err)
	}
	if _, err := h.Respond(bob, false); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	if _, ok := h.SessionOf(alice.CharacterID); ok {
		t.Fatal("expected no active trade after decline")
	}
}

func TestRequestSelf(t *testing.T) {
	h := NewHub()
	alice := member(1, "Aria")
	if err := h.Request(alice, alice); !errors.Is(err, ErrCannotTradeSelf) {
		t.Fatalf("got %v, want ErrCannotTradeSelf", err)
	}
}

func TestRequestWhileBusy(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")

	if err := h.Request(alice, bob); err != nil {
		t.Fatalf("Request: %v", err)
	}
	if _, err := h.Respond(bob, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	if err := h.Request(alice, carol); !errors.Is(err, ErrAlreadyTrading) {
		t.Fatalf("got %v, want ErrAlreadyTrading", err)
	}
	if err := h.Request(carol, bob); !errors.Is(err, ErrTargetBusy) {
		t.Fatalf("got %v, want ErrTargetBusy", err)
	}
}

func TestSetOfferClearsConfirmations(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")
	h.Request(alice, bob)
	h.Respond(bob, true)

	if _, err := h.SetOffer(alice.CharacterID, Offer{Gold: 100, ItemSlot: -1}); err != nil {
		t.Fatalf("SetOffer: %v", err)
	}
	if _, _, err := h.Confirm(alice.CharacterID); err != nil {
		t.Fatalf("Confirm: %v", err)
	}
	sess, _ := h.SessionOf(alice.CharacterID)
	if !sess.ConfirmedA {
		t.Fatal("expected A confirmed")
	}

	// Changing the offer again should clear the confirmation.
	if _, err := h.SetOffer(alice.CharacterID, Offer{Gold: 200, ItemSlot: -1}); err != nil {
		t.Fatalf("SetOffer: %v", err)
	}
	if sess.ConfirmedA {
		t.Fatal("expected confirmation cleared after changing offer")
	}
}

func TestSetOfferInvalid(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")
	h.Request(alice, bob)
	h.Respond(bob, true)

	if _, err := h.SetOffer(alice.CharacterID, Offer{Gold: -1, ItemSlot: -1}); !errors.Is(err, ErrInvalidOffer) {
		t.Fatalf("got %v, want ErrInvalidOffer", err)
	}
}

func TestConfirmBothSides(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")
	h.Request(alice, bob)
	h.Respond(bob, true)

	_, both, err := h.Confirm(alice.CharacterID)
	if err != nil {
		t.Fatalf("Confirm: %v", err)
	}
	if both {
		t.Fatal("expected not both confirmed yet")
	}

	sess, both, err := h.Confirm(bob.CharacterID)
	if err != nil {
		t.Fatalf("Confirm: %v", err)
	}
	if !both {
		t.Fatal("expected both confirmed")
	}
	if sess.A.CharacterID != alice.CharacterID {
		t.Fatalf("unexpected session: %+v", sess)
	}
}

func TestOtherReturnsCounterpartyAndTheirOffer(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")
	h.Request(alice, bob)
	h.Respond(bob, true)
	h.SetOffer(bob.CharacterID, Offer{Gold: 50, ItemSlot: 3, Quantity: 2})

	sess, _ := h.SessionOf(alice.CharacterID)
	other, offer, ok := sess.Other(alice.CharacterID)
	if !ok || other.CharacterID != bob.CharacterID {
		t.Fatalf("Other(alice) = %+v, %v; want bob", other, ok)
	}
	if offer.Gold != 50 || offer.ItemSlot != 3 || offer.Quantity != 2 {
		t.Fatalf("unexpected offer: %+v", offer)
	}
}

func TestEnd(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")
	h.Request(alice, bob)
	h.Respond(bob, true)

	sess, ok := h.End(alice.CharacterID)
	if !ok || sess.A.CharacterID != alice.CharacterID {
		t.Fatalf("End(alice) = %+v, %v", sess, ok)
	}
	if _, ok := h.SessionOf(alice.CharacterID); ok {
		t.Fatal("expected alice no longer trading")
	}
	if _, ok := h.SessionOf(bob.CharacterID); ok {
		t.Fatal("expected bob no longer trading")
	}
}

func TestCancelPendingForTarget(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")
	h.Request(alice, bob)

	requester, notifiable := h.CancelPendingFor(bob.CharacterID)
	if !notifiable || requester.CharacterID != alice.CharacterID {
		t.Fatalf("CancelPendingFor(bob) = %+v, %v; want alice, true", requester, notifiable)
	}
	if _, err := h.Respond(bob, true); !errors.Is(err, ErrNoPendingRequest) {
		t.Fatalf("expected pending request gone, got %v", err)
	}
}

// TestHubBusyCoversEveryTradePhase pins trade.Hub.Busy / Established to the
// engine's INTERACTMODE: CTradeMgr::OpenTradeSession (0x0047f620) writes 1 to
// BOTH parties when the request is made, EstablishTradeSession (0x0047f970)
// moves both to 2 on acceptance, and ending the trade frees both.
func TestHubBusyCoversEveryTradePhase(t *testing.T) {
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")

	h := NewHub()
	for _, m := range []Member{alice, bob} {
		if h.Busy(m.CharacterID) || h.Established(m.CharacterID) {
			t.Fatalf("fresh hub: %s busy=%v established=%v", m.Name, h.Busy(m.CharacterID), h.Established(m.CharacterID))
		}
	}

	// Pending: both parties are held (mode 1), neither is established.
	if err := h.Request(alice, bob); err != nil {
		t.Fatalf("Request: %v", err)
	}
	for _, m := range []Member{alice, bob} {
		if !h.Busy(m.CharacterID) {
			t.Errorf("pending: %s should be busy (OpenTradeSession writes 1 to both)", m.Name)
		}
		if h.Established(m.CharacterID) {
			t.Errorf("pending: %s should not be established", m.Name)
		}
	}
	if h.Busy(carol.CharacterID) {
		t.Error("pending: a bystander is not busy")
	}

	// Accepted: both established (mode 2).
	if _, err := h.Respond(bob, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	for _, m := range []Member{alice, bob} {
		if !h.Busy(m.CharacterID) || !h.Established(m.CharacterID) {
			t.Errorf("accepted: %s busy=%v established=%v, want both", m.Name, h.Busy(m.CharacterID), h.Established(m.CharacterID))
		}
	}

	// Ended: both free.
	h.End(alice.CharacterID)
	for _, m := range []Member{alice, bob} {
		if h.Busy(m.CharacterID) || h.Established(m.CharacterID) {
			t.Errorf("ended: %s still held", m.Name)
		}
	}

	// Declined: both free.
	h.Request(alice, bob)
	if _, err := h.Respond(bob, false); err != nil {
		t.Fatalf("Respond(decline): %v", err)
	}
	for _, m := range []Member{alice, bob} {
		if h.Busy(m.CharacterID) {
			t.Errorf("declined: %s still busy", m.Name)
		}
	}

	// Withdrawn: the requester takes the request back, and the target has
	// nothing left to answer.
	h.Request(alice, bob)
	got := h.WithdrawRequest(alice.CharacterID)
	if len(got) != 1 || got[0] != bob.CharacterID {
		t.Fatalf("WithdrawRequest(alice) = %v, want [%d]", got, bob.CharacterID)
	}
	if _, err := h.Respond(bob, true); !errors.Is(err, ErrNoPendingRequest) {
		t.Fatalf("Respond after withdraw: got %v, want ErrNoPendingRequest", err)
	}
	if h.Busy(alice.CharacterID) || h.Busy(bob.CharacterID) {
		t.Error("withdrawn: both should be free")
	}

	// NEGATIVE: a requester with TWO outgoing requests. CancelPendingFor must
	// drop both -- until round 499 its `break` left one standing, and with it a
	// target held busy by a requester who had gone.
	h.Request(alice, bob)
	h.Request(alice, carol)
	h.CancelPendingFor(alice.CharacterID)
	if _, err := h.Respond(bob, true); !errors.Is(err, ErrNoPendingRequest) {
		t.Errorf("Bram's request survived CancelPendingFor(alice): %v", err)
	}
	if _, err := h.Respond(carol, true); !errors.Is(err, ErrNoPendingRequest) {
		t.Errorf("Carol's request survived CancelPendingFor(alice): %v", err)
	}
	if h.Busy(bob.CharacterID) || h.Busy(carol.CharacterID) {
		t.Error("CancelPendingFor(alice) left a target busy")
	}

	// A nil hub holds nobody.
	var nilHub *Hub
	if nilHub.Busy(alice.CharacterID) || nilHub.Established(alice.CharacterID) {
		t.Error("a nil hub should hold nobody")
	}
}

// TestCancelPendingForTargetAlsoDropsTheirOwnRequests: a character who is both
// the target of one request and the sender of another loses both. The early
// return removed in round 499 kept the outgoing one.
func TestCancelPendingForTargetAlsoDropsTheirOwnRequests(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")
	h.Request(alice, bob) // Bram is a target...
	h.Request(bob, carol) // ...and a requester.

	requester, notifiable := h.CancelPendingFor(bob.CharacterID)
	if !notifiable || requester.CharacterID != alice.CharacterID {
		t.Fatalf("CancelPendingFor(bob) = %+v, %v; want alice, true", requester, notifiable)
	}
	if _, err := h.Respond(carol, true); !errors.Is(err, ErrNoPendingRequest) {
		t.Fatalf("Bram's own request to Carol survived: %v", err)
	}
}
