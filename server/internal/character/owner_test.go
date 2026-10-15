package character

import (
	"context"
	"errors"
	"testing"
)

var (
	_ OwnerStore = (*MemStore)(nil)
	_ OwnerStore = (*SQLStore)(nil)
)

// ByName (round 788) finds a character on any account, without case.
func TestOwnerByName(t *testing.T) {
	for name, s := range map[string]interface {
		Store
		OwnerStore
	}{"mem": NewMemStore(), "sql": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			if _, err := s.Create(ctx, 7, "Alpha"); err != nil {
				t.Fatal(err)
			}
			b, err := s.Create(ctx, 9, "Beta")
			if err != nil {
				t.Fatal(err)
			}
			c, err := s.ByName(ctx, "bETA")
			if err != nil || c.ID != b.ID || c.AccountID != 9 || c.Name != "Beta" {
				t.Fatalf("ByName(bETA) = %+v, %v", c, err)
			}
			if _, err := s.ByName(ctx, "Gamma"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("ByName(Gamma) = %v, want ErrNotFound", err)
			}
		})
	}
}
