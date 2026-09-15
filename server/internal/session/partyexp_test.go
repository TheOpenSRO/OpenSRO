package session

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/party"
)

// member builds a party member with a distinct session, which Hub.Create and
// Hub.Join both dereference.
func member(sessionID uint64, characterID int64, name string) party.Member {
	return party.Member{Session: gateway.NewTestSession(sessionID), CharacterID: characterID, Name: name}
}

// TestApplyPartyExpBonus covers the wiring between a live party and the
// recovered multiplier. The multiplier itself is pinned in
// leveldata.TestPartyExpBonus; what this checks is that a kill actually reaches
// it, and that every "no party" shape falls back to the engine's FLD1 default
// of 1.0 rather than to zero or a panic.
func TestApplyPartyExpBonus(t *testing.T) {
	// No hub at all -- how the handler is built in most tests.
	if got := applyPartyExpBonus(nil, 1, 1000); got != 1000 {
		t.Errorf("no party hub: got %d, want the exp unchanged (1000)", got)
	}

	hub := party.NewHub()

	// A character in no party is unchanged.
	if got := applyPartyExpBonus(hub, 42, 1000); got != 1000 {
		t.Errorf("character in no party: got %d, want 1000", got)
	}

	// A party of one is still 1.0 -- the engine only adds for members PAST
	// the first, so a solo leader earns exactly what a partyless one does.
	pt, err := hub.Create(member(1, 42, "Leader"))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if got := applyPartyExpBonus(hub, 42, 1000); got != 1000 {
		t.Errorf("party of one: got %d, want 1000", got)
	}

	// Two members: 1000 * 1.03.
	if _, err := hub.Join(pt.ID, member(2, 43, "Second")); err != nil {
		t.Fatalf("Join: %v", err)
	}
	if got := applyPartyExpBonus(hub, 42, 1000); got != 1030 {
		t.Errorf("party of two: got %d, want 1030", got)
	}
	// The bonus follows the party, not the killer: the joiner earns it too.
	if got := applyPartyExpBonus(hub, 43, 1000); got != 1030 {
		t.Errorf("party of two, other member: got %d, want 1030", got)
	}

	// Three members: 1000 * 1.06.
	if _, err := hub.Join(pt.ID, member(3, 44, "Third")); err != nil {
		t.Fatalf("Join: %v", err)
	}
	if got := applyPartyExpBonus(hub, 42, 1000); got != 1060 {
		t.Errorf("party of three: got %d, want 1060", got)
	}

	// Zero exp stays zero rather than rounding into a point from nothing.
	if got := applyPartyExpBonus(hub, 42, 0); got != 0 {
		t.Errorf("zero exp: got %d, want 0", got)
	}

	// Rounding is to nearest, not truncation: 7 * 1.06 = 7.42 -> 7, but
	// 9 * 1.06 = 9.54 -> 10. Truncation would give 9 and hide the bonus.
	if got := applyPartyExpBonus(hub, 42, 9); got != 10 {
		t.Errorf("small award rounding: got %d, want 10 (9 * 1.06 = 9.54)", got)
	}
}
