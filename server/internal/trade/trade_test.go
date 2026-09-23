package trade

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

func member(id int64, name string) Member {
	return Member{Session: gateway.NewTestSession(uint64(id)), CharacterID: id, Name: name}
}

func TestRequestAndRespondAccept(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if _, err := h.Request(alice, bob); err != nil {
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

	if _, err := h.Request(alice, bob); err != nil {
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
	if _, err := h.Request(alice, alice); !errors.Is(err, ErrCannotTradeSelf) {
		t.Fatalf("got %v, want ErrCannotTradeSelf", err)
	}
}

func TestRequestWhileBusy(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")

	if _, err := h.Request(alice, bob); err != nil {
		t.Fatalf("Request: %v", err)
	}
	if _, err := h.Respond(bob, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	if _, err := h.Request(alice, carol); !errors.Is(err, ErrAlreadyTrading) {
		t.Fatalf("got %v, want ErrAlreadyTrading", err)
	}
	if _, err := h.Request(carol, bob); !errors.Is(err, ErrTargetBusy) {
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
	if _, err := h.Request(alice, bob); err != nil {
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
	// target held busy by a requester who had gone. Since round 500 Request
	// refuses a second request, so the state is built by hand to keep that
	// guard.
	h.pending[bob.CharacterID] = PendingRequest{Requester: alice, TargetID: bob.CharacterID, ID: 101}
	h.pending[carol.CharacterID] = PendingRequest{Requester: alice, TargetID: carol.CharacterID, ID: 102}
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
// return removed in round 499 kept the outgoing one. Round 500's Request no
// longer lets a pending target send a request, so the state is built by hand.
func TestCancelPendingForTargetAlsoDropsTheirOwnRequests(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")
	h.pending[bob.CharacterID] = PendingRequest{Requester: alice, TargetID: bob.CharacterID, ID: 1}   // Bram is a target...
	h.pending[carol.CharacterID] = PendingRequest{Requester: bob, TargetID: carol.CharacterID, ID: 2} // ...and a requester.

	requester, notifiable := h.CancelPendingFor(bob.CharacterID)
	if !notifiable || requester.CharacterID != alice.CharacterID {
		t.Fatalf("CancelPendingFor(bob) = %+v, %v; want alice, true", requester, notifiable)
	}
	if _, err := h.Respond(carol, true); !errors.Is(err, ErrNoPendingRequest) {
		t.Fatalf("Bram's own request to Carol survived: %v", err)
	}
}

// TestRequestHoldsEachCharacterInOneRequest: OpenTradeSession (0x0047f620)
// needs both parties at INTERACTMODE 0 and writes 1 to both, so a character in
// a pending request -- on either side -- can neither send another nor be sent
// one.
func TestRequestHoldsEachCharacterInOneRequest(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")

	id, err := h.Request(alice, bob)
	if err != nil || id == 0 {
		t.Fatalf("Request = %d, %v; want a non-zero id", id, err)
	}
	if _, err := h.Request(alice, carol); !errors.Is(err, ErrRequestPending) {
		t.Errorf("a second request from the sender: got %v, want ErrRequestPending", err)
	}
	if _, err := h.Request(bob, carol); !errors.Is(err, ErrRequestPending) {
		t.Errorf("a request from the pending target: got %v, want ErrRequestPending", err)
	}
	if _, err := h.Request(carol, bob); !errors.Is(err, ErrTargetBusy) {
		t.Errorf("a request to the pending target: got %v, want ErrTargetBusy", err)
	}
	// NEGATIVE: before round 500 only a target's INCOMING request made it
	// busy, so a request to the pending SENDER went through.
	if _, err := h.Request(carol, alice); !errors.Is(err, ErrTargetBusy) {
		t.Errorf("a request to the pending sender: got %v, want ErrTargetBusy", err)
	}
	if h.Busy(carol.CharacterID) {
		t.Error("refused requests left Carol busy")
	}
}

// TestPendingOfSeesBothSides: PendingOf answers for the sender and the target
// of a request alike, and for nobody else.
func TestPendingOfSeesBothSides(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")
	id, _ := h.Request(alice, bob)
	for _, m := range []Member{alice, bob} {
		p, ok := h.PendingOf(m.CharacterID)
		if !ok || p.Requester.CharacterID != alice.CharacterID || p.TargetID != bob.CharacterID || p.ID != id {
			t.Errorf("PendingOf(%s) = %+v, %v; want Aria -> Bram #%d", m.Name, p, ok, id)
		}
	}
	if p, ok := h.PendingOf(carol.CharacterID); ok {
		t.Errorf("PendingOf(Carol) = %+v, want none", p)
	}
}

// TestRespondAcceptDoesNotOverwriteAnOpenTrade: accepting a request whose
// requester (or target) is already in an open trade is refused and drops the
// request. Before round 500 Respond overwrote h.active for the requester and
// left the first partner holding a session nobody else shared.
// EstablishTradeSession (0x0047f970) requires both parties at INTERACTMODE 1,
// and Request no longer builds this state, so it is built by hand.
func TestRespondAcceptDoesNotOverwriteAnOpenTrade(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")
	h.Request(alice, bob)
	h.Respond(bob, true)
	open, _ := h.SessionOf(alice.CharacterID)

	// The requester is mid-trade.
	h.pending[carol.CharacterID] = PendingRequest{Requester: alice, TargetID: carol.CharacterID, ID: 90}
	if _, err := h.Respond(carol, true); !errors.Is(err, ErrAlreadyTrading) {
		t.Fatalf("accept with the requester mid-trade: got %v, want ErrAlreadyTrading", err)
	}
	if s, _ := h.SessionOf(alice.CharacterID); s != open {
		t.Fatalf("Aria's open trade was replaced: %+v", s)
	}
	if h.Established(carol.CharacterID) || h.Busy(carol.CharacterID) {
		t.Fatal("Carol was left in a trade or a request")
	}

	// The target is mid-trade.
	h.pending[bob.CharacterID] = PendingRequest{Requester: carol, TargetID: bob.CharacterID, ID: 91}
	if _, err := h.Respond(bob, true); !errors.Is(err, ErrAlreadyTrading) {
		t.Fatalf("accept with the target mid-trade: got %v, want ErrAlreadyTrading", err)
	}
	if s, _ := h.SessionOf(bob.CharacterID); s != open {
		t.Fatalf("Bram's open trade was replaced: %+v", s)
	}
	if h.Established(carol.CharacterID) {
		t.Fatal("Carol was put in a trade")
	}
}

// TestExpireMatchesTheRequestID: the timeout closes only the request it was
// started for -- as the engine's closes by session number -- so a timer left
// from a request that was withdrawn and made again does nothing.
func TestExpireMatchesTheRequestID(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	old, _ := h.Request(alice, bob)
	h.WithdrawRequest(alice.CharacterID)
	cur, err := h.Request(alice, bob)
	if err != nil || cur == old {
		t.Fatalf("second Request = %d, %v; want a new id (old %d)", cur, err, old)
	}
	if _, ok := h.Expire(bob.CharacterID, old); ok {
		t.Fatal("a stale timeout closed the newer request")
	}
	if !h.Busy(bob.CharacterID) {
		t.Fatal("the newer request is gone")
	}
	requester, ok := h.Expire(bob.CharacterID, cur)
	if !ok || requester.CharacterID != alice.CharacterID {
		t.Fatalf("Expire(current) = %+v, %v; want Aria, true", requester, ok)
	}
	if h.Busy(alice.CharacterID) || h.Busy(bob.CharacterID) {
		t.Fatal("an expired request left a party busy")
	}
	if _, ok := h.Expire(bob.CharacterID, cur); ok {
		t.Fatal("a request expired twice")
	}
}

// TestRequestRuleValues pins the two engine constants: float32 320.0 at .rdata
// 0xb460dc (bytes 00 00 a0 43) and float32 30.0 at .rdata 0xb45b48 (00 00 f0 41),
// in seconds (the tick divides milliseconds by the double 1000.0 at 0xb45c68).
func TestRequestRuleValues(t *testing.T) {
	if bits := math.Float32bits(RequestRange); bits != 0x43a00000 {
		t.Errorf("RequestRange is float32 bits 0x%08x, want 0x43a00000", bits)
	}
	if bits := math.Float32bits(float32(RequestTimeout.Seconds())); bits != 0x41f00000 {
		t.Errorf("RequestTimeout is float32 bits 0x%08x, want 0x41f00000", bits)
	}
	if RequestTimeout != 30*time.Second {
		t.Errorf("RequestTimeout = %v, want 30s", RequestTimeout)
	}
}
