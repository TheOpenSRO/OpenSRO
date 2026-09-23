package session

import (
	"context"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
)

// member builds a party member with a distinct session, which Hub.Create and
// Hub.Join both dereference.
func member(sessionID uint64, characterID int64, name string) party.Member {
	// Level clears party.MinLevelToCreate: Hub.Create enforces the engine's
	// level-5 rule for starting a party, and these tests are about the exp
	// bonus rather than that gate.
	return party.Member{Session: gateway.NewTestSession(sessionID), CharacterID: characterID,
		Name: name, Level: party.MinLevelToCreate}
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

// TestKillExpPartyGapBonus covers the wiring between a live party and the diff
// scaler's gap bonus (round 480). The bonus itself is pinned in
// leveldata.TestExpDiffScalePartyBonus; what this checks is that a partied
// kill reaches it and every "no party" shape does not.
//
// A level-10 killer against a level-20 target, with the real level-10 exp unit
// 235: solo 235 * 1.39 = 326.65 -> 327; partied 235 * (1.39 + 0.45) = 432.4 ->
// 432 (the window scaler is 1.0 inside a +10 gap).
func TestKillExpPartyGapBonus(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader(`level,exp,mastery_sp,exp_unit
10,23500,9,235
20,72700,53,470
`))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}

	// No hub at all -- how the handler is built in most tests.
	if got, ok := killExpFor(tbl, nil, 42, 10, 20); !ok || got != 327 {
		t.Errorf("no party hub: got %d,%v; want 327", got, ok)
	}

	hub := party.NewHub()

	// A character in no party gets the solo scale.
	if got, _ := killExpFor(tbl, hub, 42, 10, 20); got != 327 {
		t.Errorf("character in no party: got %d, want 327", got)
	}

	// A party of one already passes the engine's gate: it tests the party
	// pointer, not the member count.
	pt, err := hub.Create(member(1, 42, "Leader"))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if got, _ := killExpFor(tbl, hub, 42, 10, 20); got != 432 {
		t.Errorf("party of one: got %d, want 432", got)
	}

	// Both members of a party of two earn it.
	if _, err := hub.Join(pt.ID, member(2, 43, "Second")); err != nil {
		t.Fatalf("Join: %v", err)
	}
	for _, id := range []int64{42, 43} {
		if got, _ := killExpFor(tbl, hub, id, 10, 20); got != 432 {
			t.Errorf("party of two, member %d: got %d, want 432", id, got)
		}
	}

	// Someone outside the party still gets the solo scale.
	if got, _ := killExpFor(tbl, hub, 44, 10, 20); got != 327 {
		t.Errorf("outsider beside a live party: got %d, want 327", got)
	}
}

// TestApplyMasteryExpScale covers the wiring between a character's masteries and
// the recovered penalty. The multiplier itself is pinned in
// leveldata.TestMasteryExpScale; this checks that the HIGHEST mastery is the one
// that counts, and that every failure shape leaves the award alone rather than
// silently costing the player most of a kill.
func TestApplyMasteryExpScale(t *testing.T) {
	ctx := context.Background()

	// No skill store at all -- how several handlers are built in tests.
	if got := applyMasteryExpScale(ctx, nil, 1, 40, 1000); got != 1000 {
		t.Errorf("no skill store: got %d, want 1000", got)
	}

	store := skill.NewMemStore()
	if _, err := store.AddSkillPoints(ctx, 1, 100000); err != nil {
		t.Fatalf("AddSkillPoints: %v", err)
	}

	// No masteries at all: a level-40 character falls to the floor, 0.1.
	if got := applyMasteryExpScale(ctx, store, 1, 40, 1000); got != 100 {
		t.Errorf("no masteries at level 40: got %d, want 100 (the 0.1 floor)", got)
	}

	// Raise one mastery to 5 and another to 3. The HIGHEST is what counts, so
	// the gap is 40-5 = 35, still past the floor.
	for i := 0; i < 5; i++ {
		if _, err := store.RaiseMastery(ctx, 1, 257, 1, 120); err != nil {
			t.Fatalf("RaiseMastery 257: %v", err)
		}
	}
	for i := 0; i < 3; i++ {
		if _, err := store.RaiseMastery(ctx, 1, 258, 1, 120); err != nil {
			t.Fatalf("RaiseMastery 258: %v", err)
		}
	}
	if got := applyMasteryExpScale(ctx, store, 1, 40, 1000); got != 100 {
		t.Errorf("best mastery 5 at level 40: got %d, want 100", got)
	}

	// A character whose best mastery keeps pace takes no penalty.
	if got := applyMasteryExpScale(ctx, store, 1, 5, 1000); got != 1000 {
		t.Errorf("level 5 with mastery 5: got %d, want 1000", got)
	}
	// One level of lag costs exactly a tenth.
	if got := applyMasteryExpScale(ctx, store, 1, 6, 1000); got != 900 {
		t.Errorf("level 6 with mastery 5: got %d, want 900", got)
	}
	// Mastery ahead of level pays MORE -- the rule is symmetric.
	if got := applyMasteryExpScale(ctx, store, 1, 3, 1000); got != 1200 {
		t.Errorf("level 3 with mastery 5: got %d, want 1200", got)
	}

	// Zero exp stays zero rather than being floored up to 1.
	if got := applyMasteryExpScale(ctx, store, 1, 40, 0); got != 0 {
		t.Errorf("zero exp: got %d, want 0", got)
	}
	// A tiny award never rounds away to nothing.
	if got := applyMasteryExpScale(ctx, store, 1, 40, 3); got < 1 {
		t.Errorf("small award: got %d, want at least 1", got)
	}
}
