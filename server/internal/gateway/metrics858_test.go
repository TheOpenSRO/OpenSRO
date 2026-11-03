package gateway

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 858: one session's connection, packets, bytes, handler run and
// disconnect reason reach the gateway's families.
func TestRound858GatewayMetrics(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	srv := &Server{
		Addr: "127.0.0.1:0",
		Handle: func(_ context.Context, sess *Session, p *proto.Packet) error {
			if len(p.Data) > 0 {
				return sess.Send(&proto.Packet{Opcode: 0xB021, Data: []byte{1}})
			}
			return errors.New("test: refuse")
		},
		OnDisconnect: func(*Session) { close(done) },
	}
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatal(err)
	}
	srv.Addr = ln.Addr().String()
	ln.Close()
	go srv.ListenAndServe(ctx)

	accepted0 := metrics.Value("gateway_connections_accepted_total")
	in0 := metrics.Value("gateway_packets_total", "dir", "in", "opcode", "0x7021")
	out0 := metrics.Value("gateway_packets_total", "dir", "out", "opcode", "0xb021")
	bytesIn0 := metrics.Value("gateway_bytes_total", "dir", "in")
	bytesOut0 := metrics.Value("gateway_bytes_total", "dir", "out")
	herr0 := metrics.Value("gateway_disconnects_total", "reason", "handler_error")
	world0 := metrics.Value("gateway_handler_seconds", "group", "world")

	var conn net.Conn
	for i := 0; i < 50; i++ {
		if conn, err = net.DialTimeout("tcp", srv.Addr, 100*time.Millisecond); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = proto.Write(conn, &proto.Packet{Opcode: 0x7021, Data: []byte("abcd")}, nil, nil)
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 7)
	if _, err := conn.Read(buf); err != nil {
		t.Fatalf("reading the reply: %v", err)
	}
	_ = proto.Write(conn, &proto.Packet{Opcode: 0x7021}, nil, nil) // empty: the handler refuses: the session ends
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the session did not end")
	}
	time.Sleep(50 * time.Millisecond) // the disconnect is counted after OnDisconnect

	for _, c := range []struct {
		name string
		got  float64
		min  float64
	}{
		{"accepted", metrics.Value("gateway_connections_accepted_total") - accepted0, 1},
		{"packets in 0x7021", metrics.Value("gateway_packets_total", "dir", "in", "opcode", "0x7021") - in0, 2},
		{"packets out 0xb021", metrics.Value("gateway_packets_total", "dir", "out", "opcode", "0xb021") - out0, 1},
		{"bytes in", metrics.Value("gateway_bytes_total", "dir", "in") - bytesIn0, 6 + 4 + 6},
		{"bytes out", metrics.Value("gateway_bytes_total", "dir", "out") - bytesOut0, 7},
		{"handler_error disconnects", metrics.Value("gateway_disconnects_total", "reason", "handler_error") - herr0, 1},
		{"world handler runs", metrics.Value("gateway_handler_seconds", "group", "world") - world0, 2},
	} {
		if c.got < c.min {
			t.Errorf("%s moved by %v, want at least %v", c.name, c.got, c.min)
		}
	}
}
