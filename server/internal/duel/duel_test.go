package duel

import (
	"errors"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

func member(id int64, name string) Member {
	return Member{Session: gateway.NewTestSession(uint64(id)), CharacterID: id, Name: name}
}

func TestChallengeAndRespondAccept(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}

	challenger, err := h.Respond(bob, true)
	if err != nil {
		t.Fatalf("Respond: %v", err)
	}
	if challenger.CharacterID != alice.CharacterID {
		t.Fatalf("got challenger %+v, want %+v", challenger, alice)
	}

	opp, ok := h.OpponentOf(alice.CharacterID)
	if !ok || opp.CharacterID != bob.CharacterID {
		t.Fatalf("OpponentOf(alice) = %+v, %v; want bob", opp, ok)
	}
	opp, ok = h.OpponentOf(bob.CharacterID)
	if !ok || opp.CharacterID != alice.CharacterID {
		t.Fatalf("OpponentOf(bob) = %+v, %v; want alice", opp, ok)
	}
}

func TestChallengeAndRespondDecline(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	if _, err := h.Respond(bob, false); err != nil {
		t.Fatalf("Respond: %v", err)
	}

	if _, ok := h.OpponentOf(alice.CharacterID); ok {
		t.Fatal("expected no active duel after decline")
	}
	if _, ok := h.OpponentOf(bob.CharacterID); ok {
		t.Fatal("expected no active duel after decline")
	}
}

func TestChallengeSelf(t *testing.T) {
	h := NewHub()
	alice := member(1, "Aria")
	if err := h.Challenge(alice, alice); !errors.Is(err, ErrCannotChallengeSelf) {
		t.Fatalf("got %v, want ErrCannotChallengeSelf", err)
	}
}

func TestChallengeWhileAlreadyDueling(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	if _, err := h.Respond(bob, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}

	if err := h.Challenge(alice, carol); !errors.Is(err, ErrAlreadyDueling) {
		t.Fatalf("got %v, want ErrAlreadyDueling", err)
	}
}

func TestChallengeBusyTarget(t *testing.T) {
	h := NewHub()
	alice, bob, carol := member(1, "Aria"), member(2, "Bram"), member(3, "Carol")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	if err := h.Challenge(carol, bob); !errors.Is(err, ErrTargetBusy) {
		t.Fatalf("got %v, want ErrTargetBusy (already has pending challenge)", err)
	}

	if _, err := h.Respond(bob, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	if err := h.Challenge(carol, bob); !errors.Is(err, ErrTargetBusy) {
		t.Fatalf("got %v, want ErrTargetBusy (already dueling)", err)
	}
}

func TestRespondNoPendingChallenge(t *testing.T) {
	h := NewHub()
	bob := member(2, "Bram")
	if _, err := h.Respond(bob, true); !errors.Is(err, ErrNoPendingChallenge) {
		t.Fatalf("got %v, want ErrNoPendingChallenge", err)
	}
}

func TestEnd(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}
	if _, err := h.Respond(bob, true); err != nil {
		t.Fatalf("Respond: %v", err)
	}

	opponent, ok := h.End(alice.CharacterID)
	if !ok || opponent.CharacterID != bob.CharacterID {
		t.Fatalf("End(alice) = %+v, %v; want bob", opponent, ok)
	}
	if _, ok := h.OpponentOf(alice.CharacterID); ok {
		t.Fatal("expected alice no longer dueling")
	}
	if _, ok := h.OpponentOf(bob.CharacterID); ok {
		t.Fatal("expected bob no longer dueling (both sides cleared)")
	}

	if _, ok := h.End(alice.CharacterID); ok {
		t.Fatal("expected second End to report not dueling")
	}
}

func TestCancelPendingForTarget(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}

	challenger, notifiable := h.CancelPendingFor(bob.CharacterID)
	if !notifiable || challenger.CharacterID != alice.CharacterID {
		t.Fatalf("CancelPendingFor(bob) = %+v, %v; want alice, true", challenger, notifiable)
	}

	if _, err := h.Respond(bob, true); !errors.Is(err, ErrNoPendingChallenge) {
		t.Fatalf("expected pending challenge to be gone, got %v", err)
	}
}

func TestCancelPendingForChallenger(t *testing.T) {
	h := NewHub()
	alice, bob := member(1, "Aria"), member(2, "Bram")

	if err := h.Challenge(alice, bob); err != nil {
		t.Fatalf("Challenge: %v", err)
	}

	if _, notifiable := h.CancelPendingFor(alice.CharacterID); notifiable {
		t.Fatal("expected no notifiable party when the challenger disconnects")
	}

	if _, err := h.Respond(bob, true); !errors.Is(err, ErrNoPendingChallenge) {
		t.Fatalf("expected pending challenge to be gone, got %v", err)
	}
}
