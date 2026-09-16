package guild

import (
	"context"
	"errors"
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
