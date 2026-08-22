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
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func TestEquipRequestRoundTrip(t *testing.T) {
	want := &EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: 3}
	got, err := DecodeEquipRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEquipRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestEquipmentResultRoundTrip(t *testing.T) {
	want := &EquipmentResult{Items: []EquippedSnapshot{{Slot: 0, ItemID: 100}}}
	got, err := DecodeEquipmentResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEquipmentResult: %v", err)
	}
	if len(got.Items) != 1 || got.Items[0] != want.Items[0] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestEquipmentFullFlow logs in, creates a character, gives it an item via
// inventory, equips it, confirms via OpEquipmentList, then unequips and
// confirms the item is back in the inventory -- all through the real
// server stack over TCP.
func TestEquipmentFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	invStore, err := inventory.OpenSQLStore(inventoryTestDSN(), stubMaxStacks{100: 1})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer invStore.Close()
	if err := invStore.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := invStore.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}

	eqStore, err := equipment.OpenSQLStore(inventoryTestDSN(), invStore)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eqStore.Close()
	if err := eqStore.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}

	handle := gateway.Chain(LoginHandler(accounts), EquipmentHandler(chars, eqStore))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
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

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp = send(OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: 0}).Encode())
	eqResult, err := DecodeEquipmentResult(resp.Data)
	if err != nil || eqResult.Error != "" {
		t.Fatalf("equip failed: err=%v result=%+v", err, eqResult)
	}

	resp = send(OpEquipmentList, (&CharacterCreateRequest{Name: "Aria"}).Encode())
	listResult, err := DecodeEquipmentResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeEquipmentResult: %v", err)
	}
	if len(listResult.Items) != 1 || listResult.Items[0].ItemID != 100 {
		t.Fatalf("got %+v, want weapon slot with item 100", listResult.Items)
	}

	resp = send(OpUnequip, (&UnequipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon}).Encode())
	unequipResult, err := DecodeEquipmentResult(resp.Data)
	if err != nil || unequipResult.Error != "" {
		t.Fatalf("unequip failed: err=%v result=%+v", err, unequipResult)
	}

	invList, err := invStore.List(ctx, c.ID)
	if err != nil {
		t.Fatalf("inv.List: %v", err)
	}
	if len(invList) != 1 || invList[0].ItemID != 100 {
		t.Fatalf("expected item back in inventory after unequip, got %+v", invList)
	}
}
