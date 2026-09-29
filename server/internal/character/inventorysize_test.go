package character

import (
	"context"
	"errors"
	"testing"
)

// Round 633: a character's own bag size, in memory and in PostgreSQL alike.
// None stored reads 0; a set size reads back; an expansion starts from the
// stored size or, with none, from the caller's base; one past the ceiling is
// refused with ErrInventoryFull and changes nothing; an unknown character is
// ErrNotFound.
func TestInventorySizeStores(t *testing.T) {
	ctx := context.Background()
	for name, store := range map[string]interface {
		Store
		InventorySizeStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			c, err := store.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if n, err := store.InventorySize(ctx, c.ID); err != nil || n != 0 {
				t.Fatalf("a new character's size: %d, %v; want 0 (none stored)", n, err)
			}
			if n, err := store.ExpandInventory(ctx, c.ID, 32, 32, 64); err != nil || n != 64 {
				t.Fatalf("expanding from the base 32 by 32: %d, %v; want 64", n, err)
			}
			if _, err := store.ExpandInventory(ctx, c.ID, 32, 1, 64); !errors.Is(err, ErrInventoryFull) {
				t.Errorf("expanding past the ceiling: %v, want ErrInventoryFull", err)
			}
			if n, _ := store.InventorySize(ctx, c.ID); n != 64 {
				t.Errorf("after the refusal the size is %d, want 64", n)
			}
			if err := store.SetInventorySize(ctx, c.ID, 40); err != nil {
				t.Fatalf("SetInventorySize: %v", err)
			}
			if n, _ := store.InventorySize(ctx, c.ID); n != 40 {
				t.Errorf("set 40, read %d", n)
			}
			if _, err := store.InventorySize(ctx, 999999); !errors.Is(err, ErrNotFound) {
				t.Errorf("an unknown character: %v, want ErrNotFound", err)
			}
			if err := store.SetInventorySize(ctx, 999999, 5); !errors.Is(err, ErrNotFound) {
				t.Errorf("setting an unknown character: %v, want ErrNotFound", err)
			}
		})
	}
}
