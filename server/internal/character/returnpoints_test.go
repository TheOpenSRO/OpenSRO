package character

import (
	"context"
	"errors"
	"testing"
)

// Round 778: the recall and death points (ReturnPointStore), in memory and in
// PostgreSQL alike. A new character has neither (Region 0); each kind is its
// own; a dungeon's negative region survives; an unknown character is
// ErrNotFound.
func TestReturnPointStores(t *testing.T) {
	ctx := context.Background()
	for name, store := range map[string]interface {
		Store
		ReturnPointStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			c, err := store.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			for _, kind := range []ReturnPointKind{RecallPoint, DeathPoint} {
				p, err := store.ReturnPoint(ctx, c.ID, kind)
				if err != nil || p.Set() {
					t.Fatalf("kind %d of a new character: %+v, %v; want none", kind, p, err)
				}
			}
			recall := SavedPoint{Region: 25000, X: 995.5, Y: -32, Z: 1132.25, WorldID: 1}
			death := SavedPoint{Region: -32767, X: 1115, Y: 12.5, Z: -935, WorldID: 1}
			if err := store.SetReturnPoint(ctx, c.ID, RecallPoint, recall); err != nil {
				t.Fatal(err)
			}
			if err := store.SetReturnPoint(ctx, c.ID, DeathPoint, death); err != nil {
				t.Fatal(err)
			}
			if got, _ := store.ReturnPoint(ctx, c.ID, RecallPoint); got != recall {
				t.Errorf("recall point %+v, want %+v", got, recall)
			}
			if got, _ := store.ReturnPoint(ctx, c.ID, DeathPoint); got != death {
				t.Errorf("death point %+v, want %+v", got, death)
			}
			if _, err := store.ReturnPoint(ctx, 999999, DeathPoint); !errors.Is(err, ErrNotFound) {
				t.Errorf("unknown character: %v, want ErrNotFound", err)
			}
			if err := store.SetReturnPoint(ctx, 999999, RecallPoint, recall); !errors.Is(err, ErrNotFound) {
				t.Errorf("setting for an unknown character: %v, want ErrNotFound", err)
			}
			if _, err := store.ReturnPoint(ctx, c.ID, ReturnPointKind(7)); err == nil {
				t.Error("an unknown kind was read")
			}
		})
	}
}
