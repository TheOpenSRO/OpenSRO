package session

import (
	"context"
	"encoding/binary"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// The server's status for the client's server list (round 679). The
// exchange is OURS, like the front-end theme's: the client opens a
// short-lived connection of its own to each server its setting/config.yaml
// lists, sends OpServerStatusRequest, reads OpServerStatus, and the server
// ends the connection. No login is needed and nothing about the session
// changes.
//
// The fields are retail's (READ, sro_client.exe): the shard list entry the
// client's server window reads carries the current users (u16, entry+0x20),
// the maximum (u16, +0x22) and a state byte (+0x24) in that order, and the
// list code (FUN_00869cd0) shows "Check" for state 0 and otherwise a band of
// current/max. Retail gets them in its shard list from its one gateway
// (0x6101 -> 0xA101); this project's client asks each listed server.
const (
	OpServerStatusRequest uint16 = 0x0007 // client -> server, empty payload
	OpServerStatus        uint16 = 0x0008 // server -> client
)

// ServerStatusVersion is the first byte of every OpServerStatus. OURS.
const ServerStatusVersion = 1

// ServerState is retail's state byte: 0 shows "Check" (the server under
// inspection), anything else a population band (READ, FUN_00869cd0).
const (
	ServerStateCheck     uint8 = 0
	ServerStateOperating uint8 = 1
)

// ServerStatus is what the server reports.
type ServerStatus struct {
	Current    int
	Max        int
	Inspection bool
}

// Encode serializes the OpServerStatus payload:
//
//	u8 version (1) | u16 LE current | u16 LE max | u8 state
//
// Current and Max are clamped to 0..65535 (retail's fields are u16).
func (s ServerStatus) Encode() []byte {
	out := make([]byte, 6)
	out[0] = ServerStatusVersion
	binary.LittleEndian.PutUint16(out[1:], clampU16(s.Current))
	binary.LittleEndian.PutUint16(out[3:], clampU16(s.Max))
	out[5] = ServerStateOperating
	if s.Inspection {
		out[5] = ServerStateCheck
	}
	return out
}

func clampU16(v int) uint16 {
	switch {
	case v < 0:
		return 0
	case v > 0xffff:
		return 0xffff
	}
	return uint16(v)
}

// DecodeServerStatus parses an OpServerStatus payload, strictly.
func DecodeServerStatus(data []byte) (ServerStatus, error) {
	if len(data) != 6 {
		return ServerStatus{}, fmt.Errorf("session: decoding ServerStatus: %d bytes, want 6", len(data))
	}
	if data[0] != ServerStatusVersion {
		return ServerStatus{}, fmt.Errorf("session: decoding ServerStatus: version %d, want %d", data[0], ServerStatusVersion)
	}
	return ServerStatus{
		Current:    int(binary.LittleEndian.Uint16(data[1:])),
		Max:        int(binary.LittleEndian.Uint16(data[3:])),
		Inspection: data[5] == ServerStateCheck,
	}, nil
}

// ServerStatusHandler answers OpServerStatusRequest (any payload, ignored)
// with the status now(), read at the moment of the request. Like the theme's
// handler it needs no login, answers once per connection, and ends an
// unauthenticated asker's session after the answer (gateway.ErrEndSession);
// a logged-in session that asks gets one answer and nothing for a repeat.
// Nothing is logged per request. OURS.
func ServerStatusHandler(now func() ServerStatus) gateway.Handler {
	return func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpServerStatusRequest {
			return nil
		}
		if _, answered := sess.Get(serverStatusAnsweredKey); answered {
			return nil
		}
		sess.Set(serverStatusAnsweredKey, true)
		if err := sess.Send(&proto.Packet{Opcode: OpServerStatus, Data: now().Encode()}); err != nil {
			return err
		}
		if _, authed := AuthenticatedAccountID(sess); !authed {
			return gateway.ErrEndSession
		}
		return nil
	}
}

const serverStatusAnsweredKey = "session.server_status_answered"

// Retail's words for a login the server turns away (READ, textuisystem as
// the client's title shows them, round 679): the server under inspection
// (UIO_MSG_ERROR_ACCOUNT_CONNECT_IMPOSSIBILE) and the server full
// (UIO_MSG_ERROR_SERVER_BUSY_CONNECT_IMPOSSIBILE).
const (
	LoginRefusedInspection = "Cannot connect to the server because the server is now in inspection."
	LoginRefusedFull       = "The server is full, please try again later."
)

// LoginGate wraps the login handler: while the server is under inspection,
// or as full as its maximum, OpLogin is answered with a refusal carrying
// retail's words and never reaches next. Every other packet goes to next
// unchanged. OURS: retail's gateway refuses the same two cases with its own
// result codes; this server has one login reply with a reason.
func LoginGate(now func() ServerStatus, next gateway.Handler) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode == OpLogin {
			s := now()
			reason := ""
			switch {
			case s.Inspection:
				reason = LoginRefusedInspection
			case s.Max > 0 && s.Current >= s.Max:
				reason = LoginRefusedFull
			}
			if reason != "" {
				return sess.Send(&proto.Packet{Opcode: OpLoginResult, Data: (&LoginResult{OK: false, Reason: reason}).Encode()})
			}
		}
		return next(ctx, sess, p)
	}
}
