package session

import (
	"context"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/clientpacks"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// The packs a client needs (round 789, lane U; docs/protocol/asset_packs.md,
// "Server packs"). OURS, like the front-end theme and the server status: the
// client opens a short-lived connection of its own when Connect is pressed,
// before it logs in, sends OpClientPacksRequest, reads one OpClientPacks
// (clientpacks.Manifest's bytes) and the server ends the connection. It must
// come before the login so the client can fetch and layer the packs before
// character select reads item names and tables from them.
//
// Every server since round 789 answers, -client-packs or not: without it the
// manifest names no packs (flags 0) and the client keeps its own set at once.
// A server from before round 789 ignores the unknown request (the handler
// chain drops what no handler claims), so a new client waits out its timeout
// and goes on without packs; an old client never sends the request and never
// sees the reply.
const (
	OpClientPacksRequest uint16 = 0x0009 // client -> server, empty payload
	OpClientPacks        uint16 = 0x000A // server -> client
)

// ClientPacksHandler answers OpClientPacksRequest with m, once per
// connection, and ends a connection that has not logged in after the answer
// (the theme's rule, gateway.ErrEndSession). m is encoded once, here; a
// manifest that does not encode is a startup error.
func ClientPacksHandler(m clientpacks.Manifest) (gateway.Handler, error) {
	payload, err := m.Encode()
	if err != nil {
		return nil, err
	}
	if len(payload) > proto.MaxPayload {
		return nil, fmt.Errorf("session: the pack manifest is %d bytes, more than one frame", len(payload))
	}
	return func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpClientPacksRequest {
			return nil
		}
		if _, answered := sess.Get(clientPacksAnsweredKey); answered {
			return nil
		}
		sess.Set(clientPacksAnsweredKey, true)
		if err := sess.Send(&proto.Packet{Opcode: OpClientPacks, Data: payload}); err != nil {
			return err
		}
		if _, authed := AuthenticatedAccountID(sess); !authed {
			return gateway.ErrEndSession
		}
		return nil
	}, nil
}

const clientPacksAnsweredKey = "session.client_packs_answered"
