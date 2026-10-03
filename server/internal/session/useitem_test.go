package session

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/storage"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
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

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, nil, nil, nil, nil, nil, nil, nil))
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

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mp, nil, nil, nil, nil, nil, nil))
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
// 153.75 -> 153. Before round 496 the handler restored exactly 120.
//
// Since round 509 it lands through the queue: a step of 153/5 = 30 at once
// (HP 230) and 4 x 30 = 120 still queued. Param1 unscaled would step 24.
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

	potions := NewPotionQueue()
	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, potions, nil, nil, nil, nil))
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
	if res.RestoredHP != 30 || res.HP != 230 || res.MaxHP != 359 {
		t.Errorf("restored %d HP to %d/%d at once, want 30 to 230/359 (153/5; 153 = 120 * 1.02^9 * (1 + 30/416))", res.RestoredHP, res.HP, res.MaxHP)
	}
	if after, _ := chars.GetByID(ctx, c.ID); after.HP != 230 {
		t.Errorf("stored HP = %d, want 230", after.HP)
	}
	if got := queuedFor(potions, c.ID, potionPoolHP); got != 120 {
		t.Errorf("queued HP = %d, want the other four steps, 4 x 30 = 120", got)
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
//   - The bag item fails ExpandInventory's kind-0 test against a 50-slot bag
//     (a 63-slot array: 32 > 77 - 63) and is refused with 0x18fe, kept. (A
//     bag of 32 or fewer takes it: TestUseBagExpansionItem, round 633.)
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

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), svc, nil, nil, nil, nil, nil), StorageHandler(chars, svc, nil))
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

// ExpandInventory's kind-0 test (0x4e195f..0x4e1989) against the engine's
// array (the bag + 13 equipment) and the default cap 77: a 50-slot bag takes
// at most 14 more, so the real item's 32 never fits it; a 32-slot bag takes
// exactly 32 (77); the test server's 96 takes nothing.
func TestBagExpansionAllowedFollowsExpandInventory(t *testing.T) {
	for _, tc := range []struct {
		bag, slots int
		want       bool
	}{
		{50, inventory.InventoryAdditionSlots, false}, {50, 14, true}, {50, 15, false}, {50, 1, true},
		{32, inventory.InventoryAdditionSlots, true}, {33, inventory.InventoryAdditionSlots, false},
		{inventory.MaxBagSlots, 1, false},
	} {
		if got := bagExpansionAllowed(tc.bag, tc.slots); got != tc.want {
			t.Errorf("bagExpansionAllowed(%d, %d) = %v, want %v", tc.bag, tc.slots, got, tc.want)
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
	// hurt leaves HP at 20 and MP at 20 and empties the potion queue before
	// every use, so every accepted potion lands its first step: nothing ticks
	// the queue here, and the steps earlier potions left in it would
	// otherwise carry the pool past the maximum, where the engine queues
	// nothing (round 509).
	potions := NewPotionQueue()
	hurt := func() {
		t.Helper()
		potions.drop(c.ID)
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

	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mp, nil, potions, nil, nil, nil, nil))
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
		if res := use(id); res.Error != reuseDelayRefusal {
			t.Errorf("%s: got %+v, want the 0x185b refusal %q", label, res, reuseDelayRefusal)
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

// queuedFor reads FUN_0049a110's sum for one pool under the queue's lock.
func queuedFor(q *PotionQueue, characterID int64, pool int) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.queuedLocked(characterID, pool)
}

// FUN_0049a0c0 (0x49a0c0): {amount/5, 4}, the division signed and truncated
// toward zero (`imul 0x66666667; sar edx,1; shr eax,0x1f; add eax,edx`), the
// step clamped to 1 (0x49a0e6) and to 1000000 (0x49a0f7).
func TestPotionEntryFollowsFUN0049a0c0(t *testing.T) {
	for _, tc := range []struct{ amount, step int }{
		{125, 25},          // HP_POTION_01 at level 1, Str 20
		{123, 24},          // truncated: five steps land 120, not 123
		{4, 1},             // 4/5 = 0, raised to 1: five steps land 5
		{0, 1},             // never reached (slot 308 answers 2 first), but the clamp holds
		{-7, 1},            // -7/5 = -1 toward zero, raised to 1
		{4999999, 999999},  // below the cap
		{5000000, 1000000}, // at the cap
		{9000000, 1000000}, // clamped to the cap
	} {
		e := newPotionEntry(tc.amount)
		if e.step != tc.step || e.count != 4 {
			t.Errorf("newPotionEntry(%d) = {%d, %d}, want {%d, 4}", tc.amount, e.step, e.count, tc.step)
		}
	}
}

// FUN_0049a5b0's two paths and FUN_0049a510's tick, on the queue alone:
//
//   - HP is queued while pool + queued does not EXCEED the maximum (0x49a768
//     `jg` skips), so the boundary queues; MP only while it stays BELOW
//     (0x49a7d4 `jge` skips), so the boundary does not.
//   - The tick takes one step from the HEAD entry only: a second entry
//     waits its turn, and the character leaves the queue once both lists
//     are empty.
//   - A percentage amount empties a pool's list when it alone overflows the
//     pool, otherwise cuts the list after the first entry whose step x count
//     carries cur + amount - max above zero, keeping that entry whole; it
//     lands in full at once.
func TestPotionQueueFollowsFUN0049a5b0AndFUN0049a510(t *testing.T) {
	q := NewPotionQueue()
	const a, b = 1, 2

	// HP: 100 + 0 <= 200 queues; 100 + 100 = 200 still queues (jg);
	// 100 + 200 > 200 does not.
	for i, want := range []int{25, 25, 0} {
		if hp, mp := q.landLocked(a, true, 125, 0, 100, 200, 200, 200); hp != want || mp != 0 {
			t.Errorf("HP drink %d at 100/200: landed (%d, %d) at once, want (%d, 0)", i+1, hp, mp, want)
		}
	}
	if got := queuedFor(q, a, potionPoolHP); got != 200 {
		t.Errorf("HP queued = %d, want 200 (two entries of 4 x 25)", got)
	}
	// MP: 100 + 0 < 200 queues; 100 + 100 = 200 does not (jge).
	for i, want := range []int{25, 0} {
		if hp, mp := q.landLocked(b, true, 0, 125, 200, 200, 100, 200); hp != 0 || mp != want {
			t.Errorf("MP drink %d at 100/200: landed (%d, %d) at once, want (0, %d)", i+1, hp, mp, want)
		}
	}
	if got := queuedFor(q, b, potionPoolMP); got != 100 {
		t.Errorf("MP queued = %d, want 100 (one entry of 4 x 25)", got)
	}
	// A full HP pool with nothing queued still queues (200 + 0 <= 200); a
	// full MP pool does not.
	const c = 3
	if hp, mp := q.landLocked(c, true, 125, 125, 200, 200, 200, 200); hp != 25 || mp != 0 {
		t.Errorf("an all potion at full HP and MP landed (%d, %d), want (25, 0): HP queues at the maximum, MP does not", hp, mp)
	}
	q.drop(b)
	q.drop(c)

	// The tick: head only, one step a pass. Replace a's queue with two
	// distinguishable entries.
	q.drop(a)
	q.pushLocked(a, potionPoolHP, potionEntry{step: 25, count: 4})
	q.pushLocked(a, potionPoolHP, potionEntry{step: 30, count: 4})
	q.pushLocked(a, potionPoolMP, potionEntry{step: 7, count: 4})
	for i, want := range []int{25, 25, 25, 25, 30, 30, 30, 30, 0} {
		hp, mp := q.takeLocked(a)
		if hp != want {
			t.Errorf("tick %d: HP step %d, want %d", i+1, hp, want)
		}
		wantMP := 0
		if i < 4 {
			wantMP = 7
		}
		if mp != wantMP {
			t.Errorf("tick %d: MP step %d, want %d", i+1, mp, wantMP)
		}
	}
	if len(q.characters()) != 0 {
		t.Errorf("the queue still lists %v after every step was taken", q.characters())
	}

	// The percentage trim: entries of 100, 120 and 160 queued, pool 500/1000.
	fill := func() {
		q.drop(a)
		q.pushLocked(a, potionPoolHP, potionEntry{step: 25, count: 4})
		q.pushLocked(a, potionPoolHP, potionEntry{step: 30, count: 4})
		q.pushLocked(a, potionPoolHP, potionEntry{step: 40, count: 4})
		q.pushLocked(a, potionPoolMP, potionEntry{step: 7, count: 4})
	}
	for _, tc := range []struct {
		name   string
		amount int
		want   int
	}{
		// -250 +100 +120 +160 = 130: the third entry crosses, nothing after it.
		{"crossing at the last entry keeps all three", 250, 380},
		// -150 +100 +120 = 70: the second crosses, the third is dropped.
		{"crossing at the second entry drops the third", 350, 220},
		// -350 +100 +120 +160 = 30: the third crosses, nothing dropped.
		{"crossing at the last entry, lower", 150, 380},
		// 500 + 600 - 1000 = 100 > 0: the amount alone overflows.
		{"an amount that overflows alone empties the list", 600, 0},
		// -499 +100 +120 +160 = -119 never crosses: nothing dropped.
		{"never crossing keeps every entry", 1, 380},
	} {
		fill()
		if hp, mp := q.landLocked(a, false, tc.amount, 0, 500, 1000, 500, 1000); hp != tc.amount || mp != 0 {
			t.Errorf("%s: landed (%d, %d) at once, want the whole (%d, 0)", tc.name, hp, mp, tc.amount)
		}
		if got := queuedFor(q, a, potionPoolHP); got != tc.want {
			t.Errorf("%s: HP queued = %d, want %d", tc.name, got, tc.want)
		}
		if got := queuedFor(q, a, potionPoolMP); got != 28 {
			t.Errorf("%s: the MP list (amount 0) changed: queued %d, want 28", tc.name, got)
		}
	}
}

// A queued character who is no longer in the world has the queue dropped at
// the next tick and is not healed: the engine's queue lives on the PC object
// (pc+0x1d58), which leaves with the character.
func TestPotionQueueDropsACharacterNotInTheWorld(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, _, err := chars.ApplyDamage(ctx, c.ID, 150); err != nil {
		t.Fatalf("damage: %v", err)
	}
	q := NewPotionQueue()
	q.pushLocked(c.ID, potionPoolHP, potionEntry{step: 25, count: 4})
	potionQueueTick(ctx, world.NewHub(), chars, q, RegenDeps{}, nil)
	if after, _ := chars.GetByID(ctx, c.ID); after.HP != 50 {
		t.Errorf("an offline character was healed: HP %d, want 50", after.HP)
	}
	if ids := q.characters(); len(ids) != 0 {
		t.Errorf("the offline character's queue was kept: %v", ids)
	}
}

// potionFixture is Aria -- level 1, Str 20, Int 20: 200 HP and 200 MP --
// logged in and in the world, drinking through UseItemHandler with a potion
// queue the test ticks by hand, and a stepped clock for the reuse lock.
type potionFixture struct {
	t       *testing.T
	ctx     context.Context
	chars   *character.MemStore
	inv     *inventory.MemStore
	mp      *mana.Tracker
	hub     *world.Hub
	potions *PotionQueue
	id      int64
	conn    net.Conn
	r       *bufio.Reader
	clock   time.Time
	// bag and store are what UseItemHandler is given: inv and chars, with a
	// RemoveItem and a Heal a test can make fail (round 511).
	bag   *flakyBag
	store *flakyHeal
}

// flakyBag is a bag whose RemoveItem fails while failRemove is set: the
// store error a production SQL bag can return after the handler has read the
// slot.
type flakyBag struct {
	*inventory.MemStore
	failRemove atomic.Bool
}

func (b *flakyBag) RemoveItem(ctx context.Context, characterID int64, slot, quantity int) error {
	if b.failRemove.Load() {
		return errors.New("flakyBag: RemoveItem failed")
	}
	return b.MemStore.RemoveItem(ctx, characterID, slot, quantity)
}

// flakyHeal is a character store whose Heal fails while failHeal is set.
type flakyHeal struct {
	*character.MemStore
	failHeal atomic.Bool
}

func (s *flakyHeal) Heal(ctx context.Context, characterID int64, amount, maxHP int) (int, error) {
	if s.failHeal.Load() {
		return 0, errors.New("flakyHeal: Heal failed")
	}
	return s.MemStore.Heal(ctx, characterID, amount, maxHP)
}

// The potions, real rows' kinds and Param blocks (allitems.txt on the RE box)
// but for the illustrative one.
const (
	fixtureHPPotion  = 4  // ITEM_ETC_HP_POTION_01, 3/3/1/1, Param1 120 -> 125
	fixtureMPPotion  = 11 // ITEM_ETC_MP_POTION_01, 3/3/1/2, Param3 120 -> 125
	fixtureHPSpotion = 9  // ITEM_ETC_HP_SPOTION_01, 3/3/1/1, Param2 25 (%)
	fixtureHP123     = 90 // illustrative: 3/3/1/1, Param1 118 -> 118 * (1 + 20/416) = 123.67 -> 123
)

func newPotionFixture(t *testing.T) *potionFixture {
	t.Helper()
	f := &potionFixture{t: t, ctx: context.Background(), clock: time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)}
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	useItemClock = func() time.Time { return f.clock }

	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	f.chars = character.NewMemStore()
	c, err := f.chars.Create(f.ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if c.MaxHP() != 200 || c.MaxMP() != 200 || c.HP != 200 {
		t.Fatalf("fixture: HP %d/%d, MaxMP %d; want 200/200 and 200", c.HP, c.MaxHP(), c.MaxMP())
	}
	f.id = c.ID
	items := refdata.NewMemStore()
	if err := items.ImportItems(f.ctx, []refdata.Item{
		{ID: fixtureHPPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 120, CanUse: true},
		{ID: fixtureMPPotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 2, RestoreMP: 120, CanUse: true},
		{ID: fixtureHPSpotion, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHPPct: 25, CanUse: true},
		{ID: fixtureHP123, MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, RestoreHP: 118, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	f.inv = inventory.NewMemStore(items)
	for _, id := range []int64{fixtureHPPotion, fixtureMPPotion, fixtureHPSpotion, fixtureHP123} {
		if err := f.inv.AddItem(f.ctx, c.ID, id, 10); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
	}
	f.mp = mana.NewTracker()
	f.hub = world.NewHub()
	f.potions = NewPotionQueue()
	f.bag = &flakyBag{MemStore: f.inv}
	f.store = &flakyHeal{MemStore: f.chars}

	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(f.chars, nil, f.hub),
		UseItemHandler(f.store, f.bag, items, f.mp, nil, f.potions, f.hub, nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	f.conn = dialTestServer(t, addr)
	t.Cleanup(func() { f.conn.Close() })
	f.r = bufio.NewReader(f.conn)
	if lr, err := DecodeLoginResult(f.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(f.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	return f
}

func (f *potionFixture) read() *proto.Packet {
	f.t.Helper()
	f.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(f.r, nil, nil)
	if err != nil {
		f.t.Fatalf("read: %v", err)
	}
	return p
}

func (f *potionFixture) send(op uint16, data []byte) *proto.Packet {
	f.t.Helper()
	if err := proto.Write(f.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		f.t.Fatalf("write: %v", err)
	}
	return f.read()
}

// use drinks one of item id. The reply must be the use-item result: a stats
// push left unread by an earlier tick would arrive here instead, so a tick
// that pushed when the test said it would not fails loudly.
func (f *potionFixture) use(id int64) *UseItemResult {
	f.t.Helper()
	slot, _ := f.stack(id)
	if slot < 0 {
		f.t.Fatalf("item %d is not in the bag", id)
	}
	p := f.send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode())
	if p.Opcode != OpUseItemResult {
		f.t.Fatalf("got opcode %#x where the use-item reply belongs (a stray push?)", p.Opcode)
	}
	res, err := DecodeUseItemResult(p.Data)
	if err != nil {
		f.t.Fatalf("decode use result: %v", err)
	}
	return res
}

func (f *potionFixture) stack(id int64) (slot, qty int) {
	f.t.Helper()
	slots, err := f.inv.List(f.ctx, f.id)
	if err != nil {
		f.t.Fatalf("list: %v", err)
	}
	for _, sl := range slots {
		if sl.ItemID == id {
			return sl.Index, sl.Quantity
		}
	}
	return -1, 0
}

// tick is one PeriodicUpdate pass.
func (f *potionFixture) tick() {
	potionQueueTick(f.ctx, f.hub, f.chars, f.potions, RegenDeps{Mana: f.mp}, nil)
}

// pushed reads the stats push a tick sent.
func (f *potionFixture) pushed() *CharacterStatsResult {
	f.t.Helper()
	p := f.read()
	if p.Opcode != OpCharacterStatsResult {
		f.t.Fatalf("got opcode %#x, want the stats push %#x", p.Opcode, OpCharacterStatsResult)
	}
	s, err := DecodeCharacterStatsResult(p.Data)
	if err != nil {
		f.t.Fatalf("decode stats push: %v", err)
	}
	return s
}

func (f *potionFixture) hp() int {
	f.t.Helper()
	c, err := f.chars.GetByID(f.ctx, f.id)
	if err != nil {
		f.t.Fatalf("get: %v", err)
	}
	return c.HP
}

func (f *potionFixture) setHP(n int) {
	f.t.Helper()
	if cur := f.hp(); cur > n {
		if _, _, err := f.chars.ApplyDamage(f.ctx, f.id, cur-n); err != nil {
			f.t.Fatalf("damage: %v", err)
		}
	} else if cur < n {
		if _, err := f.chars.Heal(f.ctx, f.id, n-cur, 200); err != nil {
			f.t.Fatalf("heal: %v", err)
		}
	}
}

func (f *potionFixture) setMP(n int) {
	f.t.Helper()
	if cur := f.mp.Current(f.id, 200); cur > n {
		if _, ok := f.mp.Spend(f.id, 200, cur-n); !ok {
			f.t.Fatalf("could not spend %d MP", cur-n)
		}
	} else if cur < n {
		f.mp.Restore(f.id, 200, n-cur)
	}
}

// ticksLand ticks once per wanted HP and checks each push and the stored
// pool, then ticks once more and checks that nothing lands.
func (f *potionFixture) ticksLand(label string, wantHP ...int) {
	f.t.Helper()
	for i, want := range wantHP {
		f.tick()
		if got := f.pushed(); int(got.HP) != want || got.MaxHP != 200 {
			f.t.Errorf("%s, tick %d: pushed HP %d/%d, want %d/200", label, i+1, got.HP, got.MaxHP, want)
		}
		if got := f.hp(); got != want {
			f.t.Errorf("%s, tick %d: stored HP %d, want %d", label, i+1, got, want)
		}
	}
	last := f.hp()
	f.tick()
	if got := f.hp(); got != last {
		f.t.Errorf("%s: a tick past the queue healed %d -> %d", label, last, got)
	}
}

// An absolute potion lands in five steps of amount/5, the first at once and
// then one per PeriodicUpdate pass (FUN_0049a0c0, 0x49a82a, FUN_0049a510 at
// 0x52acd0), each pushed to the client as a stats reply. HP_POTION_01's 125
// at 50/200 lands 25 at once and 25 on each of four ticks: 125 in all. A
// 123-point potion steps 123/5 = 24 and lands 5 x 24 = 120, the engine's
// truncation. Before round 509 the whole amount landed at once.
func TestAbsolutePotionLandsInFiveStepsOneASecond(t *testing.T) {
	f := newPotionFixture(t)

	f.setHP(50)
	res := f.use(fixtureHPPotion)
	if res.Error != "" || res.RestoredHP != 25 || res.HP != 75 || res.Remaining != 9 {
		t.Fatalf("HP_POTION_01 at 50/200: got %+v, want 25 restored at once, HP 75, 9 left", res)
	}
	f.ticksLand("HP_POTION_01", 100, 125, 150, 175)
	if got := f.hp(); got != 175 {
		t.Errorf("HP_POTION_01 landed %d in all, want 125 (5 x 25)", got-50)
	}

	f.clock = f.clock.Add(potionReuseAbsoluteChina)
	f.setHP(50)
	res = f.use(fixtureHP123)
	if res.Error != "" || res.RestoredHP != 24 || res.HP != 74 {
		t.Fatalf("the 123-point potion at 50/200: got %+v, want 24 restored at once, HP 74", res)
	}
	f.ticksLand("the 123-point potion", 98, 122, 146, 170)
	if got := f.hp(); got != 170 {
		t.Errorf("the 123-point potion landed %d in all, want 120 (5 x 24, not 123)", got-50)
	}
}

// A percentage potion lands in full at once (FUN_0049a5b0's flag-0 path,
// 0x49a71a) and queues nothing: HP_SPOTION_01's 25% of 200 is 50.
func TestPercentagePotionLandsInFullAtOnce(t *testing.T) {
	f := newPotionFixture(t)
	f.setHP(50)
	res := f.use(fixtureHPSpotion)
	if res.Error != "" || res.RestoredHP != 50 || res.HP != 100 || res.Remaining != 9 {
		t.Fatalf("HP_SPOTION_01 at 50/200: got %+v, want 50 restored at once, HP 100, 9 left", res)
	}
	if ids := f.potions.characters(); len(ids) != 0 {
		t.Errorf("a percentage potion queued steps: %v", ids)
	}
	f.ticksLand("HP_SPOTION_01")
}

// A potion drunk at full HP is SPENT, not refused: slot 308 answers 1 after
// FUN_004ef450 whatever landed (0x49b996), and the HP entry is still queued,
// because 200 + 0 does not exceed 200 (0x49a768 `jg`). So damage taken in the
// next four seconds is healed by it. An MP potion at full MP is spent too but
// queues nothing (0x49a7d4 `jge`).
//
// NEGATIVE: before round 509 both were refused with "no need for that right
// now" and kept.
func TestPotionAtFullPoolIsSpent(t *testing.T) {
	f := newPotionFixture(t)

	res := f.use(fixtureHPPotion)
	if res.Error != "" {
		t.Fatalf("an HP potion at full HP was refused: %q; the engine spends it", res.Error)
	}
	if res.RestoredHP != 0 || res.HP != 200 {
		t.Errorf("an HP potion at full HP: restored %d to %d, want 0 to 200", res.RestoredHP, res.HP)
	}
	if _, qty := f.stack(fixtureHPPotion); qty != 9 || res.Remaining != 9 {
		t.Errorf("an HP potion at full HP: %d left (reply %d), want 9 -- spent", qty, res.Remaining)
	}
	res = f.use(fixtureMPPotion)
	if res.Error != "" {
		t.Fatalf("an MP potion at full MP was refused: %q; the engine spends it", res.Error)
	}
	if _, qty := f.stack(fixtureMPPotion); qty != 9 || res.RestoredMP != 0 {
		t.Errorf("an MP potion at full MP: %d left, restored %d; want 9 left, 0 restored", qty, res.RestoredMP)
	}

	// The HP entry is there; the MP one is not.
	f.setHP(100)
	f.setMP(100)
	f.ticksLand("the potion drunk at full HP, after damage", 125, 150, 175, 200)
	if got := f.mp.Current(f.id, 200); got != 100 {
		t.Errorf("the MP potion drunk at full MP restored MP later: %d, want 100", got)
	}
}

// With the pool plus what is queued already past the maximum, the engine
// queues nothing and lands nothing (0x49a768 `jg`), yet still spends the
// potion (0x49b996). At 190/200 the first HP_POTION_01 queues (190 <= 200) and
// its first step fills the pool; 1.1 s later the second meets 200 + 100 > 200,
// is spent and queues nothing. After damage to 50 only the first potion's four
// steps land.
func TestPotionNotQueuedPastTheMaximum(t *testing.T) {
	f := newPotionFixture(t)
	f.setHP(190)
	res := f.use(fixtureHPPotion)
	if res.Error != "" || res.RestoredHP != 10 || res.HP != 200 {
		t.Fatalf("HP_POTION_01 at 190/200: got %+v, want 10 restored at once (clamped), HP 200", res)
	}
	f.clock = f.clock.Add(potionReuseAbsoluteChina)
	res = f.use(fixtureHPPotion)
	if res.Error != "" || res.RestoredHP != 0 || res.Remaining != 8 {
		t.Fatalf("HP_POTION_01 at 200/200 with 100 queued: got %+v, want no error, nothing restored, 8 left", res)
	}
	if got := queuedFor(f.potions, f.id, potionPoolHP); got != 100 {
		t.Errorf("queued HP = %d, want only the first potion's 100", got)
	}
	f.setHP(50)
	f.ticksLand("after the potion past the maximum", 75, 100, 125, 150)
}

// slowHeal is a character store whose first Heal for slowID closes entered
// and then waits for release: a database round trip that has not come back.
type slowHeal struct {
	*character.MemStore
	slowID  int64
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (s *slowHeal) Heal(ctx context.Context, characterID int64, amount, maxHP int) (int, error) {
	if characterID == s.slowID {
		s.once.Do(func() {
			close(s.entered)
			<-s.release
		})
	}
	return s.MemStore.Heal(ctx, characterID, amount, maxHP)
}

// LOCKING (round 511): the queue-wide mu is not held across a store call, so
// one character's store call holds up no other character's drink, no step
// taken on its own, and no listing. Aria's drink is held inside Heal -- a SQL
// round trip in production -- while Bea drinks, Bea's queue steps, and the
// tick's listing runs; all three must finish while Aria's Heal is still held.
// Aria's own step must still wait for her drink -- her turn IS held across
// her store calls, as the engine runs both on the PC's thread -- and land
// after it. The steps here are called directly; a tick pass's own wait is
// TestPotionQueueTickStuckInAStoreCallHoldsUpNoOtherDrink.
//
// NEGATIVE: round 509 held the queue's one lock across the whole drink, so
// Bea's drink and the listing waited for Aria's Heal.
func TestPotionQueueHoldsNoQueueWideLockAcrossAStoreCall(t *testing.T) {
	ctx := context.Background()
	mem := character.NewMemStore()
	aria, err := mem.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create Aria: %v", err)
	}
	bea, err := mem.Create(ctx, 2, "Bea")
	if err != nil {
		t.Fatalf("create Bea: %v", err)
	}
	for _, id := range []int64{aria.ID, bea.ID} {
		if _, _, err := mem.ApplyDamage(ctx, id, 150); err != nil {
			t.Fatalf("damage: %v", err)
		}
	}
	chars := &slowHeal{MemStore: mem, slowID: aria.ID, entered: make(chan struct{}), release: make(chan struct{})}
	var once sync.Once
	letGo := func() { once.Do(func() { close(chars.release) }) }
	var wg sync.WaitGroup
	defer wg.Wait()
	defer letGo()
	const wait = 2 * time.Second

	q := NewPotionQueue()
	ariaDrink := make(chan error, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _, _, _, err := q.drink(ctx, chars, nil, aria.ID, true, 125, 0, 200, 200)
		ariaDrink <- err
	}()
	select {
	case <-chars.entered:
	case <-time.After(wait):
		t.Fatal("Aria's drink never reached Heal")
	}

	// Aria's step waits for her drink.
	ariaStep := make(chan string, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		c, changed, err := q.step(ctx, chars, nil, aria.ID)
		if err != nil || !changed || c == nil {
			ariaStep <- fmt.Sprintf("Aria's step: %+v, changed %v, err %v", c, changed, err)
			return
		}
		ariaStep <- fmt.Sprintf("HP %d", c.HP)
	}()

	// Bea drinks and steps while Aria's Heal is held.
	bea1 := make(chan string, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		newHP, _, gotHP, _, err := q.drink(ctx, chars, nil, bea.ID, true, 125, 0, 200, 200)
		if err != nil || newHP != 75 || gotHP != 25 {
			bea1 <- fmt.Sprintf("Bea's drink at 50/200: HP %d, %d at once, err %v; want 75, 25", newHP, gotHP, err)
			return
		}
		c, changed, err := q.step(ctx, chars, nil, bea.ID)
		if err != nil || !changed || c == nil || c.HP != 100 {
			bea1 <- fmt.Sprintf("Bea's step: %+v, changed %v, err %v; want HP 100", c, changed, err)
			return
		}
		bea1 <- ""
	}()
	select {
	case msg := <-bea1:
		if msg != "" {
			t.Error(msg)
		}
	case <-time.After(wait):
		t.Errorf("Bea's drink and step did not finish in %v while Aria's Heal was held: a lock is held across the store call", wait)
	}

	listed := make(chan []int64, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		listed <- q.characters()
	}()
	select {
	case <-listed:
	case <-time.After(wait):
		t.Errorf("the tick's listing did not finish in %v while Aria's Heal was held", wait)
	}

	select {
	case msg := <-ariaStep:
		t.Errorf("Aria's step ran while her drink was held in Heal (%s); the two must not interleave", msg)
	case <-time.After(100 * time.Millisecond):
	}

	letGo()
	select {
	case err := <-ariaDrink:
		if err != nil {
			t.Errorf("Aria's drink: %v", err)
		}
	case <-time.After(wait):
		t.Fatal("Aria's drink did not finish after Heal was released")
	}
	select {
	case msg := <-ariaStep:
		// 50 + 25 at once, then one step of 25.
		if msg != "HP 100" {
			t.Errorf("Aria's step after her drink: %s, want HP 100", msg)
		}
	case <-time.After(wait):
		t.Fatal("Aria's step did not finish after her drink")
	}
}

// The tick pass (round 511, potionQueueTick's note): a pass stuck in one
// character's store call holds up no other character's drink and no listing,
// but the pass itself -- sequential, and run synchronously by RunPotionQueue
// -- waits, and so does that character's own drink. Aria has 4 x 25 queued at
// full HP, so her step lands nothing that moves a pool and the pass sends no
// stats push (a test session cannot send); her step's Heal is held. Bea, at
// 50/200 with nothing queued when the pass listed, drinks meanwhile.
//
// NEGATIVE: round 509 held the queue's one lock across the step's Heal, so
// Bea's drink and the listing waited for the pass.
func TestPotionQueueTickStuckInAStoreCallHoldsUpNoOtherDrink(t *testing.T) {
	ctx := context.Background()
	mem := character.NewMemStore()
	aria, err := mem.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create Aria: %v", err)
	}
	bea, err := mem.Create(ctx, 2, "Bea")
	if err != nil {
		t.Fatalf("create Bea: %v", err)
	}
	if _, _, err := mem.ApplyDamage(ctx, bea.ID, 150); err != nil {
		t.Fatalf("damage: %v", err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(1), aria.ID, "Aria", 1, "z", world.Position{})
	hub.Enter(gateway.NewTestSession(2), bea.ID, "Bea", 1, "z", world.Position{})
	chars := &slowHeal{MemStore: mem, slowID: aria.ID, entered: make(chan struct{}), release: make(chan struct{})}
	var once sync.Once
	letGo := func() { once.Do(func() { close(chars.release) }) }
	var wg sync.WaitGroup
	defer wg.Wait()
	defer letGo()
	const wait = 2 * time.Second

	q := NewPotionQueue()
	q.pushLocked(aria.ID, potionPoolHP, potionEntry{step: 25, count: 4})
	tickDone := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		potionQueueTick(ctx, hub, chars, q, RegenDeps{}, nil)
		close(tickDone)
	}()
	select {
	case <-chars.entered:
	case <-time.After(wait):
		t.Fatal("the pass never reached Aria's Heal")
	}

	// Aria's own drink waits for her step's turn.
	ariaDrink := make(chan error, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _, _, _, err := q.drink(ctx, chars, nil, aria.ID, true, 125, 0, 200, 200)
		ariaDrink <- err
	}()

	bea1 := make(chan string, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		newHP, _, gotHP, _, err := q.drink(ctx, chars, nil, bea.ID, true, 125, 0, 200, 200)
		if err != nil || newHP != 75 || gotHP != 25 {
			bea1 <- fmt.Sprintf("Bea's drink at 50/200: HP %d, %d at once, err %v; want 75, 25", newHP, gotHP, err)
			return
		}
		bea1 <- ""
	}()
	select {
	case msg := <-bea1:
		if msg != "" {
			t.Error(msg)
		}
	case <-time.After(wait):
		t.Errorf("Bea's drink did not finish in %v while the pass was held in Aria's Heal", wait)
	}

	listed := make(chan []int64, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		listed <- q.characters()
	}()
	select {
	case ids := <-listed:
		if len(ids) != 2 {
			t.Errorf("the listing while the pass was held: %v, want Aria and Bea", ids)
		}
	case <-time.After(wait):
		t.Errorf("a listing did not finish in %v while the pass was held in Aria's Heal", wait)
	}

	// The disclosed wait: the pass and Aria's drink are both still held.
	select {
	case <-tickDone:
		t.Error("the pass finished while Aria's Heal was held; potionQueueTick's note says it waits -- update the note")
	case err := <-ariaDrink:
		t.Errorf("Aria's drink finished (err %v) while her step held her turn in Heal; the two must not interleave", err)
	case <-time.After(100 * time.Millisecond):
	}

	letGo()
	select {
	case <-tickDone:
	case <-time.After(wait):
		t.Fatal("the pass did not finish after Heal was released")
	}
	select {
	case err := <-ariaDrink:
		if err != nil {
			t.Errorf("Aria's drink: %v", err)
		}
	case <-time.After(wait):
		t.Fatal("Aria's drink did not finish after her step")
	}
	if after, _ := mem.GetByID(ctx, aria.ID); after.HP != 200 {
		t.Errorf("Aria at full HP: %d after the pass and her drink, want 200", after.HP)
	}
	if after, _ := mem.GetByID(ctx, bea.ID); after.HP != 75 {
		t.Errorf("Bea: %d after her drink, want 75 (the held pass listed only Aria)", after.HP)
	}
}

// SPEND FIRST (round 511): a potion the server fails to remove heals nothing,
// now or later. The reply is "using failed", the potion is kept, nothing is
// queued, the ticks land nothing, and the kind is not locked: once the bag
// works again the same potion is drunk at the same instant, as if the failed
// use had never happened.
//
// NEGATIVE: round 509 drank before RemoveItem, so the failed use landed 25 at
// once and queued four more steps of 25.
func TestPotionNotRemovedHealsNothing(t *testing.T) {
	f := newPotionFixture(t)
	f.setHP(50)
	f.bag.failRemove.Store(true)
	res := f.use(fixtureHPPotion)
	if res.Error != "using failed" {
		t.Fatalf("a failed removal: got %+v, want %q", res, "using failed")
	}
	if got := f.hp(); got != 50 {
		t.Errorf("a potion the server failed to remove healed at once: HP %d, want 50", got)
	}
	if _, qty := f.stack(fixtureHPPotion); qty != 10 {
		t.Errorf("a potion the server failed to remove: %d left, want 10", qty)
	}
	if ids := f.potions.characters(); len(ids) != 0 {
		t.Fatalf("a potion the server failed to remove queued steps for %v", ids)
	}
	f.ticksLand("after the failed removal")
	if got := f.hp(); got != 50 {
		t.Errorf("a potion the server failed to remove healed later: HP %d, want 50", got)
	}

	f.bag.failRemove.Store(false)
	res = f.use(fixtureHPPotion)
	if res.Error != "" || res.RestoredHP != 25 || res.HP != 75 || res.Remaining != 9 {
		t.Fatalf("the same potion at the same instant, bag working: got %+v; want 25 at once, HP 75, 9 left (the failed use locks nothing)", res)
	}
	f.ticksLand("the potion drunk after the failed removal", 100, 125, 150, 175)
}

// A drink whose heal fails leaves the queue as it was (round 511): the entry
// an absolute drink pushed is dropped, and the entries a percentage drink
// trimmed come back. Through the handler the potion is handed back, nothing
// lands then or on the ticks after, and the kind is not locked.
//
// NEGATIVE: round 509 left the pushed entry queued and the trim made, so a
// potion reported as "healing failed" and kept went on to heal four times.
func TestPotionDrinkThatFailsLeavesTheQueueAsItWas(t *testing.T) {
	ctx := context.Background()
	mem := character.NewMemStore()
	c, err := mem.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, _, err := mem.ApplyDamage(ctx, c.ID, 150); err != nil {
		t.Fatalf("damage: %v", err)
	}
	chars := &flakyHeal{MemStore: mem}
	chars.failHeal.Store(true)
	q := NewPotionQueue()

	// Nothing queued before: 50 + 0 <= 200 queues {25, 4}, and the failed
	// heal takes it back out.
	if _, _, _, _, err := q.drink(ctx, chars, nil, c.ID, true, 125, 0, 200, 200); err == nil {
		t.Fatal("an absolute drink succeeded with a failing Heal")
	}
	if ids := q.characters(); len(ids) != 0 {
		t.Errorf("a failed absolute drink left a queue for %v", ids)
	}

	// One entry of 4 x 30 queued before: it is kept, the failed drink's is not.
	q.pushLocked(c.ID, potionPoolHP, potionEntry{step: 30, count: 4})
	if _, _, _, _, err := q.drink(ctx, chars, nil, c.ID, true, 125, 0, 200, 200); err == nil {
		t.Fatal("an absolute drink succeeded with a failing Heal")
	}
	if got := queuedFor(q, c.ID, potionPoolHP); got != 120 {
		t.Errorf("after a failed absolute drink: HP queued %d, want the earlier 120 alone", got)
	}
	// A percentage 200 at 50/200 overflows alone (50 + 200 - 200 > 0) and
	// would empty the list; failed, the list comes back whole.
	if _, _, _, _, err := q.drink(ctx, chars, nil, c.ID, false, 200, 0, 200, 200); err == nil {
		t.Fatal("a percentage drink succeeded with a failing Heal")
	}
	if got := queuedFor(q, c.ID, potionPoolHP); got != 120 {
		t.Errorf("after a failed percentage drink: HP queued %d, want the earlier 120 back", got)
	}
	if after, _ := mem.GetByID(ctx, c.ID); after.HP != 50 {
		t.Errorf("the failed drinks healed: HP %d, want 50", after.HP)
	}

	// Through the handler.
	f := newPotionFixture(t)
	f.setHP(50)
	f.store.failHeal.Store(true)
	res := f.use(fixtureHPPotion)
	if res.Error != "healing failed" {
		t.Fatalf("a failed heal: got %+v, want %q", res, "healing failed")
	}
	if _, qty := f.stack(fixtureHPPotion); qty != 10 {
		t.Errorf("the potion whose heal failed was not handed back: %d left, want 10", qty)
	}
	if ids := f.potions.characters(); len(ids) != 0 {
		t.Fatalf("the potion whose heal failed left steps queued for %v", ids)
	}
	f.store.failHeal.Store(false)
	f.ticksLand("after the failed heal")
	if got := f.hp(); got != 50 {
		t.Errorf("the potion whose heal failed healed later: HP %d, want 50", got)
	}
	res = f.use(fixtureHPPotion)
	if res.Error != "" || res.RestoredHP != 25 || res.HP != 75 || res.Remaining != 9 {
		t.Fatalf("the same potion at the same instant, heal working: got %+v; want 25 at once, HP 75, 9 left", res)
	}
}

// ---- The player's dead state, the server half (round 549) ----

// A step queued on a dead character lands nothing and the list goes: the
// engine's ApplyHPMPDelta refuses a life state other than 1 (`cmp al,0x1` at
// 0x4a87e8) and its death path empties both lists (GObjPC::FUN_004e67b0), so
// nothing a kill left queued -- or a drink racing it -- heals the dead.
func TestPotionQueueTickLandsNothingOnTheDead(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, _, err := chars.ApplyDamage(ctx, c.ID, 1<<30); err != nil {
		t.Fatalf("damage: %v", err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(5490), c.ID, "Aria", 1, "jangan", world.Position{})
	hub.SetLifeState(c.ID, world.LifeAlive, world.LifeDead, time.Now())
	q := NewPotionQueue()
	q.pushLocked(c.ID, potionPoolHP, potionEntry{step: 25, count: 4})
	potionQueueTick(ctx, hub, chars, q, RegenDeps{}, nil)
	if after, _ := chars.GetByID(ctx, c.ID); after.HP != 0 {
		t.Errorf("a dead character was healed: HP %d, want 0", after.HP)
	}
	if ids := q.characters(); len(ids) != 0 {
		t.Errorf("the dead character's queue was kept: %v", ids)
	}
}

// A dead character's OpUseItem is refused and the potion kept: Item_HandleUseItem
// answers 0x1889 unless GetLifeState is 1 (0x510ca6 / 0x510cd0). Revived, the
// same potion lands.
func TestUseItemIsRefusedWhileDead(t *testing.T) {
	f := newPotionFixture(t)
	f.setHP(100)
	if !f.hub.SetLifeState(f.id, world.LifeAlive, world.LifeDead, time.Now()) {
		t.Fatal("Aria could not be marked dead")
	}
	if res := f.use(fixtureHPPotion); res.Error != deadRefusal {
		t.Fatalf("a dead character's potion answered %+v, want the refusal %q", res, deadRefusal)
	}
	if _, qty := f.stack(fixtureHPPotion); qty != 10 {
		t.Errorf("the refused potion was spent: %d left, want 10", qty)
	}
	if f.hp() != 100 {
		t.Errorf("the refused potion healed: HP %d, want 100", f.hp())
	}
	if !f.hub.SetLifeState(f.id, world.LifeDead, world.LifeAlive, time.Time{}) {
		t.Fatal("Aria could not be revived")
	}
	if res := f.use(fixtureHPPotion); res.Error != "" || res.RestoredHP <= 0 {
		t.Errorf("the revived character's potion answered %+v, want a heal", res)
	}
}

// Round 633: the bag expansion item (ITEM_MALL_INVENTORY_ADDITION, 24365,
// Param1 32, Param2 0) grows the character's own bag now that it has one.
// From a 32-slot bag (one page) the engine's kind-0 test passes (32 + 13 + 32
// = 77, the default cap): the item is spent, the bag is 64 (two pages), and
// the bag list says so. A second use from 64 fails the test (64 + 13 + 32 >
// 77): refused with 0x18fe and kept, the bag still 64.
func TestUseBagExpansionItem(t *testing.T) {
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
	const bagAddition = 24365
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: bagAddition, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 32, RestoreHPPct: 0, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetCapacityFunc(inventory.BagCapacity(chars, 32))
	if err := inv.AddItem(ctx, c.ID, bagAddition, 2); err != nil {
		t.Fatalf("add bag items: %v", err)
	}
	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, nil, nil, nil, nil), InventoryHandler(chars, inv, nil))
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
	held := func() (slot, n int) {
		t.Helper()
		slots, err := inv.List(ctx, c.ID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		slot = -1
		for _, sl := range slots {
			if sl.ItemID == bagAddition {
				if slot < 0 {
					slot = sl.Index
				}
				n += sl.Quantity
			}
		}
		return slot, n
	}
	use := func() *UseItemResult {
		t.Helper()
		slot, _ := held()
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		return res
	}
	bagSize := func() int {
		t.Helper()
		res, err := DecodeStorageListResult(send(OpInventoryList, (&CharacterNameRequest{Name: "Aria"}).Encode()).Data)
		if err != nil || res.Error != "" {
			t.Fatalf("list: %v %+v", err, res)
		}
		return res.Capacity
	}
	if got := bagSize(); got != 32 {
		t.Fatalf("the bag starts at %d, want 32", got)
	}
	if res := use(); res.Error != "" {
		t.Fatalf("the first expansion from 32: refused %q", res.Error)
	}
	if _, n := held(); n != 1 {
		t.Errorf("%d expansion items left after one use, want 1", n)
	}
	if got := bagSize(); got != 64 {
		t.Errorf("after one expansion the bag is %d, want 64", got)
	}
	if res := use(); res.Error != errStorageExpansionRefused {
		t.Errorf("the second expansion from 64: %+v, want the 0x18fe refusal", res)
	}
	if _, n := held(); n != 1 {
		t.Errorf("the refused item was spent: %d left, want 1", n)
	}
	if got := bagSize(); got != 64 {
		t.Errorf("after the refusal the bag is %d, want 64", got)
	}
}

// Rounds 633-635 integration review: the bag expansion grows the CONFIGURED
// size, not the reach an item held past it raises (inventory.SetKeepHeld).
// With -inventory-size lowered to 32 while an item sits in slot 60 (reach 61),
// the expansion from 32 passes the engine's test and stores 64 -- not 61 + 32,
// and not the 0x18fe refusal that testing 61 would give.
func TestBagExpansionGrowsTheConfiguredSizeNotTheReach(t *testing.T) {
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
	const bagAddition, sword = 24365, 71
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: bagAddition, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 17, RestoreHP: 32, RestoreHPPct: 0, CanUse: true},
		{ID: sword, MaxStack: 1},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	inv.SetCapacityFunc(inventory.BagCapacity(chars, 96))
	inv.SetKeepHeld(nil)
	if err := inv.AddItem(ctx, c.ID, sword, 1); err != nil {
		t.Fatal(err)
	}
	if err := inv.MoveItem(ctx, c.ID, 0, 60); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItem(ctx, c.ID, bagAddition, 1); err != nil {
		t.Fatal(err)
	}
	inv.SetCapacityFunc(inventory.BagCapacity(chars, 32)) // the operator lowers the size
	if got := inventory.CapacityOf(ctx, inv, c.ID); got != 61 {
		t.Fatalf("reach %d, want 61", got)
	}
	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, nil, nil, nil, nil))
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
	res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: 0}).Encode()).Data)
	if err != nil || res.Error != "" {
		t.Fatalf("the expansion from a configured 32: %v %+v", err, res)
	}
	if got, _ := chars.InventorySize(ctx, c.ID); got != 64 {
		t.Errorf("stored size %d after the expansion, want 32 + 32 = 64", got)
	}
}
