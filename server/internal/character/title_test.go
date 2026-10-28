package character

import (
	"context"
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 838: a character's title (TitleStore), in memory and in PostgreSQL
// alike: none at first, a level, the custom title's text kept only at
// CustomTitleLevel, and a change undone by its transaction.
func TestTitleStores(t *testing.T) {
	ctx := context.Background()
	for name, store := range map[string]interface {
		Store
		TitleStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			c, err := store.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if l, s, err := store.Title(ctx, c.ID); err != nil || l != 0 || s != "" {
				t.Fatalf("a new character's title %d %q %v", l, s, err)
			}
			if err := store.SetTitle(ctx, c.ID, 196, "ignored"); err != nil {
				t.Fatal(err)
			}
			if l, s, _ := store.Title(ctx, c.ID); l != 196 || s != "" {
				t.Fatalf("196: %d %q", l, s)
			}
			if err := store.SetTitle(ctx, c.ID, CustomTitleLevel, "Sky Walker"); err != nil {
				t.Fatal(err)
			}
			if l, s, _ := store.Title(ctx, c.ID); l != 255 || s != "Sky Walker" {
				t.Fatalf("custom: %d %q", l, s)
			}
			// A change rolled back leaves the title as it was.
			boom := errors.New("boom")
			if err := txn.For(store).Run(ctx, func(ctx context.Context) error {
				if err := store.SetTitle(ctx, c.ID, 1, ""); err != nil {
					return err
				}
				return boom
			}); !errors.Is(err, boom) {
				t.Fatalf("the transaction: %v", err)
			}
			if l, s, _ := store.Title(ctx, c.ID); l != 255 || s != "Sky Walker" {
				t.Fatalf("after the rollback: %d %q", l, s)
			}
			if _, _, err := store.Title(ctx, 999999); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no one's title: %v", err)
			}
			if err := store.SetTitle(ctx, 999999, 1, ""); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no one's set: %v", err)
			}
		})
	}
}
