package session

import (
	"bufio"
	"context"
	"net"
	"os"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/friend"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func friendTestDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

func openTestFriendStore(t *testing.T) *friend.SQLStore {
	t.Helper()
	s, err := friend.OpenSQLStore(friendTestDSN())
	if err != nil {
		t.Fatalf("friend.OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating friend tables: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestFriendRequestRequestRoundTrip(t *testing.T) {
	want := &FriendRequestRequest{CharacterName: "Aria", TargetName: "Bram"}
	got, err := DecodeFriendRequestRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeFriendRequestRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestFriendAcceptRequestRoundTrip(t *testing.T) {
	want := &FriendAcceptRequest{CharacterName: "Bram", RequesterID: 1}
	got, err := DecodeFriendAcceptRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeFriendAcceptRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestFriendListResultRoundTrip(t *testing.T) {
	want := &FriendListResult{
		Friends: []FriendSnapshot{{CharacterID: 2, Name: "Bram", Online: true}},
	}
	got, err := DecodeFriendListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeFriendListResult: %v", err)
	}
	if len(got.Friends) != 1 || got.Friends[0] != want.Friends[0] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestFriendPendingListResultRoundTrip(t *testing.T) {
	want := &FriendPendingListResult{
		Requests: []PendingRequestSnapshot{{RequesterID: 1, RequesterName: "Aria"}},
	}
	got, err := DecodeFriendPendingListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeFriendPendingListResult: %v", err)
	}
	if len(got.Requests) != 1 || got.Requests[0] != want.Requests[0] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestFriendFullFlow logs two accounts in on separate connections, has
// both enter the world (so OpFriendRequest can find its target), sends a
// request from Aria to Bram, confirms Bram gets a live
// OpFriendRequestReceived, has Bram list pending requests and accept by
// ID, confirms Aria gets a live OpFriendAccepted, confirms both sides'
// friends lists show each other as online, then has Aria remove Bram and
// confirms both lists are empty again.
func TestFriendFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")

	friends := openTestFriendStore(t)
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), FriendHandler(chars, friends, hub))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := doSend(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("aria enter world failed: err=%v result=%+v", err, ewr)
	}
	resp = doSend(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("bram enter world failed: err=%v result=%+v", err, ewr)
	}
	// Aria was already in the zone; drain her EntityEntered broadcast for Bram.
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil {
		t.Fatalf("draining EntityEntered: %v", err)
	}

	resp = doSend(connA, rA, OpFriendRequest, (&FriendRequestRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	if rr, err := DecodeFriendRequestResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("friend request failed: err=%v result=%+v", err, rr)
	}

	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	receivedPkt, err := proto.Read(rB, nil, nil)
	if err != nil || receivedPkt.Opcode != OpFriendRequestReceived {
		t.Fatalf("reading OpFriendRequestReceived: opcode=%v err=%v", receivedPkt, err)
	}
	if rr, err := DecodeFriendRequestReceived(receivedPkt.Data); err != nil || rr.RequesterName != "Aria" {
		t.Fatalf("unexpected FriendRequestReceived: %+v (err=%v)", rr, err)
	}

	resp = doSend(connB, rB, OpFriendPendingList, (&CharacterCreateRequest{Name: "Bram"}).Encode())
	pending, err := DecodeFriendPendingListResult(resp.Data)
	if err != nil || pending.Error != "" || len(pending.Requests) != 1 || pending.Requests[0].RequesterName != "Aria" {
		t.Fatalf("unexpected pending list: err=%v result=%+v", err, pending)
	}
	requesterID := pending.Requests[0].RequesterID

	resp = doSend(connB, rB, OpFriendAccept, (&FriendAcceptRequest{CharacterName: "Bram", RequesterID: requesterID}).Encode())
	if ar, err := DecodeFriendAcceptResult(resp.Data); err != nil || !ar.OK {
		t.Fatalf("accept failed: err=%v result=%+v", err, ar)
	}

	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	acceptedPkt, err := proto.Read(rA, nil, nil)
	if err != nil || acceptedPkt.Opcode != OpFriendAccepted {
		t.Fatalf("reading OpFriendAccepted: opcode=%v err=%v", acceptedPkt, err)
	}
	if fa, err := DecodeFriendAccepted(acceptedPkt.Data); err != nil || fa.AccepterName != "Bram" {
		t.Fatalf("unexpected FriendAccepted: %+v (err=%v)", fa, err)
	}

	resp = doSend(connA, rA, OpFriendList, (&CharacterCreateRequest{Name: "Aria"}).Encode())
	listA, err := DecodeFriendListResult(resp.Data)
	if err != nil || listA.Error != "" || len(listA.Friends) != 1 || listA.Friends[0].Name != "Bram" || !listA.Friends[0].Online {
		t.Fatalf("unexpected friend list for Aria: err=%v result=%+v", err, listA)
	}
	bramID := listA.Friends[0].CharacterID

	resp = doSend(connB, rB, OpFriendList, (&CharacterCreateRequest{Name: "Bram"}).Encode())
	listB, err := DecodeFriendListResult(resp.Data)
	if err != nil || listB.Error != "" || len(listB.Friends) != 1 || listB.Friends[0].Name != "Aria" || !listB.Friends[0].Online {
		t.Fatalf("unexpected friend list for Bram: err=%v result=%+v", err, listB)
	}

	resp = doSend(connA, rA, OpFriendRemove, (&FriendRemoveRequest{CharacterName: "Aria", FriendID: bramID}).Encode())
	if rr, err := DecodeFriendRemoveResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("remove failed: err=%v result=%+v", err, rr)
	}

	resp = doSend(connA, rA, OpFriendList, (&CharacterCreateRequest{Name: "Aria"}).Encode())
	listA, err = DecodeFriendListResult(resp.Data)
	if err != nil || len(listA.Friends) != 0 {
		t.Fatalf("expected empty friend list after remove: err=%v result=%+v", err, listA)
	}
	resp = doSend(connB, rB, OpFriendList, (&CharacterCreateRequest{Name: "Bram"}).Encode())
	listB, err = DecodeFriendListResult(resp.Data)
	if err != nil || len(listB.Friends) != 0 {
		t.Fatalf("expected empty friend list after remove (Bram's side): err=%v result=%+v", err, listB)
	}
}

// TestFriendRequestOfflineTarget confirms sending a request to a name
// that isn't currently in the world fails cleanly, per FriendHandler's
// documented online-target requirement.
func TestFriendRequestOfflineTarget(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")

	friends := openTestFriendStore(t)
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), FriendHandler(chars, friends, hub))

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
	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	resp = send(OpFriendRequest, (&FriendRequestRequest{CharacterName: "Aria", TargetName: "Ghost"}).Encode())
	rr, err := DecodeFriendRequestResult(resp.Data)
	if err != nil || rr.OK || rr.Reason != "player not found" {
		t.Fatalf("request to offline target: err=%v result=%+v", err, rr)
	}
}
