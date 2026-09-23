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
		{ID: 4, MaxStack: 5000, RestoreHP: 120, CanUse: true},
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
