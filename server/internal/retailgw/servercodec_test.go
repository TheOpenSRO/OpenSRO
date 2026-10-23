package retailgw

import (
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// serveCodec runs a gateway.Server with the retail codec and handle on a free
// port and returns its address.
func serveCodec(t *testing.T, cfg ServerCodecConfig, handle gateway.Handler) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	srv := &gateway.Server{Addr: addr, Handle: handle, Codec: NewServerCodec(cfg),
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	done := make(chan struct{})
	go func() { _ = srv.ListenAndServe(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	for range 100 {
		c, err := net.Dial("tcp", addr)
		if err == nil {
			c.Close()
			return addr
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("listener did not start")
	return ""
}

// TestServerCodecHandshakeAndMessages: the Go retail client runs the full
// handshake against a gateway.Server speaking the retail codec, then
// messages go both ways -- encrypted and plain, and a massive one.
func TestServerCodecHandshakeAndMessages(t *testing.T) {
	for _, flags := range []byte{0, proto.RetailFlagBlowfish | proto.RetailFlagSecurity} {
		var mu sync.Mutex
		var logged []uint16
		cfg := ServerCodecConfig{
			Flags:   flags,
			Encrypt: func(op uint16, _ []byte) bool { return op == 0xB0B0 },
			Massive: func(op uint16) bool { return op == OpPatchReply },
			Log: func(fromServer bool, op uint16, _ []byte) {
				mu.Lock()
				defer mu.Unlock()
				if !fromServer {
					logged = append(logged, op)
				}
			},
		}
		addr := serveCodec(t, cfg, func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			switch p.Opcode {
			case OpIdentity:
				return sess.Send(&proto.Packet{Opcode: OpIdentity, Data: EncodeIdentity(GatewayModule, 0)})
			case 0x7070:
				if err := sess.Send(&proto.Packet{Opcode: 0xB0B0, Data: append([]byte("echo:"), p.Data...)}); err != nil {
					return err
				}
				return sess.Send(&proto.Packet{Opcode: OpPatchReply, Data: make([]byte, 5000)})
			}
			return nil
		})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		c, err := DialClient(ctx, addr, ClientInfo{ContentID: 22, Version: 1})
		if err != nil {
			t.Fatalf("flags 0x%02x: handshake: %v", flags, err)
		}
		name, err := c.ReadIdentity()
		if err != nil || name != GatewayModule {
			t.Fatalf("flags 0x%02x: identity %q, %v", flags, name, err)
		}
		if err := c.Send(0x7070, []byte("hi"), true); err != nil {
			t.Fatal(err)
		}
		m, err := c.Expect(0xB0B0)
		if err != nil || string(m.Payload) != "echo:hi" {
			t.Fatalf("flags 0x%02x: echo %q, %v", flags, m.Payload, err)
		}
		if !m.Encrypted && flags == 0 {
			t.Errorf("0xB0B0 was asked encrypted")
		}
		m, err = c.Expect(OpPatchReply)
		if err != nil || !m.Massive || len(m.Payload) != 5000 {
			t.Fatalf("massive: %+v, %v", m, err)
		}
		c.Close()
		cancel()
		mu.Lock()
		defer mu.Unlock()
		if len(logged) < 2 || logged[0] != OpIdentity || logged[1] != 0x7070 {
			t.Errorf("flags 0x%02x: logged %x, want the identity then 0x7070 (the handshake is the codec's)", flags, logged)
		}
	}
}

// TestServerCodecRefusesMessagesBeforeTheHandshake: anything but 0x5000 /
// 0x9000 before the handshake ends the session (READ 0x4b1dd2).
func TestServerCodecRefusesMessagesBeforeTheHandshake(t *testing.T) {
	called := false
	addr := serveCodec(t, ServerCodecConfig{}, func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		called = true
		return nil
	})
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	// A plain 0x2001 with zero security bytes, before any handshake.
	if _, err := conn.Write([]byte{0, 0, 0x01, 0x20, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(conn); err != nil {
		t.Fatalf("the server should hang up: %v", err)
	}
	if called {
		t.Error("a handler saw a message from before the handshake")
	}
}
