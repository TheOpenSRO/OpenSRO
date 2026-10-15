package retailsrv

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

// agentCodec is the agent's framing.
func agentCodec(c *Config) func() gateway.Codec {
	return retailgw.NewServerCodec(retailgw.ServerCodecConfig{
		Fixed: c.Fixed,
		Log:   packetLog(c, "agent"),
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
// vslot_018 0x4cf7a0).
const (
	agentOK              = 1
	agentFail            = 2
	AgentErrCredentials  = 1 // the ID / password do not match the queued login
	AgentErrRegistration = 2
	AgentErrNoToken      = 3 // server not ready, or the token unknown
)

// agentAuthedKey marks an agent session whose 0x6103 was accepted.
const agentAuthedKey = "retailsrv.agent_authed"

// AgentHandler answers the original client on the agent: its identity, the
// token login, the lobby, and a refused Start.
func AgentHandler(c *Config) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpIdentity:
			return sendIdentity(sess, AgentModule)
		case OpAgentLogin:
			return c.agentLogin(sess, p.Data)
		case OpLobby:
			if c.Lobby != nil {
				return c.Lobby(ctx, sess, p)
			}
		case OpStart:
			return c.refuseStart(sess, p.Data)
		}
		return nil
	}
}

func agentReply(sess *gateway.Session, code byte) error {
	data := []byte{agentOK}
	if code != 0 {
		data = []byte{agentFail, code}
	}
	return sess.Send(&proto.Packet{Opcode: OpAgentLoginReply, Data: data})
}

// agentLogin is 0x6103 (READ, AgentServer 0x402120): a content id other than
// the server's -> no reply, disconnect; a token unknown (or used, or
// expired) -> [2, 3]; credentials that do not match the queued login ->
// [2, 1]; else [1] and the session belongs to the account.
func (c *Config) agentLogin(sess *gateway.Session, data []byte) error {
	if v, _ := sess.Get(agentAuthedKey); v == true {
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
		return agentReply(sess, AgentErrNoToken)
	}
	if !p.matches(req.ID, req.PW) {
		c.logger().Info("retail agent: the credentials do not match the token's login", "addr", sess.RemoteAddr())
		return agentReply(sess, AgentErrCredentials)
	}
	c.Login.AdmitSession(sess, p.acc)
	sess.Set(agentAuthedKey, true)
	c.logger().Info("retail agent: logged in", "addr", sess.RemoteAddr(), "account", p.acc.Username)
	return agentReply(sess, 0)
}

// StartRefusal is the 0xB001 code Start is refused with.
const StartRefusal = session.LobbyErrNoGameServer

// refuseStart answers 0x7001 with [2, code]: this server offers the original
// client no world.
func (c *Config) refuseStart(sess *gateway.Session, data []byte) error {
	name := ""
	if r, err := session.DecodeStartRequest(data); err == nil {
		name = r.Name
	}
	c.logger().Info("retail agent: Start refused (the original client gets no world here)", "addr", sess.RemoteAddr(), "character", name)
	return sess.Send(&proto.Packet{Opcode: OpStartResult, Data: (&session.StartResult{Code: StartRefusal}).Encode()})
}
