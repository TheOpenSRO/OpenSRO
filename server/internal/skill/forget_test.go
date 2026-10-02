package skill

import (
	"context"
	"testing"
	"time"
)

// TestForget: both stores drop exactly the named skill (and the memory
// store its last use), and forgetting an unknown skill is not an error.
func TestForget(t *testing.T) {
	ctx := context.Background()
	for name, s := range map[string]interface {
		Store
		Forgetter
	}{"mem": NewMemStore(), "sql": openTestSQLStore(t)} {
		for _, id := range []int64{31825, 3} {
			if err := s.Learn(ctx, 7, id); err != nil {
				t.Fatalf("%s: Learn(%d): %v", name, id, err)
			}
		}
		if err := s.RecordUse(ctx, 7, 31825, time.Now()); err != nil {
			t.Fatalf("%s: RecordUse: %v", name, err)
		}
		if err := s.Forget(ctx, 7, 31825); err != nil {
			t.Fatalf("%s: Forget: %v", name, err)
		}
		if err := s.Forget(ctx, 7, 999999); err != nil {
			t.Fatalf("%s: Forget of an unknown skill: %v", name, err)
		}
		known, _ := s.KnownSkills(ctx, 7)
		if len(known) != 1 || known[0] != 3 {
			t.Fatalf("%s: known after Forget = %v, want [3]", name, known)
		}
		if _, used, _ := s.LastUsed(ctx, 7, 31825); used {
			t.Fatalf("%s: the forgotten skill keeps its last use", name)
		}
	}
}
