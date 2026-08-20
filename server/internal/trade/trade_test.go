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
