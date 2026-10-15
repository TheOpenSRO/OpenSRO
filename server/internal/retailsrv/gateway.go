package retailsrv

import (
	"context"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/retailgw"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// patchedKey marks a gateway session whose 0x6100 was accepted.
const patchedKey = "retailsrv.patched"

// gatewayCodec is the gateway's framing: 0xA100 as a massive message, the
// rest plain (READ: GatewayServer allocates its 0xA100 parts, 0xA101 and
// 0xA102 with alloc(0), gateway.md).
func gatewayCodec(c *Config) func() gateway.Codec {
	return retailgw.NewServerCodec(retailgw.ServerCodecConfig{
		Fixed:   c.Fixed,
		Massive: func(op uint16) bool { return op == OpPatchReply || op == OpNoticeReply },
		Log:     packetLog(c, "gateway"),
	})
}

// GatewayServer is the retail gateway listener on addr.
func GatewayServer(c *Config, addr string) *gateway.Server {
	return &gateway.Server{Addr: addr, Logger: c.logger(), Codec: gatewayCodec(c), Handle: GatewayHandler(c)}
}

// GatewayHandler answers the original client's gateway messages.
func GatewayHandler(c *Config) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpIdentity:
			return sendIdentity(sess, GatewayModule)
		case OpPatchRequest:
			return c.patch(sess, p.Data)
		case OpShardListReq:
			if !patched(sess) {
				return fmt.Errorf("retail gateway: 0x6101 before an accepted 0x6100")
			}
			return sess.Send(&proto.Packet{Opcode: OpShardList, Data: c.shardList()})
		case OpNoticeRequest:
			return sess.Send(&proto.Packet{Opcode: OpNoticeReply, Data: noNotices()})
		case OpLogin:
			if !patched(sess) {
				return fmt.Errorf("retail gateway: 0x6102 before an accepted 0x6100")
			}
			return c.login(ctx, sess, p.Data)
		}
		return nil
	}
}

func patched(sess *gateway.Session) bool {
	v, _ := sess.Get(patchedKey)
	b, _ := v.(bool)
	return b
}

// sendIdentity answers the client's 0x2001 with the server's module name and
// a 0 byte (READ: the client reads a string and a byte, vslot_014 0x4ce9d0).
func sendIdentity(sess *gateway.Session, module string) error {
	return sess.Send(&proto.Packet{Opcode: OpIdentity, Data: retailgw.EncodeIdentity(module, 0)})
}

// patch answers 0x6100 (READ, GatewayServer 0x4051a0).
func (c *Config) patch(sess *gateway.Session, data []byte) error {
	cid, module, ver, err := retailgw.DecodePatchRequest(data)
	if err != nil {
		// READ: "certificate client module : invalid msg data", disconnect.
		return fmt.Errorf("retail gateway: 0x6100: %v", err)
	}
	reply := []byte{1}
	switch {
	case module != retailgw.ClientModule || cid != c.ContentID:
		reply = []byte{2, 1}
	case ver != c.Version:
		reply = []byte{2, 2}
	}
	if err := sess.Send(&proto.Packet{Opcode: OpPatchReply, Data: reply}); err != nil {
		return err
	}
	if reply[0] != 1 {
		return gateway.ErrEndSession
	}
	sess.Set(patchedKey, true)
	return nil
}

// shardList is the 0xA101 with this server as its one shard.
func (c *Config) shardList() []byte {
	st := c.Status()
	state := session.ServerStateOperating
	if st.Inspection {
		state = session.ServerStateCheck
	}
	l := retailgw.ShardList{
		Farms: []retailgw.Farm{{ID: 1, Name: c.FarmName}},
		Shards: []retailgw.Shard{{ID: c.ShardID, Name: c.ShardName,
			Current: clampU16(st.Current), Capacity: clampU16(st.Max), State: state, Farm: 1}},
	}
	return retailgw.EncodeShardList(l, retailgw.FarmByteFor(c.ContentID))
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

// noNotices is a 0xA104 with no notice.
func noNotices() []byte { return []byte{0} }

// login answers 0x6102: the shard must be ours, then the LoginService
// decides; an admitted login is queued for the agent under a token.
func (c *Config) login(ctx context.Context, sess *gateway.Session, data []byte) error {
	req, err := session.DecodeGatewayLoginRequest(data)
	var out session.LoginOutcome
	switch {
	case err != nil:
		out = session.LoginOutcome{Ack: session.LoginAck{Code: session.LoginErrFailed}, Close: true}
	case req.ShardID != c.ShardID:
		// READ: a shard the gateway does not know is [2, 4] (0x40d710).
		out = session.LoginOutcome{Ack: session.LoginAck{Code: session.LoginErrNoShard}}
	default:
		// The decision only: the session that plays is the agent's
		// (AdmitSession there), so none is given here.
		out = c.Login.Login(ctx, session.LoginAttempt{Username: req.Username, Password: req.Password, Remote: sess.RemoteAddr()})
		if out.Ack.OK {
			if out.Account == nil {
				return errors.New("retail gateway: a login admitted without an account")
			}
			out.Ack.Token = c.Tokens.Issue(out.Account, req.Username, req.Password, req.ContentID)
			out.Ack.AgentHost, out.Ack.AgentPort = c.AgentHost, c.AgentPort
			c.logger().Info("retail gateway: login admitted; the client goes to the agent", "addr", sess.RemoteAddr(),
				"account", out.Account.Username, "agent", fmt.Sprintf("%s:%d", c.AgentHost, c.AgentPort))
		}
	}
	if err := sess.Send(&proto.Packet{Opcode: OpLoginReply, Data: out.Ack.Encode()}); err != nil {
		return err
	}
	if out.Close {
		return gateway.ErrEndSession
	}
	return nil
}
