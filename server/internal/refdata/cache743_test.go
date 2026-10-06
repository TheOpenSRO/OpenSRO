package refdata

import (
	"context"
	"testing"
)

// Round 743's review, F3: item rows are cached once read. A caller's copy is
// its own, and an import replaces what the cache holds.
func TestItemCache(t *testing.T) {
	s := openTestSQLStore(t)
	ctx := context.Background()
	if err := s.ImportItems(ctx, []Item{{ID: 7, MaxStack: 5, DurabilityMin: 10, DurabilityMax: 20}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	a, err := s.GetItem(ctx, 7)
	if err != nil || a.MaxStack != 5 {
		t.Fatalf("GetItem: %+v %v", a, err)
	}
	a.MaxStack = 99 // a caller's change stays the caller's
	if n, _ := s.GetMaxStack(ctx, 7); n != 5 {
		t.Fatalf("GetMaxStack after a caller's change: %d, want 5", n)
	}
	if _, err := s.db.Exec(`UPDATE items SET max_stack = 50 WHERE id = 7`); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.GetMaxStack(ctx, 7); n != 5 {
		t.Fatalf("GetMaxStack read the table again: %d, want the cached 5", n)
	}
	if err := s.ImportItems(ctx, []Item{{ID: 7, MaxStack: 8}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	if n, _ := s.GetMaxStack(ctx, 7); n != 8 {
		t.Fatalf("after an import: %d, want 8", n)
	}
	if _, _, ok, _ := s.DurabilityRange(ctx, 7); ok {
		t.Fatal("the imported row has no durability")
	}
	if n, err := s.GetMaxStack(ctx, 12345); n != 0 || err != nil {
		t.Fatalf("an unknown item: %d %v, want 0 and no error", n, err)
	}
}
