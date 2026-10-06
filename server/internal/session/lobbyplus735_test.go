package session

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// Round 735: the select list's item record carries each worn item's
// effective plus (OptLevel + advanced elixir) in the byte after its u32
// RefItemID (READ: the client's SCharacterInfo reader 0x85e620), so the
// select screen can draw the glow.
func TestLobbyListCarriesEffectivePlus(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	for _, w := range []struct {
		id   int64
		slot equipment.Slot
		inst inventory.Instance
	}{
		{4842, equipment.SlotMail, inventory.Instance{}},
		{3727, equipment.SlotWeapon, inventory.Instance{OptLevel: 7, AdvElixir: 2}},
	} {
		if err := inv.AddItemInstance(ctx, c.ID, w.id, 1, w.inst); err != nil {
			t.Fatal(err)
		}
		bag, _ := inv.List(ctx, c.ID)
		if err := eq.Equip(ctx, c.ID, w.slot, bag[0].Index); err != nil {
			t.Fatal(err)
		}
	}
	d := &LobbyDeps{Chars: chars, Eq: eq}
	rec := d.record(ctx, c, time.Now())
	if len(rec.Items) != 2 || rec.Items[0].Plus != 0 || rec.Items[1].Plus != 9 {
		t.Fatalf("items %+v, want the mail at +0 and the weapon at +9", rec.Items)
	}
	// The record's tail: academy 0, count 2, then (u32 ref, u8 plus) x2,
	// then avatar count 0.
	enc := rec.encode(nil)
	want := []byte{0, 2, 0xea, 0x12, 0, 0, 0, 0x8f, 0x0e, 0, 0, 9, 0}
	if !bytes.HasSuffix(enc, want) {
		t.Fatalf("record tail % x, want % x", enc[len(enc)-len(want):], want)
	}
	// And it reads back.
	back := decodeLobbyCharacter(&lobbyReader{b: enc})
	if back.Items[1].RefItemID != 3727 || back.Items[1].Plus != 9 {
		t.Fatalf("decoded %+v", back.Items)
	}
}
