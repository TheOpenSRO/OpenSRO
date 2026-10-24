package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 824 (crest.go): the four crest items -- itemdata 9268..9271, TypeID
// 3/3/12/2, Param1 guild/union, Param2 register/delete (MEASURED in the
// export) -- against the GS's checks, and the crest's bytes served back.
func crestRows() []refdata.Item {
	row := func(id int64, code string, kind, act int) refdata.Item {
		return refdata.Item{ID: id, CodeName: code, MaxStack: 10, TypeID1: 3, TypeID2: 3, TypeID3: 12, TypeID4: 2,
			RestoreHP: kind, RestoreHPPct: act, CanUse: true}
	}
	return []refdata.Item{
		row(9268, "ITEM_ETC_GUILD_CREST_USER", 1, 1),
		row(9269, "ITEM_ETC_GUILD_CREST_DELETE", 1, 2),
		row(9270, "ITEM_ETC_UNION_CREST_USER", 2, 1),
		row(9271, "ITEM_ETC_UNION_CREST_DELETE", 2, 2),
	}
}

func TestRound824CrestItems(t *testing.T) {
	rows := crestRows()
	for _, r := range rows {
		union, register, ok := crestItem(&r)
		if !ok || union != (r.RestoreHP == 2) || register != (r.RestoreHPPct == 1) {
			t.Fatalf("%s: union %v register %v ok %v", r.CodeName, union, register, ok)
		}
	}
	potion := refdata.Item{TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 1, RestoreHPPct: 1}
	if _, _, ok := crestItem(&potion); ok {
		t.Fatal("a potion is not a crest item")
	}
}

func TestRound824CrestUse(t *testing.T) {
	guilds := guild.NewMemStore()
	h := newPillHarnessWith(t, crestRows(), testGuildHandler(t, nil, guilds, nil))
	ctx := context.Background()
	pixels := bytes.Repeat([]byte{0x2a}, guild.CrestBytes)
	use := func(id int64, withPixels bool) *UseItemResult {
		t.Helper()
		slot, _ := h.qty(id)
		req := &UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}
		if withPixels {
			req.Option, req.Pixels = UseOptionCrest, pixels
		}
		res, err := DecodeUseItemResult(h.send(OpUseItem, req.Encode()).Data)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	refused := func(what string, r *UseItemResult, code uint16) {
		t.Helper()
		if r.Error == "" || r.Code != code {
			t.Fatalf("%s: %+v, want code %#x", what, r, code)
		}
	}
	// Not in a guild: 0x4c0d, the item kept.
	refused("no guild", use(9268, true), crestErrNotInGuild)
	if _, q := h.qty(9268); q != 5 {
		t.Fatalf("a refused use took the item (%d left)", q)
	}
	g, err := guilds.Create(ctx, "Crested", h.char, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	// Level 1: 0x4c4a.
	refused("level 1", use(9268, true), crestErrLevel)
	// Level 4 (points and gold enough for three level-ups).
	if err := guilds.AddPoints(ctx, g.ID, h.char, 1_000_000); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := guilds.LevelUp(ctx, h.char, true, 1<<40, func(int64) error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	// A delete with no crest: 0x4c4f.
	refused("delete with none", use(9269, false), crestErrNone)
	// A register without the bytes is malformed.
	if r := use(9268, false); r.Error == "" {
		t.Fatal("a register without its bytes was taken")
	}
	// The register: rev 1, one item spent.
	if r := use(9268, true); r.Error != "" || r.ItemID != 9268 || r.Remaining != 4 {
		t.Fatalf("register: %+v", r)
	}
	if rev, px, _ := guilds.Crest(ctx, g.ID); rev != 1 || !bytes.Equal(px, pixels) {
		t.Fatalf("stored crest rev %d", rev)
	}
	if p := guildPlateOf(ctx, h.char); p.CrestRev != 1 {
		t.Fatalf("the plate cache's rev %d", p.CrestRev)
	}
	// The bytes are served for the current revision only.
	get := func(rev uint32) []byte {
		b := []byte{CrestKindGuild}
		b = binary.LittleEndian.AppendUint32(b, uint32(g.ID))
		b = binary.LittleEndian.AppendUint32(b, rev)
		p := h.send(OpCrestGet, b)
		if p.Opcode != OpCrestData {
			t.Fatalf("reply %#04x", p.Opcode)
		}
		return p.Data
	}
	if d := get(1); len(d) != 10+guild.CrestBytes || d[9] != 1 || !bytes.Equal(d[10:], pixels) {
		t.Fatalf("crest data % x", d[:10])
	}
	if d := get(7); len(d) != 10 || d[9] != 0 {
		t.Fatalf("a stale revision: % x", d)
	}
	// A second register: 0x4c4e.
	refused("register over one", use(9268, true), crestErrExists)
	// A union's: below level 5, 0x4c4a.
	refused("union below 5", use(9270, true), crestErrLevel)
	// The delete: rev 0.
	if r := use(9269, false); r.Error != "" || r.Remaining != 4 {
		t.Fatalf("delete: %+v", r)
	}
	if rev, _, _ := guilds.Crest(ctx, g.ID); rev != 0 {
		t.Fatalf("rev after delete %d", rev)
	}
	// Level 5: a union's goes on to the union test -- OpenSRO forms none.
	if _, err := guilds.LevelUp(ctx, h.char, true, 1<<40, func(int64) error { return nil }); err != nil {
		t.Fatal(err)
	}
	refused("no union", use(9270, true), crestErrNoUnion)
}

func TestRound824GuildCrestUpdateBytes(t *testing.T) {
	b := EncodeGuildCrestUpdate(0x01020304, "Ab", 5)
	want := []byte{1, 4, 3, 2, 1, 2, 0, 'A', 'b', 5, 0, 0, 0}
	if !bytes.Equal(b, want) {
		t.Fatalf("0x3257 % x", b)
	}
}
