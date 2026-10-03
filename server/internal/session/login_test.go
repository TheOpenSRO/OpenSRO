package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

func TestLoginRequestRoundTrip(t *testing.T) {
	want := &LoginRequest{Username: "alice", Password: "hunter2"}
	got, err := DecodeLoginRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeLoginRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestLoginResultRoundTrip(t *testing.T) {
	for _, want := range []*LoginResult{
		{OK: true},
		{OK: false, Reason: "account blocked"},
	} {
		got, err := DecodeLoginResult(want.Encode())
		if err != nil {
			t.Fatalf("DecodeLoginResult: %v", err)
		}
		if *got != *want {
			t.Fatalf("got %+v, want %+v", got, want)
		}
	}
}

func TestDecodeLoginRequestTruncated(t *testing.T) {
	if _, err := DecodeLoginRequest([]byte{0x05, 0x00, 'a', 'b'}); err == nil {
		t.Fatal("expected error decoding truncated payload, got nil")
	}
}

// TestLoginEndToEnd dials a real TCP connection through gateway.Server and
// exercises the full stack: framing (proto), the login handler (session),
// and account authentication (account) together.
func TestLoginEndToEnd(t *testing.T) {
	store := account.NewMemStore()
	if _, err := store.Add("alice", "hunter2"); err != nil {
		t.Fatalf("seeding account: %v", err)
	}
	if _, err := store.Add("blocked", "pw"); err != nil {
		t.Fatalf("seeding account: %v", err)
	}
	if err := store.SetBlocked("blocked", true, "test"); err != nil {
		t.Fatalf("SetBlocked: %v", err)
	}

	srv := &gateway.Server{Addr: "127.0.0.1:0", Handle: LoginHandler(store)}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close() // ListenAndServe binds it again; just needed a free port

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	srv.Addr = addr

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

	cases := []struct {
		name    string
		req     *LoginRequest
		wantOK  bool
		wantRsn string
	}{
		{"valid credentials", &LoginRequest{Username: "alice", Password: "hunter2"}, true, ""},
		{"wrong password", &LoginRequest{Username: "alice", Password: "wrong"}, false, "invalid username or password"},
		{"blocked account", &LoginRequest{Username: "blocked", Password: "pw"}, false, "account blocked"},
	}

	r := bufio.NewReader(conn)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := proto.Write(conn, &proto.Packet{Opcode: OpLogin, Data: c.req.Encode()}, nil, nil); err != nil {
				t.Fatalf("Write: %v", err)
			}
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			resp, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("Read: %v", err)
			}
			if resp.Opcode != OpLoginResult {
				t.Fatalf("got opcode 0x%04x, want OpLoginResult", resp.Opcode)
			}
			result, err := DecodeLoginResult(resp.Data)
			if err != nil {
				t.Fatalf("DecodeLoginResult: %v", err)
			}
			if result.OK != c.wantOK || result.Reason != c.wantRsn {
				t.Fatalf("got %+v, want OK=%v Reason=%q", result, c.wantOK, c.wantRsn)
			}
		})
	}
}
