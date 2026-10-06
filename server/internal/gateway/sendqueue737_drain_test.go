package gateway

import (
	"bytes"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// recordingConn is a net.Conn that keeps every Write as it was made, and can
// hold the writer back until released (so several Sends queue behind one
// drain).
type recordingConn struct {
	net.Conn
	mu     sync.Mutex
	writes [][]byte
	gate   chan struct{}
}

func (c *recordingConn) Write(b []byte) (int, error) {
	if c.gate != nil {
		<-c.gate
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.writes = append(c.writes, append([]byte(nil), b...))
	return len(b), nil
}
func (c *recordingConn) SetWriteDeadline(time.Time) error { return nil }
func (c *recordingConn) Close() error                     { return nil }
func (c *recordingConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }

// Round 737 (crowd_scale.md C2): the writer puts everything it drained on the
// socket in ONE write, where round 662 wrote a frame per write. Frames queued
// while a write is in flight -- a batch of three, one of them a full-size
// page, two single sends and a pre-encoded Frame -- go out in the next drain
// as one write, in order, byte for byte what proto.Write makes. (Round 662's
// frame-per-write mitigation was for a client wedge round 663 fixed in the
// client's reader; its cost was round 736's 79% of server CPU in write.)
func TestTheWriterWritesOneDrainPerWrite(t *testing.T) {
	conn := &recordingConn{gate: make(chan struct{})}
	s := &Session{id: 1, conn: conn}
	s.startWriter()
	defer s.closeAfterDrain(time.Second)
	// The first frame alone: the writer takes it and blocks in Write.
	first := &proto.Packet{Opcode: 0x01, Data: []byte{9}}
	if err := s.Send(first); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		s.outMu.Lock()
		taken := s.inFlight > 0
		s.outMu.Unlock()
		if taken || time.Now().After(deadline) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	frames := []*proto.Packet{
		{Opcode: 0x66, Data: bytes.Repeat([]byte{1}, proto.MaxPayload)},
		{Opcode: 0x7f, Data: nil},
		{Opcode: 0x7c, Data: bytes.Repeat([]byte{2}, 29)},
	}
	if err := s.SendBatch(frames...); err != nil {
		t.Fatal(err)
	}
	for _, p := range []*proto.Packet{{Opcode: 0xf2, Data: []byte("hi")}, {Opcode: 0x110, Data: bytes.Repeat([]byte{3}, 5000)}} {
		if err := s.Send(p); err != nil {
			t.Fatal(err)
		}
		frames = append(frames, p)
	}
	pre := &proto.Packet{Opcode: 0x3019, Data: []byte{1, 2, 3, 4}}
	if err := s.SendFrames(MustFrame(pre)); err != nil {
		t.Fatal(err)
	}
	frames = append(frames, pre)
	close(conn.gate)
	if !s.flush(2 * time.Second) {
		t.Fatal("the queue did not drain")
	}
	conn.mu.Lock()
	defer conn.mu.Unlock()
	if len(conn.writes) != 2 {
		t.Fatalf("%d writes, want 2: the first frame, then one drain of %d frames", len(conn.writes), len(frames))
	}
	var want bytes.Buffer
	_ = proto.Write(&want, first, nil, nil)
	if !bytes.Equal(conn.writes[0], want.Bytes()) {
		t.Fatalf("first write %d bytes, want the first frame", len(conn.writes[0]))
	}
	want.Reset()
	for _, p := range frames {
		_ = proto.Write(&want, p, nil, nil)
	}
	if !bytes.Equal(conn.writes[1], want.Bytes()) {
		t.Errorf("second write is %d bytes, want the %d frames in order (%d bytes)", len(conn.writes[1]), len(frames), want.Len())
	}
}

// A Frame is the packet proto.Write makes, encoded once; NewFrame refuses an
// oversized payload as Send does, and copies the payload.
func TestFrameIsTheEncodedPacket(t *testing.T) {
	data := []byte{5, 6, 7}
	f, err := NewFrame(&proto.Packet{Opcode: 0x3015, Data: data})
	if err != nil {
		t.Fatal(err)
	}
	data[0] = 99
	var want bytes.Buffer
	_ = proto.Write(&want, &proto.Packet{Opcode: 0x3015, Data: []byte{5, 6, 7}}, nil, nil)
	if !bytes.Equal(f.wire, want.Bytes()) || f.Opcode() != 0x3015 || !bytes.Equal(f.Payload(), []byte{5, 6, 7}) {
		t.Fatalf("frame %x, want %x", f.wire, want.Bytes())
	}
	if _, err := NewFrame(&proto.Packet{Opcode: 1, Data: make([]byte, proto.MaxPayload+1)}); err == nil {
		t.Fatal("an oversized payload was taken")
	}
}

// A session with security draws its own rolling byte and checksum for a
// Frame, exactly as Send of the same packet would.
func TestFrameOnASecuredSessionIsEncodedPerSession(t *testing.T) {
	mk := func() *Session {
		conn := &recordingConn{}
		s := &Session{id: 1, conn: conn}
		s.SetSecurity(proto.NewRollingByte(0x12, 0x34, 0x56), proto.NewPacketChecksum(0x78), nil, nil)
		s.startWriter()
		return s
	}
	p := &proto.Packet{Opcode: 0x3016, Data: []byte{1, 0, 0, 0}}
	a, b := mk(), mk()
	defer a.closeAfterDrain(time.Second)
	defer b.closeAfterDrain(time.Second)
	if err := a.Send(p); err != nil {
		t.Fatal(err)
	}
	if err := b.SendFrames(MustFrame(p)); err != nil {
		t.Fatal(err)
	}
	a.flush(time.Second)
	b.flush(time.Second)
	ca, cb := a.conn.(*recordingConn), b.conn.(*recordingConn)
	ca.mu.Lock()
	cb.mu.Lock()
	defer ca.mu.Unlock()
	defer cb.mu.Unlock()
	if len(ca.writes) != 1 || len(cb.writes) != 1 || !bytes.Equal(ca.writes[0], cb.writes[0]) {
		t.Fatalf("Send %x, SendFrames %x", ca.writes, cb.writes)
	}
}
