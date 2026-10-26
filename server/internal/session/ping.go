package session

// The ping counter (round 832, OURS): the Extra option tab's Ping / FPS box,
// a private-server add-on the user asked for -- retail has no such message.
// The client sends OpPing {u32 token} every few seconds and times the echo.

import (
	"context"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

const (
	// OpPing is the client's ping, {u32 token} (OURS).
	OpPing uint16 = 0x00FC
	// OpPingEcho is the server's answer: the same four bytes (OURS).
	OpPingEcho uint16 = 0x00FD
)

// PingHandler echoes OpPing's token at once.
func PingHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpPing || len(p.Data) != 4 {
			return nil
		}
		return sess.Send(&proto.Packet{Opcode: OpPingEcho, Data: append([]byte(nil), p.Data...)})
	}
}
