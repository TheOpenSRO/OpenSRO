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
