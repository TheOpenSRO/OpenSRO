package guild

import (
	"context"
	"errors"
	"testing"
	"time"
)

func testRound822(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	g, err := s.Create(ctx, "Verizon", 1, "Tess")
	if err != nil {
		t.Fatal(err)
	}
	for id, name := range map[int64]string{2: "Rook", 3: "Bea"} {
		if _, err := s.Join(ctx, g.ID, id, name); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Remove(ctx, 1); !errors.Is(err, ErrIsMaster) {
		t.Fatalf("the master's remove: %v", err)
	}
	after, err := s.Remove(ctx, 2)
	if err != nil || len(after.Members) != 2 {
		t.Fatalf("remove Rook: %+v %v", after, err)
	}
	if _, err := s.GetByCharacter(ctx, 2); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("Rook still in: %v", err)
	}
	if _, err := s.Remove(ctx, 2); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("a second remove: %v", err)
	}
	was, err := s.Disband(ctx, g.ID)
	if err != nil || len(was.Members) != 2 {
		t.Fatalf("disband: %+v %v", was, err)
	}
	for _, id := range []int64{1, 3} {
		if _, err := s.GetByCharacter(ctx, id); !errors.Is(err, ErrNotInGuild) {
			t.Fatalf("%d after the disband: %v", id, err)
		}
	}
	if _, err := s.Create(ctx, "Verizon", 3, "Bea"); err != nil {
		t.Fatalf("the name is free again: %v", err)
	}
	if u, _ := s.PenaltyUntil(ctx, 9); !u.IsZero() {
		t.Fatalf("no penalty: %v", u)
	}
	until := time.Now().Add(PenaltyDuration).Truncate(time.Second)
	if err := s.SetPenalty(ctx, 9, until); err != nil {
		t.Fatal(err)
	}
	if u, _ := s.PenaltyUntil(ctx, 9); !u.Equal(until) {
		t.Fatalf("penalty %v, want %v", u, until)
	}
}

func TestSQLStoreRound822(t *testing.T) {
	testRound822(t, openTestSQLStore(t))
}
