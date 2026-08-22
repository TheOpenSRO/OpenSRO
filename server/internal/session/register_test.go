package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func TestRegisterRequestRoundTrip(t *testing.T) {
	want := &RegisterRequest{Username: "bob", Password: "s3cr3t"}
	got, err := DecodeRegisterRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeRegisterRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestRegisterThenLoginEndToEnd exercises registration and login together
// through gateway.Chain, over a real TCP connection: register a new
// account, then confirm the same credentials work for login and a
// duplicate registration is rejected.
func TestRegisterThenLoginEndToEnd(t *testing.T) {
	store := account.NewMemStore()
	handle := gateway.Chain(LoginHandler(store), RegisterHandler(store))
	srv := &gateway.Server{Addr: "127.0.0.1:0", Handle: handle}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe(ctx) }()

	var conn net.Conn
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
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

	// Register a brand new account.
	resp := send(OpRegister, (&RegisterRequest{Username: "newuser", Password: "hunter2"}).Encode())
	if resp.Opcode != OpRegisterResult {
		t.Fatalf("got opcode 0x%04x, want OpRegisterResult", resp.Opcode)
	}
	regResult, err := DecodeRegisterResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeRegisterResult: %v", err)
	}
	if !regResult.OK {
		t.Fatalf("registration failed: %+v", regResult)
	}

	// The same credentials should now work for login.
	resp = send(OpLogin, (&LoginRequest{Username: "newuser", Password: "hunter2"}).Encode())
	loginResult, err := DecodeLoginResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeLoginResult: %v", err)
	}
	if !loginResult.OK {
		t.Fatalf("login after registration failed: %+v", loginResult)
	}

	// Registering the same username again should fail.
	resp = send(OpRegister, (&RegisterRequest{Username: "newuser", Password: "different"}).Encode())
	regResult, err = DecodeRegisterResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeRegisterResult: %v", err)
	}
	if regResult.OK {
		t.Fatal("expected duplicate registration to fail, got OK")
	}
}
