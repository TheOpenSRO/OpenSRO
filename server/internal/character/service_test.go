package character

import (
	"context"
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 838: the service scrolls' state (ServiceStore), in memory and in
// PostgreSQL alike: the plate colours, the pending flags, the waived SP, the rename and its
// uniqueness, and a rename undone by its transaction.
func TestServiceStores(t *testing.T) {
	ctx := context.Background()
	for name, store := range map[string]interface {
		Store
		LobbyStore
		ServiceStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			c, err := store.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if _, err := store.Create(ctx, 2, "Bram"); err != nil {
				t.Fatalf("Create: %v", err)
			}
			if n, ti, err := store.PlateColours(ctx, c.ID); err != nil || n != 0 || ti != 0 {
				t.Fatalf("a new character's colours %x %x %v", n, ti, err)
			}
			if err := store.SetNameColour(ctx, c.ID, 0xFF000000); err != nil {
				t.Fatal(err)
			}
			if err := store.SetTitleColour(ctx, c.ID, 0xFFFFFFFF); err != nil {
				t.Fatal(err)
			}
			if n, ti, _ := store.PlateColours(ctx, c.ID); n != 0xFF000000 || ti != 0xFFFFFFFF {
				t.Fatalf("colours %x %x", n, ti)
			}
			if p, _ := store.AddServicePending(ctx, c.ID, ServicePendingRename|ServicePendingStatReset); p != 3 {
				t.Fatalf("pending %b", p)
			}
			if p, _ := store.ClearServicePending(ctx, c.ID, ServicePendingRename); p != ServicePendingStatReset {
				t.Fatalf("after the clear %b", p)
			}
			if p, _ := store.ServicePending(ctx, c.ID); p != ServicePendingStatReset {
				t.Fatalf("read back %b", p)
			}
			if w, err := store.TakeWaivedSP(ctx, c.ID); err != nil || w != 0 {
				t.Fatalf("a new character's waived SP %d %v", w, err)
			}
			if err := store.AddWaivedSP(ctx, c.ID, 120); err != nil {
				t.Fatal(err)
			}
			if err := store.AddWaivedSP(ctx, c.ID, 30); err != nil {
				t.Fatal(err)
			}
			if w, err := store.TakeWaivedSP(ctx, c.ID); err != nil || w != 150 {
				t.Fatalf("waived SP %d %v", w, err)
			}
			if w, _ := store.TakeWaivedSP(ctx, c.ID); w != 0 {
				t.Fatalf("waived SP after the take %d", w)
			}
			if err := store.AddWaivedSP(ctx, 999999, 1); !errors.Is(err, ErrNotFound) {
				t.Fatalf("waived SP for no one: %v", err)
			}
			if err := store.Rename(ctx, c.ID, "bram"); !errors.Is(err, ErrNameTaken) {
				t.Fatalf("a taken name: %v", err)
			}
			if err := store.Rename(ctx, c.ID, "Arion"); err != nil {
				t.Fatal(err)
			}
			if got, _ := store.GetByID(ctx, c.ID); got.Name != "Arion" {
				t.Fatalf("name %q", got.Name)
			}
			if taken, _ := store.NameTaken(ctx, "aria"); taken {
				t.Fatal("the old name is still taken")
			}
			if taken, _ := store.NameTaken(ctx, "ARION"); !taken {
				t.Fatal("the new name is not taken")
			}
			// Undone with its transaction.
			_ = txn.For(store).Run(ctx, func(ctx context.Context) error {
				if err := store.Rename(ctx, c.ID, "Ariel"); err != nil {
					t.Fatal(err)
				}
				return errors.New("roll back")
			})
			if got, _ := store.GetByID(ctx, c.ID); got.Name != "Arion" {
				t.Fatalf("a rolled-back rename stood: %q", got.Name)
			}
			if err := store.Rename(ctx, 999999, "Nobody"); !errors.Is(err, ErrNotFound) {
				t.Errorf("an unknown character: %v", err)
			}
			if _, _, err := store.PlateColours(ctx, 999999); !errors.Is(err, ErrNotFound) {
				t.Errorf("an unknown character's colours: %v", err)
			}
		})
	}
}
