package gateway

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func TestServerEchoesPackets(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	received := make(chan *proto.Packet, 1)
	srv := &Server{
		Addr: "127.0.0.1:0",
		Handle: func(_ context.Context, sess *Session, p *proto.Packet) error {
			received <- p
			return sess.Send(&proto.Packet{Opcode: p.Opcode + 1, Data: p.Data})
		},
	}

	// Bind on an ephemeral port ourselves so the test can dial it, since
	// ListenAndServe doesn't expose the resolved address for ":0".
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe(ctx) }()

	var conn net.Conn
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	want := &proto.Packet{Opcode: 0x6100, Data: []byte("ping")}
	if err := proto.Write(conn, want); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case got := <-received:
		if got.Opcode != want.Opcode || string(got.Data) != string(want.Data) {
			t.Fatalf("handler got %+v, want %+v", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for handler to receive packet")
	}

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reply, err := proto.Read(bufio.NewReader(conn))
	if err != nil {
		t.Fatalf("reading reply: %v", err)
	}
	if reply.Opcode != want.Opcode+1 || string(reply.Data) != "ping" {
		t.Fatalf("unexpected reply: %+v", reply)
	}
}

func TestChainCallsEachHandlerInOrder(t *testing.T) {
	var order []string
	a := Handler(func(context.Context, *Session, *proto.Packet) error {
		order = append(order, "a")
		return nil
	})
	b := Handler(func(context.Context, *Session, *proto.Packet) error {
		order = append(order, "b")
		return nil
	})

	if err := Chain(a, b)(context.Background(), nil, &proto.Packet{}); err != nil {
		t.Fatalf("Chain: %v", err)
	}
	if len(order) != 2 || order[0] != "a" || order[1] != "b" {
		t.Fatalf("got call order %v, want [a b]", order)
	}
}

func TestChainStopsOnFirstError(t *testing.T) {
	wantErr := errTest("boom")
	called := false
	a := Handler(func(context.Context, *Session, *proto.Packet) error { return wantErr })
	b := Handler(func(context.Context, *Session, *proto.Packet) error {
		called = true
		return nil
	})

	err := Chain(a, b)(context.Background(), nil, &proto.Packet{})
	if err != wantErr {
		t.Fatalf("got error %v, want %v", err, wantErr)
	}
	if called {
		t.Fatal("expected Chain to stop after the first error, but second handler ran")
	}
}

type errTest string

func (e errTest) Error() string { return string(e) }
