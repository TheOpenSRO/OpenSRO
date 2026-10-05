package inventory

import (
	"context"
	"errors"
	"testing"
)

type splitStacks struct{}

func (splitStacks) GetMaxStack(_ context.Context, _ int64) (int, error) { return 5000, nil }

func splitStores(t *testing.T) map[string]Store {
	t.Helper()
	stores := map[string]Store{"mem": NewMemStore(splitStacks{})}
	sql, err := OpenSQLStore(testDSN(), splitStacks{})
	if err != nil {
		t.Logf("sql store skipped: %v", err)
		return stores
	}
	if err := sql.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	t.Cleanup(func() { sql.Close() })
	stores["sql"] = sql
	return stores
}

// Round 728: a split moves count of a stack into an EMPTY slot (the client's
// MsgBoxDivideCount sends the bag's first empty slot), keeps the rest, and
// refuses a taken destination or a count outside 1..stack-1.
func TestSplitItem(t *testing.T) {
	ctx := context.Background()
	for name, st := range splitStores(t) {
		t.Run(name, func(t *testing.T) {
			const char = int64(7)
			if err := st.AddItem(ctx, char, 42, 5000); err != nil {
				t.Fatal(err)
			}
			if err := st.AddItem(ctx, char, 43, 1); err != nil {
				t.Fatal(err)
			}
			sp, ok := st.(Splitter)
			if !ok {
				t.Fatal("store is not a Splitter")
			}
			if err := sp.SplitItem(ctx, char, 0, 5, 1); err != nil {
				t.Fatalf("SplitItem: %v", err)
			}
			got := map[int]int{}
			slots, _ := st.List(ctx, char)
			for _, sl := range slots {
				got[sl.Index] = sl.Quantity
			}
			if got[0] != 4999 || got[5] != 1 {
				t.Fatalf("after splitting 1 off 5000: %v", got)
			}
			if err := sp.SplitItem(ctx, char, 0, 1, 2); !errors.Is(err, ErrSlotTaken) {
				t.Fatalf("onto a taken slot: %v, want ErrSlotTaken", err)
			}
			if err := sp.SplitItem(ctx, char, 0, 9, 4999); !errors.Is(err, ErrSplitCount) {
				t.Fatalf("the whole stack: %v, want ErrSplitCount", err)
			}
			if err := sp.SplitItem(ctx, char, 0, 9, 0); !errors.Is(err, ErrSplitCount) {
				t.Fatalf("zero: %v, want ErrSplitCount", err)
			}
			if err := sp.SplitItem(ctx, char, 3, 9, 1); !errors.Is(err, ErrSlotEmpty) {
				t.Fatalf("from an empty slot: %v, want ErrSlotEmpty", err)
			}
		})
	}
}
