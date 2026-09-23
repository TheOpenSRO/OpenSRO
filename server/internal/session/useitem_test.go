package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The wire format must survive a round trip, and an older/empty tail must not
// blow up the decoder.
func TestUseItemRoundTrip(t *testing.T) {
	req := &UseItemRequest{CharacterName: "Aria", InventorySlot: 7}
	gotReq, err := DecodeUseItemRequest(req.Encode())
	if err != nil {
		t.Fatalf("DecodeUseItemRequest: %v", err)
	}
	if gotReq.CharacterName != "Aria" || gotReq.InventorySlot != 7 {
		t.Fatalf("got %+v, want Aria/7", gotReq)
	}

	res := &UseItemResult{HP: 180, MaxHP: 220, MP: 90, MaxMP: 104, RestoredHP: 120, RestoredMP: 0, Remaining: 4}
	gotRes, err := DecodeUseItemResult(res.Encode())
	if err != nil {
		t.Fatalf("DecodeUseItemResult: %v", err)
	}
	if *gotRes != *res {
		t.Fatalf("got %+v, want %+v", gotRes, res)
	}

	fail := &UseItemResult{Error: "that cannot be used"}
	gotFail, err := DecodeUseItemResult(fail.Encode())
	if err != nil || gotFail.Error != "that cannot be used" {
		t.Fatalf("got %+v (err %v), want the error preserved", gotFail, err)
	}
}

// An item whose CanUse bit is clear is refused before anything else is
// weighed, as Item_HandleUseItem (0x00510980) refuses it with 0x183e
// CANNOT_BE_USED when vtable slot 0xe0 (IGObj::CanUse, flags bit 8) answers
// zero (round 489). The item is not consumed and heals nothing.
//
// The refused item's restore amounts are illustrative, not a real row's. What
// matters is that they are non-zero: a non-usable row's Param block can read
// as restore amounts (7001, an alchemy stone, exports RestoreHP 11 from column
// 118), and before this gate such an item passed the "restores nothing" check,
// healed the player and was eaten. A potion (CanUse set) still works.
func TestUseItemRefusesAnItemWhoseCanUseIsClear(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, _, err := chars.ApplyDamage(ctx, c.ID, 50); err != nil {
		t.Fatalf("damage: %v", err)
	}

	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 7001, MaxStack: 500, RestoreHP: 13, RestoreHPPct: 3, RestoreMP: 35, CanUse: false},
		// An HP potion, ITEM_ETC_HP_POTION_01's kind (3/3/1/1): since round
		// 491 only a recovery kind restores anything.
		{ID: 4, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	for _, id := range []int64{7001, 4} {
		if err := inv.AddItem(ctx, c.ID, id, 5); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
	}
	slotOf := func(id int64) (index, qty int) {
		t.Helper()
		slots, err := inv.List(ctx, c.ID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		for _, sl := range slots {
			if sl.ItemID == id {
				return sl.Index, sl.Quantity
			}
		}
		return -1, 0
	}

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	use := func(slot int) *UseItemResult {
		t.Helper()
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode result: %v", err)
		}
		return res
	}

	before, _ := chars.GetByID(ctx, c.ID)
	stoneSlot, _ := slotOf(7001)
	if stoneSlot < 0 {
		t.Fatal("item 7001 is not in the bag; the refusal below would be \"nothing there\"")
	}
	if res := use(stoneSlot); res.Error != "that item cannot be used" {
		t.Errorf("an item whose CanUse is clear got %+v, want the 0x183e refusal %q", res, "that item cannot be used")
	}
	if _, qty := slotOf(7001); qty != 5 {
		t.Errorf("the refused item was consumed: %d left, want 5", qty)
	}
	if after, _ := chars.GetByID(ctx, c.ID); after.HP != before.HP {
		t.Errorf("the refused item healed: HP %d -> %d", before.HP, after.HP)
	}

	potionSlot, _ := slotOf(4)
	if potionSlot < 0 {
		t.Fatal("item 4 is not in the bag")
	}
	res := use(potionSlot)
	if res.Error != "" {
		t.Fatalf("a potion (CanUse set) was refused: %q", res.Error)
	}
	if res.RestoredHP <= 0 || res.Remaining != 4 {
		t.Errorf("potion: restored %d HP with %d left, want > 0 and 4", res.RestoredHP, res.Remaining)
	}
}

// Only a recovery kind restores the user's HP/MP (round 491). The engine picks
// an item's use by its TID -- CGItemExpendable::DoJob (0x0049aca0) switches on
// TypeID3, and only case 1's slot-308 branch (0x0049b710) reads the Param block
// as HP/MP for the user -- while the exporter emits columns 118..124 as
// RestoreHP..RestoreMPPct for every row. Before this round a CanUse item of any
// other kind healed from its Param1 and was consumed.
//
// Every refused item below is a real row's kind, id and Param block
// (allitems.txt on the RE box): ITEM_ETC_SCROLL_RETURN_01 (61, 3/3/3/1, 30000 /
// 1), ITEM_MALL_INVENTORY_ADDITION (24365, 3/3/13/17, 32 / 0), the pet HP
// potion ITEM_ETC_COS_HP_POTION_01 (2143, 3/3/1/4, 360 -- recovery family, but
// DoJob sends TypeID4 4 to the pet, slot 327) and ITEM_EVENT_HWAN_POTION
// (24993, 3/3/1/8, 5 -- slot 308 sends TypeID4 8 to AddHwanCount). Each is
// refused, keeps its stack and restores nothing. HP_POTION_01 (4, 3/3/1/1) and
// MP_POTION_01 (11, 3/3/1/2) still work.
func TestUseItemRestoresOnlyForRecoveryKinds(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	// Room to heal, so a refusal cannot be the "no need" answer.
	hurtHP, _, err := chars.ApplyDamage(ctx, c.ID, 50)
	if err != nil {
		t.Fatalf("damage: %v", err)
	}
	mp := mana.NewTracker()
	maxMP := c.MaxMP()
	lowMP, ok := mp.Spend(c.ID, maxMP, maxMP/2)
	if !ok || maxMP/2 < 1 {
		t.Fatalf("could not spend half of %d MP", maxMP)
	}
	// reopenRoom undoes whatever an earlier case restored, so each case's own
	// HP/MP and stack checks pin its own item: without the gate the return
	// scroll heals to full, and every later case would otherwise fail only on
	// the error string.
	reopenRoom := func() {
		t.Helper()
		cur, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if cur.HP > hurtHP {
			if _, _, err := chars.ApplyDamage(ctx, c.ID, cur.HP-hurtHP); err != nil {
				t.Fatalf("re-damage: %v", err)
			}
		}
		if got := mp.Current(c.ID, maxMP); got > lowMP {
			if _, ok := mp.Spend(c.ID, maxMP, got-lowMP); !ok {
				t.Fatalf("could not re-spend %d MP", got-lowMP)
			}
		}
	}

	const (
		returnScroll  = 61
		bagExpansion  = 24365
		petHPPotion   = 2143
		berserkPotion = 24993
		hpPotion      = 4
		mpPotion      = 11
	)
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: returnScroll, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 1, RestoreHP: 30000, RestoreHPPct: 1, CanUse: true},
		{ID: bagExpansion, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 32, CanUse: true},
		{ID: petHPPotion, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 4, RestoreHP: 360, CanUse: true},
		{ID: berserkPotion, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 8, RestoreHP: 5, CanUse: true},
		{ID: hpPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120, CanUse: true},
		{ID: mpPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 2, RestoreMP: 120, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	stock := map[int64]int{returnScroll: 5, bagExpansion: 1, petHPPotion: 5, berserkPotion: 5, hpPotion: 5, mpPotion: 5}
	for _, id := range []int64{returnScroll, bagExpansion, petHPPotion, berserkPotion, hpPotion, mpPotion} {
		if err := inv.AddItem(ctx, c.ID, id, stock[id]); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
	}
	slotOf := func(id int64) (index, qty int) {
		t.Helper()
		slots, err := inv.List(ctx, c.ID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		for _, sl := range slots {
			if sl.ItemID == id {
				return sl.Index, sl.Quantity
			}
		}
		return -1, 0
	}

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mp))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	use := func(id int64) *UseItemResult {
		t.Helper()
		slot, _ := slotOf(id)
		if slot < 0 {
			t.Fatalf("item %d is not in the bag; the answer would be \"nothing there\"", id)
		}
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode result: %v", err)
		}
		return res
	}

	for _, tc := range []struct {
		name string
		id   int64
	}{
		{"return scroll 3/3/3/1", returnScroll},
		{"bag expansion 3/3/13/17", bagExpansion},
		{"pet HP potion 3/3/1/4", petHPPotion},
		{"berserk potion 3/3/1/8", berserkPotion},
	} {
		reopenRoom()
		before, _ := chars.GetByID(ctx, c.ID)
		mpBefore := mp.Current(c.ID, maxMP)
		if res := use(tc.id); res.Error != "that cannot be used" {
			t.Errorf("%s: got %+v, want the refusal %q", tc.name, res, "that cannot be used")
		}
		if _, qty := slotOf(tc.id); qty != stock[tc.id] {
			t.Errorf("%s: the refused item was consumed: %d left, want %d", tc.name, qty, stock[tc.id])
		}
		if after, _ := chars.GetByID(ctx, c.ID); after.HP != before.HP {
			t.Errorf("%s: the refused item healed: HP %d -> %d", tc.name, before.HP, after.HP)
		}
		if got := mp.Current(c.ID, maxMP); got > mpBefore {
			t.Errorf("%s: the refused item restored MP: %d -> %d", tc.name, mpBefore, got)
		}
	}

	res := use(hpPotion)
	if res.Error != "" {
		t.Fatalf("an HP potion (3/3/1/1) was refused: %q", res.Error)
	}
	if res.RestoredHP <= 0 || int(res.Remaining) != stock[hpPotion]-1 {
		t.Errorf("HP potion: restored %d HP with %d left, want > 0 and %d", res.RestoredHP, res.Remaining, stock[hpPotion]-1)
	}
	res = use(mpPotion)
	if res.Error != "" {
		t.Fatalf("an MP potion (3/3/1/2) was refused: %q", res.Error)
	}
	if res.RestoredMP <= 0 || int(res.Remaining) != stock[mpPotion]-1 {
		t.Errorf("MP potion: restored %d MP with %d left, want > 0 and %d", res.RestoredMP, res.Remaining, stock[mpPotion]-1)
	}
}

// restoresUserPool is DoJob's dispatch (0x0049aca0) read as a predicate: the
// recovery family is TypeID3 1 under 3/3, minus the TypeID4s DoJob diverts to
// slots 327 (4/5/6/7/9) and 330 (10) and the one slot 308 diverts to
// AddHwanCount (8).
func TestRestoresUserPoolFollowsDoJobDispatch(t *testing.T) {
	kind := func(t1, t2, t3, t4 int) *refdata.Item {
		return &refdata.Item{TypeID1: t1, TypeID2: t2, TypeID3: t3, TypeID4: t4}
	}
	for t4 := 0; t4 < 32; t4++ {
		want := true
		switch t4 {
		case 4, 5, 6, 7, 8, 9, 10:
			want = false
		}
		if got := restoresUserPool(kind(3, 3, 1, t4)); got != want {
			t.Errorf("3/3/1/%d: restoresUserPool = %v, want %v", t4, got, want)
		}
	}
	for _, k := range [][4]int{
		{3, 3, 2, 6},  // ITEM_ETC_CURE_ALL_01: a cure pill (slot 308's TypeID3-2 arm)
		{3, 3, 13, 6}, // ITEM_MALL_RESURRECTION_*: UseByKind case 6, revives the dead only
		{3, 1, 14, 1}, // a cash avatar: equipment, not a CGItemExpendable
		{3, 2, 1, 2},  // ITEM_COS_P_SEOWON_SCROLL: a pet summoner, not a CGItemExpendable
		{0, 0, 0, 0},  // a hand-built item with no kind
	} {
		if restoresUserPool(kind(k[0], k[1], k[2], k[3])) {
			t.Errorf("%d/%d/%d/%d restores the user's pool; DoJob sends it elsewhere", k[0], k[1], k[2], k[3])
		}
	}
}
