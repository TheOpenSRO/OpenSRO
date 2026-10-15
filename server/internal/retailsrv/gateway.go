package retailsrv

// The retail gateway (round 788): what GatewayServer.exe answers the
// original client, from its own code (addresses are GatewayServer's unless
// named; RESEARCH section 1 and docs/protocol/opcodes/gateway.md, "OpenSRO's
// retail listeners").

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

// gatewayCodec is the gateway's framing (READ): 0xA100 and 0xA104 go as
// massive messages (the writer 0x41f580..0x41f7d0, its frames plain); of the
// rest only a SUCCESSFUL 0xA102 is encrypted (alloc(1), 0x405e7d -- the
// 0x6102 handler's own refusals, 0x405910, are alloc(0)); 0xA101, 0xA106 and
// 0x2001 are plain.
func gatewayCodec(c *Config) func() gateway.Codec {
	return retailgw.NewServerCodec(retailgw.ServerCodecConfig{
		Fixed: c.Fixed,
		Encrypt: func(op uint16, payload []byte) bool {
			return op == OpLoginReply && len(payload) > 0 && payload[0] == 1
		},
		Massive: func(op uint16) bool { return op == OpPatchReply || op == OpNoticeReply },
		Log:     packetLog(c, "gateway"),
	})
}

// GatewayServer is the retail gateway listener on addr.
func GatewayServer(c *Config, addr string) *gateway.Server {
	return &gateway.Server{Addr: addr, Logger: c.logger(), Codec: gatewayCodec(c), Handle: GatewayHandler(c)}
}

// GatewayHandler answers the original client's gateway messages. The
// keep-alive 0x2002 is read and not answered (READ: its handler 0x4405c0
// discards it); so is anything else this gateway does not serve.
func GatewayHandler(c *Config) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpIdentity:
			return sendIdentity(sess, GatewayModule)
		case OpPatchRequest:
			return c.patch(sess, p.Data)
		case OpShardListReq:
			// OURS: the list and the login only after an accepted 0x6100
			// (whether GatewayServer's dispatcher requires it is OPEN; the
			// client never asks out of order, gateway.md).
			if !patched(sess) {
				return fmt.Errorf("retail gateway: 0x6101 before an accepted 0x6100")
			}
			return sess.Send(&proto.Packet{Opcode: OpShardList, Data: c.shardList()})
		case OpNoticeRequest:
			// READ (0x406380, reply 0x4013e0): u8 count, then per notice
			// string subject, string article, 16-byte date. This server has
			// none. The client asks only in net modes 1 and 3 (READ 0x4cf0c0);
			// the launcher's mode 2 never does.
			return sess.Send(&proto.Packet{Opcode: OpNoticeReply, Data: []byte{0}})
		case OpFarmRequest:
			// READ (0x405740): the request is not read; the reply is u8 count,
			// then per farm manager u8 farm id, u32 IPv4. This server has no
			// farm manager. The client sends 0x6106 only when a mode word no
			// code was found to write is 1 (INFERRED: never).
			return sess.Send(&proto.Packet{Opcode: OpFarmReply, Data: []byte{0}})
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

// sendIdentity answers the client's 0x2001 (READ, the servers' shared net
// library 0x43f5a0 / AgentServer 0x42c180): a server waits for the client's
// 0x2001 and replies with its own name and a 0 byte, plain (0x43f70a..
// 0x43f741). Retail then also sends massive 0x2005 and 0x6005; this server
// does not (OURS: the client registers no handler for either -- its opcode
// table, CClientProcess::vslot_002 0x4ce560 -- and 0x2005's u16 is of
// INFERRED meaning).
func sendIdentity(sess *gateway.Session, module string) error {
	return sess.Send(&proto.Packet{Opcode: OpIdentity, Data: retailgw.EncodeIdentity(module, 0)})
}

// The 0xA100 answers (READ, 0x4051a0; the client's reading, jump table
// 0x4cf308 index code-1): [1] go on; [2, 1] an unknown module, a version 0
// or a version above the server's -- the client shows "Failed to connect to
// server.(C4)" and quits; [2, 3] a version below the server's with no patch
// server -- the same text; [2, 4] the gateway not in service -- "Servers are
// offline" and quits. [2, 2] (a patch to download) is never sent: it carries
// a patch server and a file list, and this server has none.
const (
	patchUnknownClient uint8 = 1
	patchNoPatchServer uint8 = 3
)

// patch answers 0x6100. The content id is not checked here (READ: the
// gateway only logs it, 0x405508; the agent checks it in 0x6103). A refusal
// leaves the connection open (READ: no disconnect on those paths); the client
// closes it.
func (c *Config) patch(sess *gateway.Session, data []byte) error {
	_, module, ver, err := retailgw.DecodePatchRequest(data)
	if err != nil {
		// READ: "certificate client module : invalid msg data (0/1/2)", no
		// reply, disconnect (0x405237 / 0x405314 / 0x405393).
		return fmt.Errorf("retail gateway: 0x6100: %v", err)
	}
	reply := []byte{1}
	switch {
	case module != retailgw.ClientModule || ver == 0 || ver > c.Version:
		reply = []byte{2, patchUnknownClient}
	case ver < c.Version:
		reply = []byte{2, patchNoPatchServer}
	}
	if err := sess.Send(&proto.Packet{Opcode: OpPatchReply, Data: reply}); err != nil {
		return err
	}
	if reply[0] == 1 {
		sess.Set(patchedKey, true)
	} else {
		c.logger().Info("retail gateway: client refused", "addr", sess.RemoteAddr(), "module", module, "version", ver, "want", c.Version)
	}
	return nil
}

// shardList is the 0xA101 with this server as its one shard, in its one
// farm (OURS: farm id 1, named as the shard). The state is retail's: 0
// "Check" under inspection, else 1. The farm byte follows GatewayServer's
// rule for the content id (retailgw.FarmByteFor, READ 0x412d7b).
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

// login answers 0x6102: the shard must be ours, then the LoginService
// decides; an admitted login is queued for the agent under a token and the
// client is sent there. The retail gateway would now send the IBUV image
// (0x2322) and wait for its code; this server does not (OURS: the client's
// 0xA102 reader checks only the result byte -- READ 0x4cf500 -- and the
// image's format is not known).
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
		} else {
			c.logger().Info("retail gateway: login refused", "addr", sess.RemoteAddr(), "code", out.Ack.Code)
		}
	}
	if err := sess.Send(&proto.Packet{Opcode: OpLoginReply, Data: out.Ack.Encode()}); err != nil {
		return err
	}
	if out.Close {
		return gateway.ErrEndSession
	}
	// After a success the client closes the gateway itself (READ 0x4cf500:
	// engine slot 0x5c, then the agent connect); closing it from here could
	// race its read of the reply.
	return nil
}
