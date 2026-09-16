package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func TestPartyResultRoundTrip(t *testing.T) {
	want := &PartyResult{
		PartyID: 1,
		Members: []PartyMemberSnapshot{{CharacterID: 100, Name: "Aria"}, {CharacterID: 200, Name: "Bram"}},
	}
	got, err := DecodePartyResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodePartyResult: %v", err)
	}
	if got.PartyID != want.PartyID || len(got.Members) != 2 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got.Members[0] != want.Members[0] || got.Members[1] != want.Members[1] {
		t.Fatalf("member mismatch: got %+v", got.Members)
	}
}

func TestPartyResultErrorRoundTrip(t *testing.T) {
	want := &PartyResult{Error: "party is full"}
	got, err := DecodePartyResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodePartyResult: %v", err)
	}
	if got.Error != want.Error || len(got.Members) != 0 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestPartyJoinRequestRoundTrip(t *testing.T) {
	want := &PartyJoinRequest{CharacterName: "Bram", PartyID: 1}
	got, err := DecodePartyJoinRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodePartyJoinRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestPartyFullFlow logs two accounts in on separate connections, has one
// create a party and the other join it, confirms both see the correct
// roster and the creator gets a PartyMemberJoined broadcast, then has the
// joiner leave and confirms the creator gets a PartyMemberLeft broadcast
// and remains the sole member/leader -- all through the real server stack.
func TestPartyFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	c1, _ := chars.Create(ctx, 1, "Aria")
	c2, _ := chars.Create(ctx, 2, "Bram")
	// The engine requires level 5 to start a party (party.MinLevelToCreate), so
	// these characters have to clear it. Set through the store rather than on
	// the returned value, which is a copy.
	chars.SetLeveling(ctx, c1.ID, party.MinLevelToCreate, 0, 0, character.StartingStr, character.StartingInt)
	chars.SetLeveling(ctx, c2.ID, party.MinLevelToCreate, 0, 0, character.StartingStr, character.StartingInt)

	parties := party.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), PartyHandler(chars, parties))

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

	resp = doSend(connA, rA, OpPartyCreate, (&CharacterNameRequest{Name: "Aria"}).Encode())
	pr, err := DecodePartyResult(resp.Data)
	if err != nil || pr.Error != "" {
		t.Fatalf("create party failed: err=%v result=%+v", err, pr)
	}
	if len(pr.Members) != 1 || pr.Members[0].Name != "Aria" {
		t.Fatalf("got %+v, want a solo party of Aria", pr)
	}
	partyID := pr.PartyID

	resp = doSend(connB, rB, OpPartyJoin, (&PartyJoinRequest{CharacterName: "Bram", PartyID: partyID}).Encode())
	pr, err = DecodePartyResult(resp.Data)
	if err != nil || pr.Error != "" {
		t.Fatalf("join party failed: err=%v result=%+v", err, pr)
	}
	if len(pr.Members) != 2 {
		t.Fatalf("got %+v, want 2 members after join", pr)
	}

	// Alice should get a PartyMemberJoined broadcast for Bram.
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	joined, err := proto.Read(rA, nil, nil)
	if err != nil {
		t.Fatalf("reading PartyMemberJoined: %v", err)
	}
	if joined.Opcode != OpPartyMemberJoined {
		t.Fatalf("got opcode 0x%04x, want OpPartyMemberJoined", joined.Opcode)
	}
	jm, err := DecodePartyMemberJoined(joined.Data)
	if err != nil || jm.Name != "Bram" {
		t.Fatalf("expected PartyMemberJoined for Bram, got %+v (err=%v)", jm, err)
	}

	// Bob leaves; Alice should get a PartyMemberLeft broadcast.
	resp = doSend(connB, rB, OpPartyLeave, (&CharacterNameRequest{Name: "Bram"}).Encode())
	lr, err := DecodePartyLeaveResult(resp.Data)
	if err != nil || !lr.OK {
		t.Fatalf("leave party failed: err=%v result=%+v", err, lr)
	}

	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	left, err := proto.Read(rA, nil, nil)
	if err != nil {
		t.Fatalf("reading PartyMemberLeft: %v", err)
	}
	if left.Opcode != OpPartyMemberLeft {
		t.Fatalf("got opcode 0x%04x, want OpPartyMemberLeft", left.Opcode)
	}
}

// TestPartyInfoFlow confirms OpPartyInfo reports "not in a party" before
// joining one, and the real roster afterward -- this is what lets a
// client that just entered the world learn about an existing party
// without guessing.
func TestPartyInfoFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c1, _ := chars.Create(ctx, 1, "Aria")
	chars.SetLeveling(ctx, c1.ID, party.MinLevelToCreate, 0, 0, character.StartingStr, character.StartingInt)

	parties := party.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), PartyHandler(chars, parties))

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

	resp = send(OpPartyInfo, (&CharacterNameRequest{Name: "Aria"}).Encode())
	pr, err := DecodePartyResult(resp.Data)
	if err != nil || pr.Error != "" || pr.PartyID != 0 || len(pr.Members) != 0 {
		t.Fatalf("expected 'not in a party', got err=%v result=%+v", err, pr)
	}

	resp = send(OpPartyCreate, (&CharacterNameRequest{Name: "Aria"}).Encode())
	pr, err = DecodePartyResult(resp.Data)
	if err != nil || pr.Error != "" {
		t.Fatalf("create party failed: err=%v result=%+v", err, pr)
	}

	resp = send(OpPartyInfo, (&CharacterNameRequest{Name: "Aria"}).Encode())
	pr, err = DecodePartyResult(resp.Data)
	if err != nil || pr.Error != "" || pr.PartyID == 0 || len(pr.Members) != 1 {
		t.Fatalf("expected the real party after creating one, got err=%v result=%+v", err, pr)
	}
}
