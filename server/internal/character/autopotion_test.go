package character

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

// Round 786: the auto potion settings (AutoPotionStore), in memory and in
// PostgreSQL alike: none saved reads nil; seven bytes read back as saved; a
// wrong length is refused; an unknown character is ErrNotFound.
func TestAutoPotionStores(t *testing.T) {
	ctx := context.Background()
	for name, store := range map[string]interface {
		Store
		AutoPotionStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			c, err := store.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if v, err := store.AutoPotion(ctx, c.ID); err != nil || v != nil {
				t.Fatalf("a new character's settings: %v, %v; want nil", v, err)
			}
			// HP on at 50 % (belt F1, slot 1), MP on at 40 % (F2, slot 0),
			// abnormal off on F1 slot 3, delay on at 1.0 s: 0xb211, 0xa82a,
			// 0x0013, 0x8a -- little-endian on the wire.
			want := []byte{0x11, 0xb2, 0x2a, 0xa8, 0x13, 0x00, 0x8a}
			if err := store.SetAutoPotion(ctx, c.ID, want); err != nil {
				t.Fatalf("SetAutoPotion: %v", err)
			}
			if got, _ := store.AutoPotion(ctx, c.ID); !bytes.Equal(got, want) {
				t.Fatalf("read back %x, want %x", got, want)
			}
			if err := store.SetAutoPotion(ctx, c.ID, want[:6]); !errors.Is(err, ErrBadAutoPotion) {
				t.Errorf("six bytes: %v, want ErrBadAutoPotion", err)
			}
			if _, err := store.AutoPotion(ctx, 999999); !errors.Is(err, ErrNotFound) {
				t.Errorf("an unknown character: %v, want ErrNotFound", err)
			}
			if err := store.SetAutoPotion(ctx, 999999, want); !errors.Is(err, ErrNotFound) {
				t.Errorf("saving for an unknown character: %v, want ErrNotFound", err)
			}
		})
	}
}
