package retailsrv

// The retail agent (round 788): what AgentServer.exe answers the original
// client (addresses are AgentServer's unless named).

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/retailgw"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// agentCodec is the agent's framing (READ): every 0xA103 encrypted
// (alloc(1) on all its paths, 0x40226a .. 0x40312f); everything else plain --
// 0x2001, and the shard's lobby replies the agent relays (0x2209 stripped and
// sent alloc(0), 0x403348..0x403379). No message of this exchange is massive.
func agentCodec(c *Config) func() gateway.Codec {
	return retailgw.NewServerCodec(retailgw.ServerCodecConfig{
		Fixed:   c.Fixed,
		Encrypt: func(op uint16, _ []byte) bool { return op == OpAgentLoginReply },
		Log:     packetLog(c, "agent"),
	})
}

// AgentServer is the retail agent listener on addr. onDisconnect is the
// main server's session-end bookkeeping (nil: none).
func AgentServer(c *Config, addr string, onDisconnect func(*gateway.Session)) *gateway.Server {
	return &gateway.Server{Addr: addr, Logger: c.logger(), Codec: agentCodec(c), Handle: AgentHandler(c), OnDisconnect: onDisconnect}
}

// AgentLogin is a 0x6103 payload (READ, client 0x4ceb86): u32 token, the
// lower-cased ID, the password, u8 content id, then six bytes (the net
// engine's slot 0x88; a MAC address per public docs, INFERRED).
type AgentLogin struct {
	Token     uint32
	ID, PW    string
	ContentID byte
	Extra     [6]byte
}

// Encode writes the request as the client does.
func (a *AgentLogin) Encode() []byte {
	out := binary.LittleEndian.AppendUint32(nil, a.Token)
	for _, s := range []string{a.ID, a.PW} {
		out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
		out = append(out, s...)
	}
	out = append(out, a.ContentID)
	return append(out, a.Extra[:]...)
}

// DecodeAgentLogin reads a 0x6103 strictly (OURS: nothing after the six bytes).
func DecodeAgentLogin(b []byte) (*AgentLogin, error) {
	a := &AgentLogin{}
	if len(b) < 4 {
		return nil, errors.New("0x6103: short token")
	}
	a.Token = binary.LittleEndian.Uint32(b)
	b = b[4:]
	for _, dst := range []*string{&a.ID, &a.PW} {
		if len(b) < 2 {
			return nil, errors.New("0x6103: short string length")
		}
		n := int(binary.LittleEndian.Uint16(b))
		if len(b) < 2+n {
			return nil, errors.New("0x6103: short string")
		}
		*dst = string(b[2 : 2+n])
		b = b[2+n:]
	}
	if len(b) != 7 {
		return nil, fmt.Errorf("0x6103: %d bytes where the content id and six bytes end it", len(b))
	}
	a.ContentID = b[0]
	copy(a.Extra[:], b[1:])
	return a, nil
}

// The 0xA103 codes (READ, AgentServer 0x402120; the client's reader
// vslot_018 0x4cf7a0, jump table 0x4cf874: 1 "(C9)", 2 and 3 "(C10)").
const (
	agentOK              = 1
	agentFail            = 2
	AgentErrCredentials  = 1 // the ID / password do not match the queued login
	AgentErrRegistration = 2
	AgentErrNoToken      = 3 // server not ready, or the token unknown
)

// agentAuthedKey marks an agent session whose 0x6103 was accepted.
const agentAuthedKey = "retailsrv.agent_authed"

func agentAuthed(sess *gateway.Session) bool {
	v, _ := sess.Get(agentAuthedKey)
	b, _ := v.(bool)
	return b
}

// AgentHandler answers the original client on the agent: its identity, the
// token login, the lobby, and a refused Start. The keep-alive 0x2002 is read
// and not answered (READ, AgentServer 0x42d2a0).
func AgentHandler(c *Config) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpIdentity:
			return sendIdentity(sess, AgentModule)
		case OpAgentLogin:
			return c.agentLogin(sess, p.Data)
		case OpLobby, OpStart:
			// READ (0x401d00 -> 0x4315d0): a lobby message from a session
			// with no logged-in user is dropped ("unhandled msg received"),
			// not answered.
			if !agentAuthed(sess) {
				c.logger().Info("retail agent: a lobby message before 0x6103, dropped", "addr", sess.RemoteAddr(), "opcode", hexOp(p.Opcode))
				return nil
			}
			if p.Opcode == OpStart {
				if err := c.refuseStart(sess, p.Data); err != nil {
					return err
				}
				// OURS: the list again, unasked. The select screen locks its
				// controls when it sends Start (0x862410(1), 0x858770) and
				// only its 0xB007 path unlocks them (0x85fffa); its 0xB001
				// failure path shows the message and returns
				// (0x85fd03..0x85fd1d) -- MEASURED with the real client: after
				// a refused Start no button answered. A fresh list unlocks
				// the screen, so the player can pick again or leave.
				if c.Lobby != nil {
					return c.Lobby(ctx, sess, &proto.Packet{Opcode: OpLobby, Data: []byte{session.LobbyList}})
				}
				return nil
			}
			if c.Lobby != nil {
				return c.Lobby(ctx, sess, p)
			}
		}
		return nil
	}
}

// agentRefuse sends [2, code] and ends the session (READ: every refusal of
// 0x402120 is followed by a disconnect, 0x402608, engine slot 0x5c).
func agentRefuse(sess *gateway.Session, code byte) error {
	if err := sess.Send(&proto.Packet{Opcode: OpAgentLoginReply, Data: []byte{agentFail, code}}); err != nil {
		return err
	}
	return gateway.ErrEndSession
}

// agentLogin is 0x6103 (READ, AgentServer 0x402120): a content id other than
// the server's -> no reply, disconnect (0x402225 .. 0x40223c); a token
// unknown, used or expired -> [2, 3] (0x409dc0); credentials that do not
// match the queued login -> [2, 1]; else [1] and the session belongs to the
// account. Retail sends its [1] only once the shard (0xA201) and the game
// server (0xA204) have taken the user (0x402be0, 0x402d53..0x402d80); this
// server is both, so it answers at once. The ID is compared without case:
// the client sends its lower-cased copy here and the ID as typed in 0x6102
// (READ 0x4c9374); how AgentServer compares them was not read (INFERRED: it
// must ignore case too, or every mixed-case login would fail).
func (c *Config) agentLogin(sess *gateway.Session, data []byte) error {
	if agentAuthed(sess) {
		return errors.New("retail agent: a second 0x6103 on a logged-in session")
	}
	req, err := DecodeAgentLogin(data)
	if err != nil {
		return fmt.Errorf("retail agent: %w", err)
	}
	if req.ContentID != c.ContentID {
		return fmt.Errorf("retail agent: 0x6103 content id %d, not %d", req.ContentID, c.ContentID)
	}
	p, ok := c.Tokens.Take(req.Token)
	if !ok {
		c.logger().Info("retail agent: unknown or expired token", "addr", sess.RemoteAddr())
		return agentRefuse(sess, AgentErrNoToken)
	}
	if !p.matches(req.ID, req.PW) {
		c.logger().Info("retail agent: the credentials do not match the token's login", "addr", sess.RemoteAddr())
		return agentRefuse(sess, AgentErrCredentials)
	}
	c.Login.AdmitSession(sess, p.acc)
	sess.Set(agentAuthedKey, true)
	c.logger().Info("retail agent: logged in", "addr", sess.RemoteAddr(), "account", p.acc.Username)
	return sess.Send(&proto.Packet{Opcode: OpAgentLoginReply, Data: []byte{agentOK}})
}

// StartRefusal is the 0xB001 code Start is refused with: 0x40f, which the
// select screen shows as UIO_SMERR_CANT_ACCESS_PARENT_SERVER, "Character
// entry has failed. The GameServer is currently offline; therefore, you
// cannot connect to SRO at the moment. ..." with "(S1039)" (READ: 0x861a40,
// index table 0x861b84). OURS, the choice: of the select screen's texts it is
// the only one that says entering the world failed because no game server
// takes the character -- which is the truth here. The client stays on the
// select screen (READ: the failure path shows a box and changes no state).
const StartRefusal = session.LobbyErrNoParent

// refuseStart answers 0x7001 with [2, u16 code]: this server offers the
// original client no world (round 788's scope).
func (c *Config) refuseStart(sess *gateway.Session, data []byte) error {
	name := ""
	if r, err := session.DecodeStartRequest(data); err == nil {
		name = r.Name
	}
	c.logger().Info("retail agent: Start refused (the original client gets no world here)", "addr", sess.RemoteAddr(), "character", name)
	return sess.Send(&proto.Packet{Opcode: OpStartResult, Data: (&session.StartResult{Code: StartRefusal}).Encode()})
}
