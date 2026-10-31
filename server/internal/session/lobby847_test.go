package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
)

// Round 847: the character list draws a model-switched item as the world
// does. The record names the model's row (displayRef, as the spawn record
// and 0x3038 do) and the list's own-id trailer carries the item's own id
// (OURS, LobbyItem.Own), whose glow and seal the model keeps. NEGATIVE:
// before round 847 the record named the item's own row (62652) and no
// trailer was written, so the select screen drew the item's original model.
func TestLobbyListDrawsTheSwitchedModel(t *testing.T) {
	h := newLobbyHarness(t, testCatalogue(), true)
	ctx := context.Background()
	if r := h.lobby(chinaManCreate("Sword")); !r.OK {
		t.Fatalf("create refused %#x", r.Code)
	}
	if r := h.lobby(chinaManCreate("Plain")); !r.OK {
		t.Fatalf("create refused %#x", r.Code)
	}
	list, _ := h.chars.ListByAccount(ctx, 1)
	sword, plain := findOwned(list, "Sword"), findOwned(list, "Plain")
	// The user's own item (prod, MEASURED round 843): 62652 +12 with model
	// 62220. Plain wears the same item unswitched.
	for _, c := range []struct {
		id    int64
		model int64
	}{{sword.ID, 62220}, {plain.ID, 0}} {
		if err := h.inv.AddItemInstance(ctx, c.id, 62652, 1, inventory.Instance{OptLevel: 12, Model: c.model}); err != nil {
			t.Fatal(err)
		}
		bag, _ := h.inv.List(ctx, c.id)
		idx := -1
		for _, s := range bag {
			if s.ItemID == 62652 {
				idx = s.Index
			}
		}
		if err := h.eq.Equip(ctx, c.id, equipment.SlotWeapon, idx); err != nil {
			t.Fatal(err)
		}
	}
	// The raw bytes carry the trailer: decode them as the client does.
	p := h.send(OpLobby, (&LobbyRequest{Action: LobbyList}).Encode())
	res, err := DecodeLobbyResult(p.Data)
	if err != nil || !res.OK {
		t.Fatalf("list: %v %+v", err, res)
	}
	weapon := func(name string) LobbyItem {
		for _, rec := range res.Characters {
			if rec.Name != name {
				continue
			}
			for _, it := range rec.Items {
				if it.RefItemID == 62220 || it.RefItemID == 62652 {
					return it
				}
			}
			t.Fatalf("%s's record has no sword: %+v", name, rec.Items)
		}
		t.Fatalf("%s not listed", name)
		return LobbyItem{}
	}
	if w := weapon("Sword"); w.RefItemID != 62220 || w.Plus != 12 || w.Own != 62652 {
		t.Errorf("the switched sword is listed as %+v, want the model 62220 +12 with own 62652", w)
	}
	if w := weapon("Plain"); w.RefItemID != 62652 || w.Plus != 12 || w.Own != 0 {
		t.Errorf("the plain sword is listed as %+v, want 62652 +12 and no own id", w)
	}
	// A retail reader stops after the records: the trailer is the payload's
	// last 8 bytes (u16 1, char index, item index, u32 62652).
	tail := p.Data[len(p.Data)-8:]
	if tail[0] != 1 || tail[1] != 0 || tail[6] != 0 || tail[7] != 0 || tail[4] != 0xbc || tail[5] != 0xf4 {
		t.Errorf("the payload ends % x, want the own-id trailer 01 00 <char> <item> bc f4 00 00", tail)
	}
}

// A list with no switched item ends with its last record (retail's bytes).
func TestLobbyListWithoutSwitchHasNoTrailer(t *testing.T) {
	r := &LobbyResult{Action: LobbyList, OK: true, Characters: []LobbyCharacter{{RefObjID: 1907, Name: "A",
		Items: []LobbyItem{{RefItemID: 3632, Plus: 3}}}}}
	enc := r.Encode()
	if enc[len(enc)-1] != 0 || enc[len(enc)-7] != 1 {
		t.Fatalf("payload ends % x, want the record's item then an empty avatar count", enc[len(enc)-8:])
	}
	// An Own equal to the RefItemID is no switch.
	r.Characters[0].Items[0].Own = 3632
	if again := r.Encode(); string(again) != string(enc) {
		t.Errorf("an Own naming the item itself wrote a trailer: % x", again)
	}
}
