package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// worldTestMaxStacks is a fixed-answer inventory.MaxStackLookup for
// TestWorldFullFlow, so it doesn't need a real refdata item catalog just to
// seed one armor item into an inventory.
type worldTestMaxStacks map[int64]int

func (s worldTestMaxStacks) GetMaxStack(_ context.Context, itemID int64) (int, error) {
	return s[itemID], nil
}

func TestEntitySnapshotRoundTrip(t *testing.T) {
	want := &EntitySnapshot{CharacterID: 42, Name: "Aria", X: 1.5, Y: -2.5, Z: 3, HasArmor: true, Gender: character.GenderChinaWoman}
	got, rest, err := decodeEntitySnapshot(want.Encode())
	if err != nil {
		t.Fatalf("decodeEntitySnapshot: %v", err)
	}
	if len(rest) != 0 {
		t.Fatalf("expected no trailing bytes, got %d", len(rest))
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestEnterWorldResultRoundTripSuccess(t *testing.T) {
	want := &EnterWorldResult{
		OK: true, Zone: "jangan", X: 1, Y: 2, Z: 3, Gender: character.GenderChinaMan,
		Others: []EntitySnapshot{{CharacterID: 1, Name: "Bram", X: 4, Y: 5, Z: 6, HasArmor: true, Gender: character.GenderChinaWoman}},
	}
	got, err := DecodeEnterWorldResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEnterWorldResult: %v", err)
	}
	if got.OK != want.OK || got.Zone != want.Zone || got.X != want.X || got.Gender != want.Gender || len(got.Others) != 1 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got.Others[0] != want.Others[0] {
		t.Fatalf("got other %+v, want %+v", got.Others[0], want.Others[0])
	}
}

func TestEnterWorldResultRoundTripFailure(t *testing.T) {
	want := &EnterWorldResult{OK: false, Reason: "no such character"}
	got, err := DecodeEnterWorldResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEnterWorldResult: %v", err)
	}
	if got.OK || got.Reason != want.Reason {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestMoveRequestRoundTrip(t *testing.T) {
	want := &MoveRequest{X: 1.5, Y: -2.5, Z: 100}
	got, err := DecodeMoveRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeMoveRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestWorldFullFlow logs two accounts in on separate connections, enters
// each into the world, and confirms: the second entrant sees the first as
// an "other" in their EnterWorldResult, the first gets an OpEntityEntered
// for the second, a move from one broadcasts OpEntityMoved to the other,
// and disconnecting one sends OpEntityLeft to the other -- all through the
// real server stack over TCP.
func TestWorldFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	// Aria picks the real china_woman body at creation; Bram keeps the
	// real default -- exercises both real Gender outcomes through the
	// actual EnterWorld/EntityEntered flow, not just the standalone
	// Encode/Decode round trip above.
	if err := chars.SetGender(ctx, aria.ID, character.GenderChinaWoman); err != nil {
		t.Fatalf("setting Aria's gender: %v", err)
	}

	// Bram has real armor equipped; Aria doesn't -- exercises both real
	// HasArmor outcomes through the actual EnterWorld/EntityEntered flow,
	// not just the standalone Encode/Decode round trip above.
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), worldTestMaxStacks{200: 1})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := inv.AddItem(ctx, bram.ID, 200, 1); err != nil {
		t.Fatalf("seeding Bram's inventory: %v", err)
	}
	if err := eq.Equip(ctx, bram.ID, equipment.SlotArmor, 0); err != nil {
		t.Fatalf("equipping Bram's armor: %v", err)
	}

	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub)}
	srvCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(srvCtx)

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)

	connB := dialTestServer(t, addr)
	rB := bufio.NewReader(connB)

	sendRecv := func(conn net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	// Alice logs in and enters the world first, alone.
	resp := sendRecv(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = sendRecv(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	ewr, err := DecodeEnterWorldResult(resp.Data)
	if err != nil || !ewr.OK {
		t.Fatalf("alice enter world failed: err=%v result=%+v", err, ewr)
	}
	if len(ewr.Others) != 0 {
		t.Fatalf("alice should see nobody else yet, got %+v", ewr.Others)
	}
	if ewr.Gender != character.GenderChinaWoman {
		t.Fatalf("alice's own EnterWorldResult should carry her real gender %q, got %q", character.GenderChinaWoman, ewr.Gender)
	}

	// Bob logs in and enters the world; should see Aria as an "other".
	resp = sendRecv(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = sendRecv(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	ewr, err = DecodeEnterWorldResult(resp.Data)
	if err != nil || !ewr.OK {
		t.Fatalf("bob enter world failed: err=%v result=%+v", err, ewr)
	}
	if len(ewr.Others) != 1 || ewr.Others[0].Name != "Aria" {
		t.Fatalf("bob should see Aria, got %+v", ewr.Others)
	}
	if ewr.Others[0].HasArmor {
		t.Fatalf("Aria has nothing equipped, but bob's snapshot claims HasArmor=true: %+v", ewr.Others[0])
	}
	if ewr.Others[0].Gender != character.GenderChinaWoman {
		t.Fatalf("bob's snapshot of Aria should carry her real gender %q, got %q", character.GenderChinaWoman, ewr.Others[0].Gender)
	}
	if ewr.Gender != character.GenderChinaMan {
		t.Fatalf("bob's own EnterWorldResult should carry his real (default) gender %q, got %q", character.GenderChinaMan, ewr.Gender)
	}

	// Alice should now receive an OpEntityEntered for Bram, with HasArmor
	// true -- reflecting Bram's real equipped state, queried live from the
	// equipment store, not a hardcoded/default value.
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	entered, err := proto.Read(rA)
	if err != nil {
		t.Fatalf("reading OpEntityEntered: %v", err)
	}
	if entered.Opcode != OpEntityEntered {
		t.Fatalf("got opcode 0x%04x, want OpEntityEntered", entered.Opcode)
	}
	enteredSnap, _, err := decodeEntitySnapshot(entered.Data)
	if err != nil || enteredSnap.Name != "Bram" {
		t.Fatalf("expected EntityEntered for Bram, got %+v (err=%v)", enteredSnap, err)
	}
	if !enteredSnap.HasArmor {
		t.Fatalf("Bram has real armor equipped, but EntityEntered claims HasArmor=false: %+v", enteredSnap)
	}
	if enteredSnap.Gender != character.GenderChinaMan {
		t.Fatalf("Bram's real gender is the default %q, got %q", character.GenderChinaMan, enteredSnap.Gender)
	}

	// Bob moves; Alice should see OpEntityMoved.
	if err := proto.Write(connB, &proto.Packet{Opcode: OpMove, Data: (&MoveRequest{X: 10, Y: 20, Z: 30}).Encode()}); err != nil {
		t.Fatalf("bob move write: %v", err)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	moved, err := proto.Read(rA)
	if err != nil {
		t.Fatalf("reading OpEntityMoved: %v", err)
	}
	if moved.Opcode != OpEntityMoved {
		t.Fatalf("got opcode 0x%04x, want OpEntityMoved", moved.Opcode)
	}
	movedMsg, err := DecodeEntityMoved(moved.Data)
	if err != nil || movedMsg.X != 10 || movedMsg.Y != 20 || movedMsg.Z != 30 {
		t.Fatalf("unexpected EntityMoved: %+v (err=%v)", movedMsg, err)
	}

	// Bob disconnects; Alice should see OpEntityLeft.
	connB.Close()
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	left, err := proto.Read(rA)
	if err != nil {
		t.Fatalf("reading OpEntityLeft: %v", err)
	}
	if left.Opcode != OpEntityLeft {
		t.Fatalf("got opcode 0x%04x, want OpEntityLeft", left.Opcode)
	}
	leftMsg, err := DecodeEntityLeft(left.Data)
	if err != nil || leftMsg.CharacterID != movedMsg.CharacterID {
		t.Fatalf("unexpected EntityLeft: %+v (err=%v)", leftMsg, err)
	}
}
