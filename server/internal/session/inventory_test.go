package session

import (
	"bufio"
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// inventoryTestDSN points at a local PostgreSQL instance for tests.
// Override with OPENSRO_TEST_POSTGRES_DSN if your dev setup differs.
func inventoryTestDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func TestInventorySlotSnapshotRoundTrip(t *testing.T) {
	want := &InventorySlotSnapshot{Slot: 3, ItemID: 42, Quantity: 5}
	got, rest, err := decodeInventorySlotSnapshot(want.Encode())
	if err != nil {
		t.Fatalf("decodeInventorySlotSnapshot: %v", err)
	}
	if len(rest) != 0 {
		t.Fatalf("expected no trailing bytes, got %d", len(rest))
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestInventoryListResultRoundTrip(t *testing.T) {
	want := &InventoryListResult{
		Slots: []InventorySlotSnapshot{{Slot: 0, ItemID: 100, Quantity: 5}, {Slot: 1, ItemID: 200, Quantity: 1}},
	}
	got, err := DecodeInventoryListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeInventoryListResult: %v", err)
	}
	if got.Error != "" || len(got.Slots) != 2 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got.Slots[0] != want.Slots[0] || got.Slots[1] != want.Slots[1] {
		t.Fatalf("slot mismatch: got %+v", got.Slots)
	}
}

func TestInventoryListResultErrorRoundTrip(t *testing.T) {
	want := &InventoryListResult{Error: "not authenticated"}
	got, err := DecodeInventoryListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeInventoryListResult: %v", err)
	}
	if got.Error != want.Error || len(got.Slots) != 0 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// stubMaxStacks is a fixed-answer inventory.MaxStackLookup for tests.
type stubMaxStacks map[int64]int

func (s stubMaxStacks) GetMaxStack(_ context.Context, itemID int64) (int, error) {
	v, ok := s[itemID]
	if !ok {
		return 0, errors.New("no such item")
	}
	return v, nil
}

// TestInventoryFullFlow logs in, creates a character, adds an item
// server-side (simulating a future shop/drop system -- there's no wire
// opcode for this yet, see inventory.go's doc comment), then confirms
// OpInventoryList sees it, all through the real server stack over TCP.
func TestInventoryFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	invStore, err := inventory.OpenSQLStore(inventoryTestDSN(), stubMaxStacks{100: 20})
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer invStore.Close()
	if err := invStore.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory_slots: %v", err)
	}
	if err := invStore.AddItem(ctx, c.ID, 100, 5); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}

	handle := gateway.Chain(LoginHandler(accounts), InventoryHandler(chars, invStore, nil))
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

	resp = send(OpInventoryList, (&CharacterNameRequest{Name: "Aria"}).Encode())
	result, err := DecodeInventoryListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeInventoryListResult: %v", err)
	}
	if result.Error != "" {
		t.Fatalf("expected success, got error: %s", result.Error)
	}
	if len(result.Slots) != 1 || result.Slots[0].ItemID != 100 || result.Slots[0].Quantity != 5 {
		t.Fatalf("got %+v, want a single slot with 5x item 100", result.Slots)
	}
}
