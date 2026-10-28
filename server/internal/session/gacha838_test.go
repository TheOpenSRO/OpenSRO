package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gacha"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// gachaItems is an item table with the archive's card, coupons and two
// prizes (MEASURED ids), looked up by id and by code.
type gachaItems map[int64]*refdata.Item

func (g gachaItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	if it, ok := g[id]; ok {
		return it, nil
	}
	return nil, fmt.Errorf("no item %d", id)
}

func (g gachaItems) GetItemByCode(_ context.Context, code string) (*refdata.Item, error) {
	for _, it := range g {
		if it.CodeName == code {
			return it, nil
		}
	}
	return nil, fmt.Errorf("no item %q", code)
}

func (g gachaItems) GetMaxStack(_ context.Context, id int64) (int, error) {
	if it, ok := g[id]; ok {
		return it.MaxStack, nil
	}
	return 1, nil
}

func newGachaItems() gachaItems {
	return gachaItems{
		9238: {ID: 9238, CodeName: "ITEM_MALL_GACHA_CARD", TypeID1: 3, TypeID2: 3, TypeID3: 14, TypeID4: 1, MaxStack: 1,
			Desc1: "ITEM_MALL_GACHA_CARD_LOSE", Desc2: "ITEM_MALL_GACHA_CARD_WIN"},
		9239: {ID: 9239, CodeName: "ITEM_MALL_GACHA_CARD_WIN", TypeID1: 3, TypeID2: 3, TypeID3: 14, TypeID4: 2, MaxStack: 1},
		9240: {ID: 9240, CodeName: "ITEM_MALL_GACHA_CARD_LOSE", TypeID1: 3, TypeID2: 3, TypeID3: 14, TypeID4: 2, MaxStack: 1},
		3705: {ID: 3705, CodeName: "ITEM_ETC_ARCHEMY_REINFORCE_PROB_UP_B_11", TypeID1: 3, TypeID2: 3, TypeID3: 10, TypeID4: 1, MaxStack: 50},
		3680: {ID: 3680, CodeName: "ITEM_ETC_RECIPE_SHIELD_B", TypeID1: 3, TypeID2: 3, TypeID3: 11, TypeID4: 1, MaxStack: 50},
		71:   {ID: 71, CodeName: "ITEM_CH_SWORD_01_A", TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, MaxStack: 1},
	}
}

// The machine gets 0x11 from the gacha map, Gori 0x12 from his code name.
func TestGachaInteractions(t *testing.T) {
	if _, ids := npcspawn.Interactions("NPC_CH_GACHA_MACHINE", npcspawn.InteractionInputs{GachaMachine: true}); !bytes.Equal(ids, []byte{0x11}) {
		t.Fatalf("the machine offers % x, want 11", ids)
	}
	if _, ids := npcspawn.Interactions("NPC_CH_GACHA_MACHINE", npcspawn.InteractionInputs{}); len(ids) != 0 {
		t.Fatalf("a machine outside the map offers % x", ids)
	}
	if _, ids := npcspawn.Interactions("NPC_CH_GACHA_OPERATOR", npcspawn.InteractionInputs{}); !bytes.Equal(ids, []byte{0x12}) {
		t.Fatalf("Gori offers % x, want 12", ids)
	}
}

// The whole flow on a socket: the draw's refusals in their order, a win and
// a loss turning the card into its coupon in place, and Gori's exchange.
func TestGachaDrawAndExchange(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	accounts.Add("Aria", "pw")
	c0, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := newGachaItems()
	inv := inventory.NewMemStore(items)
	hub := world.NewHub()
	machine := npcAt(7, 100, 0, npcspawn.FromNest)
	machine.RefID = 9251
	machine.Code = "NPC_CH_GACHA_MACHINE"
	machine.Flags, machine.Interact = npcspawn.FlagInteractions, []byte{0x11}
	gori := npcAt(8, 120, 0, npcspawn.FromNest)
	gori.Code = "NPC_CH_GACHA_OPERATOR"
	gori.Flags, gori.Interact = npcspawn.FlagInteractions, []byte{0x12}
	potion := npcAt(9, 80, 0, npcspawn.FromNest)
	potion.Code = "NPC_CH_POTION"
	potion.Flags, potion.Interact = npcspawn.FlagInteractions, []byte{1}
	installNPCsForTest(t, machine, gori, potion)
	table := gacha.Build([]gacha.Row{
		{Set: 1, RefItemID: 3705, Ratio: 120, Count: 1, GachaID: 3916},
		{Set: 2, RefItemID: 3679, Ratio: 1200, Count: 1, GachaID: 3880},
		{Set: 2, RefItemID: 3680, Ratio: 2400, Count: 1, GachaID: 3881},
		{Set: 2, RefItemID: 3681, Ratio: 1800, Count: 1, GachaID: 3882},
		{Set: 2, RefItemID: 3682, Ratio: 2100, Count: 1, GachaID: 3883},
	}, []gacha.NPCMap{{NPCRefID: 9251, WinSet: 1, LoseSet: 2}})
	var rolls []int
	rnd := func(n int) int {
		r := rolls[0]
		rolls = rolls[1:]
		return r % n
	}

	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub),
		GachaHandler(GachaDeps{Table: table, Inv: inv, Items: items, Hub: hub, Rand: rnd}))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	c.send(OpLogin, (&LoginRequest{Username: "Aria", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
		t.Fatalf("enter: %v %+v", err, er)
	}
	e, ok := hub.FindByName("Aria")
	if !ok || e.Zone != "jangan" {
		t.Skipf("the test NPCs stand in the jangan frame; Aria is in %q", e.Zone)
	}
	hub.Relocate(e.Session, world.Position{X: 100, Z: 0}, world.MoveRelocate, 0)
	// Bag: slot 0 a card, slot 1 a sword, slot 2 a second card.
	for _, id := range []int64{9238, 71, 9238} {
		if err := inv.AddItem(ctx, c0.ID, id, 1); err != nil {
			t.Fatal(err)
		}
	}
	play := func(npc uint32, gid uint32, slot byte, want []byte, what string) {
		t.Helper()
		req := binary.LittleEndian.AppendUint32(nil, npc)
		req = binary.LittleEndian.AppendUint32(req, gid)
		c.send(OpGachaPlay, append(req, slot))
		if got := c.next(OpGachaPlayResult).Data; !bytes.Equal(got, want) {
			t.Fatalf("%s: % x, want % x", what, got, want)
		}
	}
	fail := func(code uint16) []byte { return binary.LittleEndian.AppendUint16([]byte{2}, code) }

	play(potion.UID, 3916, 13, fail(0x1c0f), "an NPC without 0x11")
	play(machine.UID, 3916, 13+200, fail(0x1806), "a slot past the bag")
	play(machine.UID, 3916, 13+5, fail(0x1809), "an empty slot")
	play(machine.UID, 3916, 13+1, fail(0x1806), "a sword is not a card")
	play(machine.UID, 9999, 13, fail(2), "a GachaID the WIN set lacks")

	// Win: roll 119 < Ratio 120. The card becomes the WIN coupon in slot 0,
	// carrying {3705, 1}.
	rolls = []int{119}
	play(machine.UID, 3916, 13, []byte{1, 1}, "a win")
	// Lose: 120, then roll2 1601 -> the shield recipe (1600 < 1601 <= 4800).
	rolls = []int{120, 1601}
	play(machine.UID, 3916, 13+2, []byte{1, 0}, "a loss")
	slots, _ := inv.List(ctx, c0.ID)
	got := map[int]inventory.Slot{}
	for _, s := range slots {
		got[s.Index] = s
	}
	if s := got[0]; s.ItemID != 9239 || len(s.MagParams) != 2 || s.MagParams[0] != 3705 || s.MagParams[1] != 1 {
		t.Fatalf("slot 0 after the win: %+v, want the WIN coupon carrying {3705, 1}", s)
	}
	if s := got[2]; s.ItemID != 9240 || len(s.MagParams) != 2 || s.MagParams[0] != 3680 {
		t.Fatalf("slot 2 after the loss: %+v, want the LOSE coupon carrying 3680", s)
	}
	// A coupon is not a card.
	play(machine.UID, 3916, 13, fail(0x1806), "a coupon is not a card")

	// Gori: a machine is refused 0x1c0f; Gori turns both coupons.
	c.send(OpGachaExchange, binary.LittleEndian.AppendUint32(nil, machine.UID))
	if got := c.next(OpGachaExchangeResult).Data; !bytes.Equal(got, fail(0x1c0f)) {
		t.Fatalf("exchange at the machine: % x", got)
	}
	// A success sends nothing (s:0x4c8130); a refused draw after it is the
	// barrier that says it was handled.
	c.send(OpGachaExchange, binary.LittleEndian.AppendUint32(nil, gori.UID))
	play(machine.UID, 3916, 13+1, fail(0x1806), "the barrier after the exchange")
	slots, _ = inv.List(ctx, c0.ID)
	got = map[int]inventory.Slot{}
	for _, s := range slots {
		got[s.Index] = s
	}
	if got[0].ItemID != 3705 || got[2].ItemID != 3680 || got[1].ItemID != 71 || len(got[0].MagParams) != 0 {
		t.Fatalf("after the exchange: %+v", got)
	}
}
