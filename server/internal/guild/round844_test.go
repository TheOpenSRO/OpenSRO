package guild

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

var (
	_ UnionBreaker    = (*MemStore)(nil)
	_ UnionBreaker    = (*SQLStore)(nil)
	_ UnionCrestStore = (*MemStore)(nil)
	_ UnionCrestStore = (*SQLStore)(nil)
)

// Round 844: s:0x5c6550's ladder, in its order.
func TestRound844ValidateUnionRequest(t *testing.T) {
	ok := UnionRequest{RequesterAlive: true, RequesterGuildID: 1, RequesterIsMaster: true, RequesterLevel: 2,
		TargetFound: true, TargetGuildID: 2, TargetLevel: 2, TargetIsMaster: true}
	if got := ValidateUnionRequest(ok); got != 1 {
		t.Fatalf("a valid request: %#x", got)
	}
	led := &Union{ID: 9}
	led.Slots[0], led.Slots[1] = 1, 3
	follower := &Union{ID: 9}
	follower.Slots[0], follower.Slots[1] = 3, 1
	cases := []struct {
		name string
		edit func(r *UnionRequest)
		want uint16
	}{
		{"dead", func(r *UnionRequest) { r.RequesterAlive = false }, 0x4c07},
		{"no guild", func(r *UnionRequest) { r.RequesterGuildID = 0 }, 0x4c0d},
		{"not the master", func(r *UnionRequest) { r.RequesterIsMaster = false }, 0x4c1e},
		{"a union's other guild", func(r *UnionRequest) { r.RequesterUnion = follower }, 0x4c1e},
		{"the union's leader", func(r *UnionRequest) { r.RequesterUnion = led }, 1},
		{"own level 1", func(r *UnionRequest) { r.RequesterLevel = 1 }, 0x4c2a},
		{"no target", func(r *UnionRequest) { r.TargetFound = false }, 3},
		{"target without a guild", func(r *UnionRequest) { r.TargetGuildID = 0 }, 0x4c25},
		{"hostile", func(r *UnionRequest) { r.TargetHostile = true }, 0x4c42},
		{"own guild", func(r *UnionRequest) { r.TargetGuildID = 1 }, 0x4c26},
		{"target level 1", func(r *UnionRequest) { r.TargetLevel = 1 }, 0x4c2b},
		{"target in a union", func(r *UnionRequest) { r.TargetInUnion = true }, 0x4c28},
		{"target not its master", func(r *UnionRequest) { r.TargetIsMaster = false }, 0x4c24},
		// Order: the level before the target, the same guild before its level.
		{"order: own level first", func(r *UnionRequest) { r.RequesterLevel = 1; r.TargetFound = false }, 0x4c2a},
		{"order: own guild before level", func(r *UnionRequest) { r.TargetGuildID = 1; r.TargetLevel = 1 }, 0x4c26},
	}
	for _, c := range cases {
		r := ok
		c.edit(&r)
		if got := ValidateUnionRequest(r); got != c.want {
			t.Errorf("%s: %#x, want %#x", c.name, got, c.want)
		}
	}
}

// Round 844: sm:0x4369f0 -- the leader's leave or fewer than two left
// breaks the union.
func TestRound844UnionBroken(t *testing.T) {
	u := &Union{ID: 1}
	u.Slots[0], u.Slots[1], u.Slots[2] = 10, 20, 30
	if !UnionBroken(u, 10) {
		t.Fatal("the leader leaving breaks it")
	}
	if UnionBroken(u, 20) {
		t.Fatal("one of three leaving keeps it")
	}
	two := &Union{ID: 2}
	two.Slots[0], two.Slots[1] = 10, 20
	if !UnionBroken(two, 20) {
		t.Fatal("one of two leaving breaks it")
	}
	if UnionBroken(nil, 1) {
		t.Fatal("no union, nothing broken")
	}
}

func TestRound844UnionBytes(t *testing.T) {
	if got := EncodeUnionRequestBox(0x01020304); !bytes.Equal(got, []byte{6, 4, 3, 2, 1}) {
		t.Fatalf("0x3080 kind 6: % x", got)
	}
	got := EncodeUnionCrestUpdate(7, []string{"Ab", "C"}, 3)
	want := []byte{2, 7, 0, 0, 0, 2, 2, 0, 'A', 'b', 1, 0, 'C', 3, 0, 0, 0}
	if !bytes.Equal(got, want) {
		t.Fatalf("0x3257 type 2: % x, want % x", got, want)
	}
}

type union844Store interface {
	Store
	UnionStore
	UnionBreaker
	UnionCrestStore
}

func TestRound844UnionStoresMem(t *testing.T) { testRound844UnionStores(t, NewMemStore()) }

func TestRound844UnionStoresSQL(t *testing.T) { testRound844UnionStores(t, openTestSQLStore(t)) }

func testRound844UnionStores(t *testing.T, s union844Store) {
	t.Helper()
	ctx := context.Background()
	mk := func(name string, leader int64) *Guild {
		g, err := s.Create(ctx, name, leader, name+"Master")
		if err != nil {
			t.Fatal(err)
		}
		return g
	}
	a, b, c := mk("Alpha", 1), mk("Beta", 2), mk("Gamma", 3)
	if _, err := s.JoinUnion(ctx, b.ID, a.ID); err != nil {
		t.Fatal(err)
	}
	u, err := s.JoinUnion(ctx, c.ID, a.ID)
	if err != nil || u.LeaderGuildID() != a.ID || u.Count() != 3 {
		t.Fatalf("formed: %+v %v", u, err)
	}
	// The crest: none, set (rev 1), set again (rev 2), cleared, set (rev 3).
	if rev, px, err := s.UnionCrest(ctx, u.ID); rev != 0 || px != nil || err != nil {
		t.Fatalf("no crest: %d %v %v", rev, px, err)
	}
	if _, err := s.SetUnionCrest(ctx, u.ID, []byte{1}); err == nil {
		t.Fatal("a short crest is refused")
	}
	pix := bytes.Repeat([]byte{7}, CrestBytes)
	if rev, err := s.SetUnionCrest(ctx, u.ID, pix); rev != 1 || err != nil {
		t.Fatalf("first crest: %d %v", rev, err)
	}
	pix[0] = 9
	if rev, err := s.SetUnionCrest(ctx, u.ID, pix); rev != 2 || err != nil {
		t.Fatalf("second crest: %d %v", rev, err)
	}
	if rev, px, err := s.UnionCrest(ctx, u.ID); rev != 2 || !bytes.Equal(px, pix) || err != nil {
		t.Fatalf("read back: %d %v", rev, err)
	}
	if got, _ := s.UnionOf(ctx, b.ID); got == nil || got.CrestRev != 2 {
		t.Fatalf("the union record carries the revision: %+v", got)
	}
	if err := s.ClearUnionCrest(ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	if rev, px, _ := s.UnionCrest(ctx, u.ID); rev != 0 || px != nil {
		t.Fatalf("cleared: %d", rev)
	}
	if rev, err := s.SetUnionCrest(ctx, u.ID, pix); rev != 3 || err != nil {
		t.Fatalf("after a delete the revision goes on: %d %v", rev, err)
	}
	if _, err := s.SetUnionCrest(ctx, 999999, pix); !errors.Is(err, ErrNoSuchUnion) {
		t.Fatalf("no such union: %v", err)
	}
	// Break: every guild out, the union gone; a second break is no error.
	if err := s.BreakUnion(ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{a.ID, b.ID, c.ID} {
		if got, err := s.UnionOf(ctx, id); got != nil || err != nil {
			t.Fatalf("guild %d after the break: %+v %v", id, got, err)
		}
	}
	if err := s.BreakUnion(ctx, u.ID); err != nil {
		t.Fatalf("a second break: %v", err)
	}
	// The guilds may form a new one.
	if u2, err := s.JoinUnion(ctx, a.ID, c.ID); err != nil || u2.LeaderGuildID() != c.ID {
		t.Fatalf("a new union: %+v %v", u2, err)
	}
}
