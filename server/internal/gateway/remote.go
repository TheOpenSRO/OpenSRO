package gateway

// Sessions for the multi-process mode (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.2-12.3):
//
//   - a remote session stands for a character whose connection is on
//     another process: what is Sent to it goes to a sink (the bus), so the
//     code that writes to "a member's session" -- a party line, a guild
//     update, a whisper -- reaches a member wherever it plays;
//   - a session may be asked to end from any goroutine (RequestEnd): a hand-off
//     to another process ends the stream here once the session's own
//     goroutine has finished the packet it is handling, and interrupts a read
//     it is blocked in;
//   - a session from a front's relay names the player's own address
//     (SetRemoteAddr), not the front's.

import (
	"net"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// RemoteSink takes what is Sent to a remote session, in Send order (frames
// encoded once for many sessions arrive as packets too).
type RemoteSink interface {
	SendRemote(ps []*proto.Packet) error
	CloseRemote() error
}

// NewRemoteSession is a session with no connection whose Sends go to sink.
// id must not collide with a local session's (the cluster layer gives it a
// range of its own).
func NewRemoteSession(id uint64, sink RemoteSink, addr net.Addr) *Session {
	s := &Session{id: id, sink: sink}
	if addr != nil {
		s.SetRemoteAddr(addr)
	}
	return s
}

// Remote reports a remote session.
func (s *Session) Remote() bool { return s != nil && s.sink != nil }

// sendRemote is enqueue for a remote session.
func (s *Session) sendRemote(ps []*proto.Packet, fs []*Frame) error {
	out := make([]*proto.Packet, 0, len(ps)+len(fs))
	for _, p := range ps {
		out = append(out, &proto.Packet{Opcode: p.Opcode, Data: append([]byte(nil), p.Data...)})
	}
	for _, f := range fs {
		out = append(out, &proto.Packet{Opcode: f.p.Opcode, Data: f.p.Data})
	}
	return s.sink.SendRemote(out)
}

// SetRemoteAddr names the address RemoteAddr reports (the player's own, for
// a session a front relays: the login's per-IP limit and the log lines read
// it).
func (s *Session) SetRemoteAddr(a net.Addr) {
	if a != nil {
		s.addr.Store(&addrBox{a})
	}
}

type addrBox struct{ a net.Addr }

// RelayAddr is a player's address as a front reports it.
type RelayAddr struct{ Text string }

func (a RelayAddr) Network() string { return "tcp" }
func (a RelayAddr) String() string  { return a.Text }

// RequestEnd ends the session from any goroutine: the packet being handled
// finishes, then the session ends as if its handler had returned
// ErrEndSession (OnDisconnect runs, what is queued is written out). A read
// the session's goroutine is blocked in is interrupted.
func (s *Session) RequestEnd() {
	if s == nil || s.sink != nil {
		return
	}
	s.endRequested.Store(true)
	if s.conn != nil {
		_ = s.conn.SetReadDeadline(time.Now())
	}
}

// EndRequested reports a RequestEnd.
func (s *Session) EndRequested() bool { return s != nil && s.endRequested.Load() }
