package guild

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// TestGuildMemberCapMatchesTheEngine pins the recovered table. The engine keys
// the cap on guild level and asserts the level is 1..5, so the table has exactly
// five entries; srrevamp's guilds have no level, so MaxMembers is the level-1
// entry.
func TestGuildMemberCapMatchesTheEngine(t *testing.T) {
	want := [5]int{15, 20, 25, 35, 50}
	if MaxMembersByLevel != want {
		t.Errorf("MaxMembersByLevel = %v, want %v (the dwords at .rdata 0x00ade8dc)", MaxMembersByLevel, want)
	}
	if MaxMembers != MaxMembersByLevel[0] {
		t.Errorf("MaxMembers = %d, want the level-1 entry %d", MaxMembers, MaxMembersByLevel[0])
	}
	// The engine's assert allows only levels 1..5; MaxMembersFor clamps rather
	// than panicking, so a future caller cannot index out of the table.
	for _, tc := range []struct{ level, want int }{
		{0, 15}, {1, 15}, {3, 25}, {5, 50}, {9, 50}, {-2, 15},
	} {
		if got := MaxMembersFor(tc.level); got != tc.want {
			t.Errorf("MaxMembersFor(%d) = %d, want %d", tc.level, got, tc.want)
		}
	}
}

// TestJoinRefusesWhenFull walks a guild to MaxMembers and checks the refusal
// lands exactly at the cap, so the constant and the check cannot drift apart.
func TestJoinRefusesWhenFull(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()
	g, err := m.Create(ctx, "Ironsong", 1, "Leader")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	// The leader is already a member, so MaxMembers-1 more fit.
	for i := 2; i <= MaxMembers; i++ {
		if _, err := m.Join(ctx, g.ID, int64(i), "M"); err != nil {
			t.Fatalf("member %d of %d: %v", i, MaxMembers, err)
		}
	}
	if _, err := m.Join(ctx, g.ID, int64(MaxMembers+1), "OneTooMany"); !errors.Is(err, ErrGuildFull) {
		t.Errorf("member %d: got %v, want ErrGuildFull", MaxMembers+1, err)
	}
}

// TestPermissionMasksMatchTheEngine pins the bit positions read off the seven
// call sites of FUN_005d0f80, and the ALL-bits semantics of its comparison.
func TestPermissionMasksMatchTheEngine(t *testing.T) {
	for _, tc := range []struct {
		name string
		got  Permission
		want Permission
	}{
		{"invite is bit 0", PermInvite, 0x01},
		{"warehouse is bit 3", PermWarehouse, 0x08},
		{"notice is bit 4", PermNotice, 0x10},
	} {
		if tc.got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, tc.got, tc.want)
		}
	}

	// The engine's test is `(perms & required) == required`, so a member needs
	// EVERY requested bit -- not merely one of them. A non-zero check would pass
	// the third case below and let a warehouse-only member edit the notice.
	full := PermInvite | PermWarehouse | PermNotice
	if !full.Has(PermNotice) {
		t.Error("a member with every bit must pass a single-bit requirement")
	}
	if !full.Has(PermInvite | PermWarehouse) {
		t.Error("a member with every bit must pass a multi-bit requirement")
	}
	if PermWarehouse.Has(PermWarehouse | PermNotice) {
		t.Error("holding one bit of a two-bit requirement must NOT pass")
	}
	if Permission(0).Has(PermInvite) {
		t.Error("holding nothing must not pass")
	}
	// A requirement of zero is vacuously satisfied, which is what the engine's
	// equality does too.
	if !Permission(0).Has(0) {
		t.Error("an empty requirement is satisfied by anyone")
	}
}

// --- values recovered 2026-09-17 -------------------------------------

// `len - 2u < 0xb` accepts 2 through 12. The boundaries are what a restatement
// of the range gets wrong, and the minimum is the half srrevamp did not have.
func TestValidNameMatchesTheUnsignedCheck(t *testing.T) {
	for n := MinNameLength; n <= MaxNameLength; n++ {
		if !ValidName(strings.Repeat("a", n)) {
			t.Errorf("a %d-character name was rejected", n)
		}
	}
	for _, n := range []int{0, 1, 13, 14, 32, 100} {
		if ValidName(strings.Repeat("a", n)) {
			t.Errorf("a %d-character name was accepted", n)
		}
	}
	// And against the instruction rather than the range.
	for n := 0; n <= 200; n++ {
		want := uint(n-MinNameLength) < uint(MaxNameLength-MinNameLength+1)
		if got := ValidName(strings.Repeat("a", n)); got != want {
			t.Fatalf("length %d: got %v want %v", n, got, want)
		}
	}
}

// MaxLevel and the capacity table were recovered from different functions and
// must agree; that agreement is the evidence for both.
func TestMaxLevelAgreesWithTheCapacityTable(t *testing.T) {
	if MaxLevel != len(MaxMembersByLevel) {
		t.Errorf("MaxLevel is %d but MaxMembersByLevel has %d entries; the level-up "+
			"cap and the capacity table came from different functions and agreeing "+
			"is what makes either trustworthy", MaxLevel, len(MaxMembersByLevel))
	}
	if MaxMembersFor(MaxLevel) != 50 {
		t.Errorf("a level-%d guild holds %d, want 50", MaxLevel, MaxMembersFor(MaxLevel))
	}
}

func TestLevelUpCost(t *testing.T) {
	for _, c := range []struct {
		from   int
		gold   int64
		points int
	}{
		{1, 3_000_000, 5_400},
		{2, 9_000_000, 50_400},
		{3, 15_000_000, 135_000},
		{4, 21_000_000, 378_000},
	} {
		gold, points, ok := LevelUpCost(c.from)
		if !ok {
			t.Errorf("level %d has no cost", c.from)
			continue
		}
		if gold != c.gold || points != c.points {
			t.Errorf("level %d costs %d gold / %d GP, want %d / %d",
				c.from, gold, points, c.gold, c.points)
		}
	}
	// The switch accepts 1..4 and nothing else. Level 5 is the cap, so it has
	// no cost -- which is a different statement from its cost being zero.
	for _, from := range []int{0, -1, MaxLevel, MaxLevel + 1, 99} {
		if _, _, ok := LevelUpCost(from); ok {
			t.Errorf("level %d reported a cost; the engine's switch rejects it", from)
		}
	}
}

// The gold costs rise by a constant six million. Recording the shape catches a
// transcription slip that a per-value check would not, because a wrong digit in
// one entry breaks the progression.
func TestLevelUpGoldIsAnArithmeticProgression(t *testing.T) {
	const step = 6_000_000
	for from := 2; from < MaxLevel; from++ {
		if d := LevelUpGold[from] - LevelUpGold[from-1]; d != step {
			t.Errorf("the step from level %d to %d is %d, want %d", from-1, from, d, step)
		}
	}
	// The guild-point costs do NOT form a clean progression, and that is the
	// point of saying so: they are a hand-tuned table, so nothing here should
	// try to derive them.
	if LevelUpGuildPoints[2]-LevelUpGuildPoints[1] == LevelUpGuildPoints[3]-LevelUpGuildPoints[2] {
		t.Error("the guild-point costs became a progression; they are a hand-tuned table")
	}
}
