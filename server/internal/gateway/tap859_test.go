package gateway

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 859: a Tap sees every packet queued while it is installed -- a Send,
// a batch, a pre-encoded Frame -- in order, and nothing after its removal; a
// removed older tap does not take a newer one away.
func TestTapSeesQueuedPacketsUntilRemoved(t *testing.T) {
	conn := &recordingConn{gate: make(chan struct{})}
	close(conn.gate)
	s := &Session{id: 1, conn: conn}
	s.startWriter()
	defer s.closeAfterDrain(time.Second)
	var seen []uint16
	untap := s.Tap(func(op uint16, payload []byte) { seen = append(seen, op) })
	_ = s.Send(&proto.Packet{Opcode: 0x10, Data: []byte{1}})
	_ = s.SendBatch(&proto.Packet{Opcode: 0x11}, &proto.Packet{Opcode: 0x12})
	_ = s.SendFrames(MustFrame(&proto.Packet{Opcode: 0x13}))
	untap()
	_ = s.Send(&proto.Packet{Opcode: 0x14})
	if len(seen) != 4 || seen[0] != 0x10 || seen[1] != 0x11 || seen[2] != 0x12 || seen[3] != 0x13 {
		t.Fatalf("tap saw %#x, want 0x10..0x13", seen)
	}
	var newer []uint16
	old := s.Tap(func(op uint16, payload []byte) {})
	keep := s.Tap(func(op uint16, payload []byte) { newer = append(newer, op) })
	old()
	_ = s.Send(&proto.Packet{Opcode: 0x15})
	keep()
	if len(newer) != 1 || newer[0] != 0x15 {
		t.Fatalf("the newer tap saw %#x, want 0x15", newer)
	}
}
