package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/storage"
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

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, nil, nil))
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
// MP_POTION_01 (11, 3/3/1/2) still work. Since round 498 the bag expansion is
// refused by its own path, with the engine's 0x18fe (useExpansion).
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

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mp, nil))
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
		want string
	}{
		{"return scroll 3/3/3/1", returnScroll, "that cannot be used"},
		{"bag expansion 3/3/13/17", bagExpansion, errStorageExpansionRefused},
		{"pet HP potion 3/3/1/4", petHPPotion, "that cannot be used"},
		{"berserk potion 3/3/1/8", berserkPotion, "that cannot be used"},
	} {
		reopenRoom()
		before, _ := chars.GetByID(ctx, c.ID)
		mpBefore := mp.Current(c.ID, maxMP)
		if res := use(tc.id); res.Error != tc.want {
			t.Errorf("%s: got %+v, want the refusal %q", tc.name, res, tc.want)
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

// potionRestore is GObjPC::FUN_0049aa70 (round 496, read from srv.asm
// 0x49aa70..0x49ac42): an absolute amount is Param * 1.02^(Level-1) *
// (1 + stat/416), truncated toward zero by _ftol2_sse (0x9fbb40), and the
// percentage pair is read only when Param1 and Param3 are both zero. Each
// expected value is worked by hand in its comment. The Param blocks are the
// real rows' (allitems.txt on the RE box) except the two marked illustrative.
func TestPotionRestoreFollowsFUN0049aa70(t *testing.T) {
	for _, tc := range []struct {
		name              string
		p1, p2, p3, p4    int
		level, str, intel int
		maxHP, maxMP      int
		wantHP, wantMP    int
	}{
		// HP_POTION_01 at level 1, Str 20: 120 * 1.02^0 * (1 + 20/416)
		// = 120 * 1.048077 = 125.77 -> 125.
		{"HP_POTION_01, level 1, Str 20", 120, 0, 0, 0, 1, 20, 20, 200, 200, 125, 0},
		// HP_POTION_03 at level 50, Str 100: 370 * 1.02^49 (2.638812) *
		// (1 + 100/416) (1.240385) = 370 * 3.273142 = 1211.06 -> 1211.
		{"HP_POTION_03, level 50, Str 100", 370, 0, 0, 0, 50, 100, 20, 5000, 5000, 1211, 0},
		// The MP twin reads Int, not Str: MP_POTION_02 at level 30, Int 55:
		// 220 * 1.02^29 (1.775845) * (1 + 55/416) (1.132212) = 442.34 -> 442.
		{"MP_POTION_02, level 30, Int 55", 0, 0, 220, 0, 30, 999, 55, 5000, 5000, 0, 442},
		// ALL_POTION_01 at level 10, Str 30, Int 40: 1.02^9 = 1.195093;
		// HP 120 * 1.195093 * 1.072115 = 153.75 -> 153,
		// MP 120 * 1.195093 * 1.096154 = 157.20 -> 157.
		{"ALL_POTION_01, level 10, Str 30, Int 40", 120, 0, 120, 0, 10, 30, 40, 1000, 1000, 153, 157},
		// HP_SPOTION_01 (Param2 25, the rest zero): 25% of the maximum, not
		// scaled by level or stat: 359 * float32(0.25) = 89.75 -> 89.
		{"HP_SPOTION_01, percentage only", 0, 25, 0, 0, 10, 30, 40, 359, 500, 89, 0},
		// ALL_SPOTION_01 (20 / 20): HP 359 * float32(0.2) = 71.8 -> 71,
		// MP 500 * float32(0.2) = 100.0000015 -> 100.
		{"ALL_SPOTION_01, both percentages", 0, 20, 0, 20, 10, 30, 40, 359, 500, 71, 100},
		// Illustrative: the fraction is rounded to a float before the multiply
		// (0x49aaef fstp DWORD), and float32(0.7) = 0.69999999, so 70% of 100
		// is 69 -- integer arithmetic would say 70.
		{"70% of 100 is 69 (float32 fraction)", 0, 70, 0, 0, 1, 20, 20, 100, 100, 69, 0},
		// Illustrative: an absolute amount beside a percentage -- the
		// percentage is never read. 125 as in the first case, not 625.
		{"Param1 set: Param2 ignored", 120, 50, 0, 0, 1, 20, 20, 1000, 1000, 125, 0},
		// Param3 alone also takes the absolute path: Param2 is ignored and
		// the HP amount is Param1 * ... = 0.
		{"Param3 set: Param2 ignored, HP 0", 0, 50, 120, 0, 1, 20, 20, 1000, 1000, 0, 125},
	} {
		hp, mp := potionRestore(tc.p1, tc.p2, tc.p3, tc.p4, tc.level, tc.str, tc.intel, tc.maxHP, tc.maxMP)
		if hp != tc.wantHP || mp != tc.wantMP {
			t.Errorf("%s: potionRestore = (%d, %d), want (%d, %d)", tc.name, hp, mp, tc.wantHP, tc.wantMP)
		}
	}
}

// A potion heals what the engine computes, not the row's Param1 (round 496).
// A level-10 character with Str 30 (MaxHP 30 * 10 * 1.02^9 = 359) at 200 HP
// drinks HP_POTION_01 (3/3/1/1, Param1 120): 120 * 1.02^9 * (1 + 30/416) =
// 153.75 -> 153, below the 159 missing, so 153 lands. Before round 496 the
// handler restored exactly 120.
func TestUseItemScalesPotionByLevelAndStr(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := chars.SetLeveling(ctx, c.ID, 10, 0, 0, 30, 30); err != nil {
		t.Fatalf("set leveling: %v", err)
	}
	c, _ = chars.GetByID(ctx, c.ID)
	if c.MaxHP() != 359 {
		t.Fatalf("MaxHP at level 10 / Str 30 = %d, want 359", c.MaxHP())
	}
	if c.HP != 200 {
		t.Fatalf("HP = %d, want the fresh character's 200", c.HP)
	}

	const hpPotion = 4
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: hpPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, c.ID, hpPotion, 5); err != nil {
		t.Fatalf("add: %v", err)
	}
	slots, err := inv.List(ctx, c.ID)
	if err != nil || len(slots) != 1 {
		t.Fatalf("list: %v %+v", err, slots)
	}

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil))
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
	res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slots[0].Index)}).Encode()).Data)
	if err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("the HP potion was refused: %q", res.Error)
	}
	if res.RestoredHP != 153 || res.HP != 353 || res.MaxHP != 359 {
		t.Errorf("restored %d HP to %d/%d, want 153 to 353/359 (120 * 1.02^9 * (1 + 30/416))", res.RestoredHP, res.HP, res.MaxHP)
	}
	if after, _ := chars.GetByID(ctx, c.ID); after.HP != 353 {
		t.Errorf("stored HP = %d, want 353", after.HP)
	}
}

// The container expansion items (round 498), CGItemExpendable::UseByKind
// (0x0049c2b0) case 0x11. The kinds and Param blocks are the two real rows'
// (allitems.txt on the RE box): ITEM_MALL_WAREHOUSE_ADDITION (24366, 3/3/13/17,
// Param1 30, Param2 1 -- the warehouse) and ITEM_MALL_INVENTORY_ADDITION
// (24365, 3/3/13/17, 32 / 0 -- the bag), both MaxStack 1 and CanUse 1.
//
//   - The warehouse item grows the account's warehouse from 50 by 30 a use,
//     heals nothing and is consumed; OpStorageList then reports the new size.
//   - At 200 the next use is refused with 0x18fe (200 + 30 is not below
//     0xd3, ExpandInventory 0x4e194d) and the item is kept.
//   - The bag item fails ExpandInventory's kind-0 test against srrevamp's
//     fixed 63-slot array (32 > 77 - 63) and is refused with 0x18fe, kept.
//
// Before this round both were refused as "that cannot be used" (round 491),
// and before round 491 both healed the user by their Param1.
func TestUseWarehouseExpansionItem(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	acc, err := accounts.Add("alice", "hunter2")
	if err != nil {
		t.Fatalf("add account: %v", err)
	}
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, acc.ID, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	// Room to heal, so a use that healed would show.
	hurt, _, err := chars.ApplyDamage(ctx, c.ID, 50)
	if err != nil {
		t.Fatalf("damage: %v", err)
	}

	const (
		warehouseAddition = 24366
		bagAddition       = 24365
	)
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: warehouseAddition, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 30, RestoreHPPct: 1, CanUse: true},
		{ID: bagAddition, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 32, RestoreHPPct: 0, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	// Six warehouse items: five to reach 200, one to be refused there.
	if err := inv.AddItem(ctx, c.ID, warehouseAddition, 6); err != nil {
		t.Fatalf("add warehouse items: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, bagAddition, 1); err != nil {
		t.Fatalf("add bag item: %v", err)
	}
	warehouse := inventory.NewMemStore(items)
	warehouse.SetCapacity(storage.DefaultCapacity)
	warehouse.SetCapacityFunc(storage.CapacityOf(accounts))
	svc := &storage.Service{Bag: inv, Warehouse: warehouse, Gold: chars, Accounts: accounts, ChestSizes: accounts}

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), svc), StorageHandler(chars, svc, nil))
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
	count := func(id int64) (slot, n int) {
		t.Helper()
		slots, err := inv.List(ctx, c.ID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		slot = -1
		for _, sl := range slots {
			if sl.ItemID == id {
				if slot < 0 {
					slot = sl.Index
				}
				n += sl.Quantity
			}
		}
		return slot, n
	}
	use := func(id int64) *UseItemResult {
		t.Helper()
		slot, _ := count(id)
		if slot < 0 {
			t.Fatalf("item %d is not in the bag", id)
		}
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode use result: %v", err)
		}
		return res
	}
	capacity := func() int {
		t.Helper()
		res, err := DecodeStorageListResult(send(OpStorageList, (&CharacterNameRequest{Name: "Aria"}).Encode()).Data)
		if err != nil || res.Error != "" {
			t.Fatalf("storage list: %v %+v", err, res)
		}
		return res.Capacity
	}
	hpNow := func() int {
		t.Helper()
		cur, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		return cur.HP
	}

	if got := capacity(); got != storage.DefaultCapacity {
		t.Fatalf("a fresh account's warehouse is %d, want %d", got, storage.DefaultCapacity)
	}

	res := use(warehouseAddition)
	if res.Error != "" || res.RestoredHP != 0 || res.RestoredMP != 0 || res.Remaining != 0 {
		t.Fatalf("the warehouse item: got %+v, want success, nothing restored, 0 left in its slot", res)
	}
	if got := hpNow(); got != hurt {
		t.Errorf("the warehouse item healed: HP %d -> %d", hurt, got)
	}
	if _, n := count(warehouseAddition); n != 5 {
		t.Errorf("%d warehouse items left, want 5 (one consumed)", n)
	}
	if got := capacity(); got != 80 {
		t.Fatalf("after one warehouse item the warehouse is %d, want 80", got)
	}

	for _, want := range []int{110, 140, 170, 200} {
		if res := use(warehouseAddition); res.Error != "" {
			t.Fatalf("expanding to %d: refused %q", want, res.Error)
		}
		if got := capacity(); got != want {
			t.Fatalf("warehouse is %d, want %d", got, want)
		}
	}

	// At 200, +30 would be 230: refused with 0x18fe, the item kept.
	if res := use(warehouseAddition); res.Error != errStorageExpansionRefused {
		t.Errorf("the warehouse item at 200: got %+v, want the 0x18fe refusal %q", res, errStorageExpansionRefused)
	}
	if _, n := count(warehouseAddition); n != 1 {
		t.Errorf("the refused warehouse item was consumed: %d left, want 1", n)
	}
	if got := capacity(); got != 200 {
		t.Errorf("after the refusal the warehouse is %d, want 200", got)
	}

	// The bag item: refused with 0x18fe, kept, heals nothing.
	if res := use(bagAddition); res.Error != errStorageExpansionRefused {
		t.Errorf("the bag item: got %+v, want the 0x18fe refusal %q", res, errStorageExpansionRefused)
	}
	if _, n := count(bagAddition); n != 1 {
		t.Errorf("the refused bag item was consumed: %d left, want 1", n)
	}
	if got := hpNow(); got != hurt {
		t.Errorf("an expansion item healed: HP %d -> %d", hurt, got)
	}
}

// ExpandInventory's kind-0 test (0x4e195f..0x4e1989) against srrevamp's
// 63-slot array (50 backpack + 13 equipment) and the default cap 77: at most
// 14 slots fit, so the real item's 32 never does.
func TestBagExpansionAllowedFollowsExpandInventory(t *testing.T) {
	for _, tc := range []struct {
		slots int
		want  bool
	}{{inventory.InventoryAdditionSlots, false}, {14, true}, {15, false}, {1, true}} {
		if got := bagExpansionAllowed(tc.slots); got != tc.want {
			t.Errorf("bagExpansionAllowed(%d) = %v, want %v", tc.slots, got, tc.want)
		}
	}
}

// Round 508: slot 308's per-kind potion lock. FUN_004eb410 answers 0x185b
// while the kind's bit (TypeID4 1/2/3 -> 1/2/4) is set, and FUN_004e0ab0 sets
// it after a use for a float32 number of SECONDS (FUN_004065d0 divides the
// GetTickCount delta by 1000.0 before AJStateChanger::vslot_002 subtracts it):
// 1.1 for an absolute potion drunk by a China character, 4.1 for a percentage
// one. The kinds and Param blocks are the real rows' (allitems.txt on the RE
// box): ITEM_ETC_HP_POTION_01 (4, 3/3/1/1, 120), ITEM_ETC_MP_POTION_01 (11,
// 3/3/1/2, Param3 120), ITEM_ETC_ALL_POTION_01 (18, 3/3/1/3, 120 / 120) and
// ITEM_ETC_HP_SPOTION_01 (9, 3/3/1/1, Param2 25).
//
//   - An HP potion twice at the same instant: the second is refused with the
//     reuse-delay reason, kept, and heals nothing. Before this round it healed
//     and was consumed.
//   - An MP potion and an all potion at that same instant are allowed: each
//     kind has its own bit.
//   - The HP potion is refused 1 ms before 1.1 s and allowed at 1.1 s.
//   - A percentage HP potion shares the HP bit and locks it for 4.1 s: an
//     absolute HP potion is refused 1 ms before and allowed at 4.1 s.
func TestPotionReuseDelayPerKind(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	mp := mana.NewTracker()
	maxMP := c.MaxMP()

	t0 := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)
	clock := t0
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	useItemClock = func() time.Time { return clock }

	const (
		hpPotion  = 4
		mpPotion  = 11
		allPotion = 18
		hpSpotion = 9
	)
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: hpPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120, CanUse: true},
		{ID: mpPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 2, RestoreMP: 120, CanUse: true},
		{ID: allPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 3, RestoreHP: 120, RestoreMP: 120, CanUse: true},
		{ID: hpSpotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHPPct: 25, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	for _, id := range []int64{hpPotion, mpPotion, allPotion, hpSpotion} {
		if err := inv.AddItem(ctx, c.ID, id, 10); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
	}
	qtyOf := func(id int64) (index, qty int) {
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
	// hurt leaves HP at 20 and MP at 20 before every use, so no potion is
	// ever refused as "no need" and every accepted one restores something.
	hurt := func() {
		t.Helper()
		cur, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if cur.HP > 20 {
			if _, _, err := chars.ApplyDamage(ctx, c.ID, cur.HP-20); err != nil {
				t.Fatalf("damage: %v", err)
			}
		}
		if got := mp.Current(c.ID, maxMP); got > 20 {
			if _, ok := mp.Spend(c.ID, maxMP, got-20); !ok {
				t.Fatalf("could not spend %d MP", got-20)
			}
		}
	}

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mp, nil))
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
		slot, _ := qtyOf(id)
		if slot < 0 {
			t.Fatalf("item %d is not in the bag; the answer would be \"nothing there\"", id)
		}
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode result: %v", err)
		}
		return res
	}
	allowed := func(label string, id int64) {
		t.Helper()
		hurt()
		_, before := qtyOf(id)
		res := use(id)
		if res.Error != "" {
			t.Fatalf("%s: refused with %q, want it drunk", label, res.Error)
		}
		if res.RestoredHP <= 0 && res.RestoredMP <= 0 {
			t.Errorf("%s: restored nothing: %+v", label, res)
		}
		if _, after := qtyOf(id); after != before-1 {
			t.Errorf("%s: %d left, want %d", label, after, before-1)
		}
	}
	refused := func(label string, id int64) {
		t.Helper()
		hurt()
		_, before := qtyOf(id)
		hpBefore, _ := chars.GetByID(ctx, c.ID)
		mpBefore := mp.Current(c.ID, maxMP)
		if res := use(id); res.Error != "wait for the reuse delay" {
			t.Errorf("%s: got %+v, want the 0x185b refusal %q", label, res, "wait for the reuse delay")
		}
		if _, after := qtyOf(id); after != before {
			t.Errorf("%s: the refused potion was consumed: %d left, want %d", label, after, before)
		}
		if hpAfter, _ := chars.GetByID(ctx, c.ID); hpAfter.HP != hpBefore.HP {
			t.Errorf("%s: the refused potion healed: HP %d -> %d", label, hpBefore.HP, hpAfter.HP)
		}
		if got := mp.Current(c.ID, maxMP); got != mpBefore {
			t.Errorf("%s: the refused potion restored MP: %d -> %d", label, mpBefore, got)
		}
	}

	allowed("HP potion", hpPotion)
	refused("HP potion again at once", hpPotion)
	allowed("MP potion right after the HP potion (bit 2)", mpPotion)
	allowed("all potion right after both (bit 4)", allPotion)
	refused("MP potion again at once", mpPotion)

	clock = t0.Add(1099 * time.Millisecond)
	refused("HP potion at 1.099 s", hpPotion)
	clock = t0.Add(1100 * time.Millisecond)
	allowed("HP potion at 1.1 s", hpPotion)

	t1 := t0.Add(2200 * time.Millisecond)
	clock = t1
	allowed("percentage HP potion", hpSpotion)
	clock = t1.Add(4099 * time.Millisecond)
	refused("absolute HP potion 4.099 s after a percentage one", hpPotion)
	allowed("MP potion while the HP bit holds the percentage delay", mpPotion)
	clock = t1.Add(4100 * time.Millisecond)
	allowed("absolute HP potion 4.1 s after a percentage one", hpPotion)
}

// potionReuseBit is FUN_004eb410's jump table (0x4eb574) for the kinds slot
// 308 heals the user with, and potionReuseDelay the choice at
// 0x49b957..0x49b978: 4.1 s for any percentage potion, 1.1 s for an absolute
// one by a China (0) character, 15.1 s for any other Country.
func TestPotionReuseBitAndDelay(t *testing.T) {
	for _, tc := range []struct {
		kind   int
		bit    uint32
		wantOK bool
	}{{1, 1, true}, {2, 2, true}, {3, 4, true}, {0, 0, false}, {6, 0, false}, {11, 0, false}} {
		bit, ok := potionReuseBit(tc.kind)
		if bit != tc.bit || ok != tc.wantOK {
			t.Errorf("potionReuseBit(%d) = (%#x, %v), want (%#x, %v)", tc.kind, bit, ok, tc.bit, tc.wantOK)
		}
	}
	for _, tc := range []struct {
		country  int
		absolute bool
		want     time.Duration
	}{
		{equipment.CountryChina, true, 1100 * time.Millisecond},
		{equipment.CountryChina, false, 4100 * time.Millisecond},
		{equipment.CountryEurope, true, 15100 * time.Millisecond},
		{equipment.CountryEurope, false, 4100 * time.Millisecond},
	} {
		if got := potionReuseDelay(tc.country, tc.absolute); got != tc.want {
			t.Errorf("potionReuseDelay(%d, %v) = %v, want %v", tc.country, tc.absolute, got, tc.want)
		}
	}
}
