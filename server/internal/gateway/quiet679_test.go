package gateway

import (
	"bytes"
	"context"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// Round 679's review: a session whose first packet is a Quiet opcode (the
// server list's status, the theme) logs its connected/disconnected lines at
// Debug, not Info; any other session still logs both at Info.
func TestQuietSessionsLogAtDebug(t *testing.T) {
	var out syncBuffer
	logger := slog.New(slog.NewTextHandler(&out, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	srv := &Server{Addr: addr, Logger: logger,
		Handle: func(_ context.Context, _ *Session, p *proto.Packet) error {
			if p.Opcode == 0x0007 {
				return ErrEndSession
			}
			return nil
		},
		Quiet: func(op uint16) bool { return op == 0x0007 },
	}
	go srv.ListenAndServe(ctx)
	dial := func() net.Conn {
		for i := 0; i < 100; i++ {
			if c, err := net.Dial("tcp", addr); err == nil {
				return c
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("no listener on %s", addr)
		return nil
	}
	count := func(msg string) int { return strings.Count(out.String(), msg) }
	waitFor := func(msg string, n int) {
		for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
			if count(msg) >= n {
				return
			}
		}
	}

	// A status question: nothing at Info.
	c := dial()
	if err := proto.Write(c, &proto.Packet{Opcode: 0x0007}, nil, nil); err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	c.Read(make([]byte, 1)) // ends when the server closes
	c.Close()
	time.Sleep(200 * time.Millisecond)
	if n := count("session connected") + count("session disconnected"); n != 0 {
		t.Errorf("a status question logged %d connected/disconnected lines at Info:\n%s", n, out.String())
	}

	// Any other session: both lines at Info, connected first.
	c = dial()
	if err := proto.Write(c, &proto.Packet{Opcode: 0x0001}, nil, nil); err != nil {
		t.Fatal(err)
	}
	waitFor("session connected", 1)
	c.Close()
	waitFor("session disconnected", 1)
	if count("session connected") != 1 || count("session disconnected") != 1 {
		t.Errorf("an ordinary session's lines missing:\n%s", out.String())
	}

	// A session that sends nothing still logs both.
	c = dial()
	time.Sleep(100 * time.Millisecond)
	c.Close()
	waitFor("session disconnected", 2)
	if count("session connected") != 2 || count("session disconnected") != 2 {
		t.Errorf("a silent session's lines missing:\n%s", out.String())
	}
}
