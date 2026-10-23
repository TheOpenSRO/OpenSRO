package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 633: the bag has a per-character size, which the client pages 32 to a
// page, at most three (IFInventory 0x6b6620), and the server holds every bag
// operation to it.
//
//   - The bag list and the move reply carry the size as a trailing u16, which
//     the client's decoder reads (DecodeStorageListResult reads the same shape).
//   - A move from page 1 (slot 3) to page 2 (slot 40) succeeds at the default
//     96, and the reply lists the item in slot 40.
//   - A character sized to 36 (one page and four slots) is refused a move to
//     slot 36 -- the first locked slot -- and allowed slot 35.
//   - A character with no size of its own gets the server's default.
func TestBagPagesSizeAndMoves(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	inv := inventory.NewMemStore(nil)
	inv.SetCapacityFunc(inventory.BagCapacity(chars, inventory.DefaultBagSlots))
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := inv.MoveItem(ctx, c.ID, 0, 3); err != nil {
		t.Fatalf("seed move: %v", err)
	}

	handle := gateway.Chain(LoginHandler(accounts), InventoryHandler(chars, inv, nil), InventoryMoveHandler(chars, inv, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}

	list := func() *StorageListResult {
		t.Helper()
		res, err := DecodeStorageListResult(send(OpInventoryList, (&CharacterNameRequest{Name: "Aria"}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode list: %v", err)
		}
		return res
	}
	move := func(from, to int32) *StorageListResult {
		t.Helper()
		res, err := DecodeStorageListResult(send(OpInventoryMove, (&InventoryMoveRequest{CharacterName: "Aria", From: from, To: to}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode move: %v", err)
		}
		return res
	}

	got := list()
	if got.Error != "" || got.Capacity != inventory.DefaultBagSlots {
		t.Fatalf("the bag list: error %q, capacity %d; want the default %d", got.Error, got.Capacity, inventory.DefaultBagSlots)
	}

	moved := move(3, 40)
	if moved.Error != "" || len(moved.Slots) != 1 || moved.Slots[0].Slot != 40 {
		t.Fatalf("page 1 -> page 2: %+v, want the item in slot 40", moved)
	}
	if moved.Capacity != inventory.DefaultBagSlots {
		t.Errorf("the move reply's capacity %d, want %d", moved.Capacity, inventory.DefaultBagSlots)
	}

	// Sized to one page and four slots: 36 is locked, 35 is not.
	if err := chars.SetInventorySize(ctx, c.ID, 36); err != nil {
		t.Fatalf("size: %v", err)
	}
	if got := list(); got.Capacity != 36 {
		t.Fatalf("after sizing to 36 the list says %d", got.Capacity)
	}
	if res := move(40, 36); res.Error == "" {
		t.Errorf("a move out of a slot past the size was allowed: %+v", res)
	}
	// Bring it back in range first: slot 40 is past 36, so size 96 again,
	// move to 35, then size 36 again.
	if err := chars.SetInventorySize(ctx, c.ID, 0); err != nil {
		t.Fatalf("size: %v", err)
	}
	if res := move(40, 35); res.Error != "" {
		t.Fatalf("40 -> 35 at the default: %q", res.Error)
	}
	if err := chars.SetInventorySize(ctx, c.ID, 36); err != nil {
		t.Fatalf("size: %v", err)
	}
	if res := move(35, 36); res.Error != "invalid slot" {
		t.Errorf("a move into the first locked slot (36 of 36): %+v, want \"invalid slot\"", res)
	}
	if res := move(35, 34); res.Error != "" || res.Capacity != 36 {
		t.Errorf("a move inside the size: %+v, want success with capacity 36", res)
	}
}

// The size a list carries is the bag's own, clamped to what the client can
// page, and the default applies to a character with none stored.
func TestBagCapacityDefaultsAndClamps(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Aria")
	f := inventory.BagCapacity(chars, 45)
	if got := f(ctx, c.ID); got != 45 {
		t.Errorf("no stored size: %d, want the default 45", got)
	}
	for stored, want := range map[int]int{10: 10, 96: 96, 200: 96} {
		if err := chars.SetInventorySize(ctx, c.ID, stored); err != nil {
			t.Fatal(err)
		}
		if got := f(ctx, c.ID); got != want {
			t.Errorf("stored %d: %d, want %d", stored, got, want)
		}
	}
	if got := inventory.BagCapacity(chars, 500)(ctx, 99999); got != inventory.MaxBagSlots {
		t.Errorf("an unknown character with a 500 default: %d, want %d", got, inventory.MaxBagSlots)
	}
}

// Round 633's review: a size set below what a character already holds must
// not strand the items. With the default lowered to 32 while an item sits in
// slot 60, the bag list still reports 61 and the item can be moved back onto
// page 1; once slot 60 is empty the size falls to the configured 32. The
// wiring is cmd/server's: SetCapacityFunc(BagCapacity(...)) and SetKeepHeld.
func TestLowerSizeKeepsHeldItemsReachable(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Aria")
	inv := inventory.NewMemStore(nil)
	inv.SetCapacityFunc(inventory.BagCapacity(chars, 96))
	inv.SetKeepHeld(nil)
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatal(err)
	}
	if err := inv.MoveItem(ctx, c.ID, 0, 60); err != nil {
		t.Fatal(err)
	}
	// The operator lowers the default: the character has no size of its own.
	inv.SetCapacityFunc(inventory.BagCapacity(chars, 32))

	handle := gateway.Chain(LoginHandler(accounts), InventoryHandler(chars, inv, nil), InventoryMoveHandler(chars, inv, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *StorageListResult {
		t.Helper()
		proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil)
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		res, _ := DecodeStorageListResult(p.Data)
		return res
	}
	send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	got := send(OpInventoryList, (&CharacterNameRequest{Name: "Aria"}).Encode())
	if got.Capacity != 61 || len(got.Slots) != 1 || got.Slots[0].Slot != 60 {
		t.Fatalf("with the default lowered to 32 the list says capacity %d, slots %+v; want 61 and the item in 60", got.Capacity, got.Slots)
	}
	moved := send(OpInventoryMove, (&InventoryMoveRequest{CharacterName: "Aria", From: 60, To: 5}).Encode())
	if moved.Error != "" || moved.Slots[0].Slot != 5 {
		t.Fatalf("moving the stranded item back to page 1: %+v", moved)
	}
	if moved.Capacity != 32 {
		t.Errorf("once slot 60 is empty the size is %d, want the configured 32", moved.Capacity)
	}
}
