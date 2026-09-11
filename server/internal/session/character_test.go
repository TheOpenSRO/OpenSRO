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
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func TestCharacterListRequiresAuthentication(t *testing.T) {
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	handle := gateway.Chain(LoginHandler(accounts), CharacterHandler(chars))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	// No login first -- straight to OpCharacterList.
	if err := proto.Write(conn, &proto.Packet{Opcode: OpCharacterList}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	resp, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	result, err := DecodeCharacterListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterListResult: %v", err)
	}
	if result.Error != errNotAuthenticated {
		t.Fatalf("got error %q, want %q", result.Error, errNotAuthenticated)
	}
}

// TestCharacterFullFlow logs in, then creates, lists, and deletes a
// character, all through the real server stack over TCP.
func TestCharacterFullFlow(t *testing.T) {
	accounts := account.NewMemStore()
	if _, err := accounts.Add("alice", "hunter2"); err != nil {
		t.Fatalf("seeding account: %v", err)
	}
	chars := character.NewMemStore()
	handle := gateway.Chain(LoginHandler(accounts), CharacterHandler(chars))
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

	// Log in first.
	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	loginResult, err := DecodeLoginResult(resp.Data)
	if err != nil || !loginResult.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, loginResult)
	}

	// List: should be empty.
	resp = send(OpCharacterList, nil)
	listResult, err := DecodeCharacterListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterListResult: %v", err)
	}
	if listResult.Error != "" || len(listResult.Characters) != 0 {
		t.Fatalf("expected empty character list, got %+v", listResult)
	}

	// Create one.
	resp = send(OpCharacterCreate, (&CharacterCreateRequest{Name: "Aria"}).Encode())
	createResult, err := DecodeCharacterCreateResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterCreateResult: %v", err)
	}
	if !createResult.OK {
		t.Fatalf("create failed: %+v", createResult)
	}

	// List again: should have it now.
	resp = send(OpCharacterList, nil)
	listResult, err = DecodeCharacterListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterListResult: %v", err)
	}
	if len(listResult.Characters) != 1 || listResult.Characters[0].Name != "Aria" {
		t.Fatalf("expected [Aria], got %+v", listResult.Characters)
	}
	// The summary carries the honest starting stats the server tracks.
	if got := listResult.Characters[0]; got.Level != character.StartingLevel || got.HP != character.MaxHP || got.MaxHP != character.MaxHP {
		t.Fatalf("expected level %d, HP %d/%d, got %+v", character.StartingLevel, character.MaxHP, character.MaxHP, got)
	}

	// Delete it.
	resp = send(OpCharacterDelete, (&CharacterDeleteRequest{Name: "Aria"}).Encode())
	deleteResult, err := DecodeCharacterDeleteResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterDeleteResult: %v", err)
	}
	if !deleteResult.OK {
		t.Fatalf("delete failed: %+v", deleteResult)
	}

	// List once more: empty again.
	resp = send(OpCharacterList, nil)
	listResult, err = DecodeCharacterListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterListResult: %v", err)
	}
	if len(listResult.Characters) != 0 {
		t.Fatalf("expected empty list after delete, got %+v", listResult.Characters)
	}
}

// TestCharacterCreateWithGender confirms a real, explicit gender choice at
// creation is actually applied (not just accepted and ignored), and that
// an empty/unrecognized choice falls back to the real default rather than
// failing creation.
func TestCharacterCreateWithGender(t *testing.T) {
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	handle := gateway.Chain(LoginHandler(accounts), CharacterHandler(chars))
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

	resp = send(OpCharacterCreate, (&CharacterCreateRequest{Name: "Mei", Gender: character.GenderChinaWoman}).Encode())
	createResult, err := DecodeCharacterCreateResult(resp.Data)
	if err != nil || !createResult.OK {
		t.Fatalf("create failed: err=%v result=%+v", err, createResult)
	}

	list, err := chars.ListByAccount(context.Background(), 1)
	if err != nil || len(list) != 1 {
		t.Fatalf("ListByAccount: err=%v list=%+v", err, list)
	}
	if list[0].Gender != character.GenderChinaWoman {
		t.Fatalf("got gender %q, want %q", list[0].Gender, character.GenderChinaWoman)
	}

	resp = send(OpCharacterCreate, (&CharacterCreateRequest{Name: "Bram", Gender: "not_a_real_gender"}).Encode())
	createResult, err = DecodeCharacterCreateResult(resp.Data)
	if err != nil || !createResult.OK {
		t.Fatalf("create with bogus gender should still succeed: err=%v result=%+v", err, createResult)
	}
	list, _ = chars.ListByAccount(context.Background(), 1)
	var bram *character.Character
	for _, c := range list {
		if c.Name == "Bram" {
			bram = c
		}
	}
	if bram == nil || bram.Gender != character.DefaultGender {
		t.Fatalf("expected Bram to fall back to default gender %q, got %+v", character.DefaultGender, bram)
	}
}

// startTestServer spins up a gateway.Server on an ephemeral port with the
// given handler, returning its address and a cleanup func.
func startTestServer(t *testing.T, handle gateway.Handler) (string, func()) {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	srv := &gateway.Server{Addr: addr, Handle: handle}
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe(ctx) }()

	return addr, cancel
}

func dialTestServer(t *testing.T, addr string) net.Conn {
	t.Helper()
	var conn net.Conn
	var err error
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			return conn
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("dial: %v", err)
	return nil
}
