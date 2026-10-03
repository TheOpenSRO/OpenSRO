package gateway

import (
	"bytes"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// recordingConn is a net.Conn that keeps every Write as it was made.
type recordingConn struct {
	net.Conn
	mu     sync.Mutex
	writes [][]byte
}

func (c *recordingConn) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.writes = append(c.writes, append([]byte(nil), b...))
	return len(b), nil
}
func (c *recordingConn) SetWriteDeadline(time.Time) error { return nil }
func (c *recordingConn) Close() error                     { return nil }
func (c *recordingConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }

// Round 662's live check: the writer puts one frame on the socket per write,
// never the whole queue in one. The real client reads a frame only once all
// of its payload is in the kernel's receive buffer, and over loopback one big
// write came as a few big segments whose memory filled that buffer while it
// held less than the 32 KB list page the client waited for: both sides
// stopped (WORLD_ISSUES round 662). Frames queued together -- a batch of
// three, one of them a full-size page, and two single sends -- are written a
// frame per write, in order, byte for byte what proto.Write makes.
func TestTheWriterWritesAFramePerWrite(t *testing.T) {
	conn := &recordingConn{}
	s := &Session{id: 1, conn: conn}
	s.startWriter()
	defer s.closeAfterDrain(time.Second)
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
	if !s.flush(2 * time.Second) {
		t.Fatal("the queue did not drain")
	}
	conn.mu.Lock()
	defer conn.mu.Unlock()
	if len(conn.writes) != len(frames) {
		t.Fatalf("%d frames went out in %d writes, want one write per frame", len(frames), len(conn.writes))
	}
	for i, p := range frames {
		var want bytes.Buffer
		_ = proto.Write(&want, p, nil, nil)
		if !bytes.Equal(conn.writes[i], want.Bytes()) {
			t.Errorf("write %d is %d bytes, want frame %d (%#x, %d bytes)", i, len(conn.writes[i]), i, p.Opcode, want.Len())
		}
	}
}
