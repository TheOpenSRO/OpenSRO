package retailgw

// The retail framing as a gateway.Codec (round 788): OpenSRO's own server
// speaks the original wire on its retail listeners with this, and the
// handlers above it -- the login, the lobby -- see an ordinary
// *gateway.Session and proto.Packet. The handshake is ServerHandshake (the
// fake gateway's own, handshake_server.go); the frames are proto's
// RetailSecurity. docs/protocol/opcodes/gateway.md, "OpenSRO's retail
// listeners (round 788)".

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// ServerCodecConfig is one listener's framing choices.
type ServerCodecConfig struct {
	// Flags of the hello (0: DefaultServerFlags, retail's 0x0E).
	Flags byte
	// Encrypt reports whether the server sends a message encrypted (the
	// sender's choice per message, READ: the allocator's argument,
	// gateway.md). nil sends everything plain.
	Encrypt func(op uint16, payload []byte) bool
	// Massive reports whether op is sent as a 0x600D header and parts (READ:
	// GatewayServer's 0xA100, 0x41f580..0x41f7d0). nil: none.
	Massive func(op uint16) bool
	// Fixed replaces the handshake's random values (tests).
	Fixed *Fixed
	// Log, when set, sees every message each way after the handshake
	// (fromServer, opcode, payload; a massive message once, whole).
	Log func(fromServer bool, op uint16, payload []byte)
}

// ServerCodec is one connection's retail framing, server side.
type ServerCodec struct {
	cfg ServerCodecConfig

	mu  sync.Mutex
	hs  *ServerHandshake
	sec *proto.RetailSecurity
	// state: 0 hello sent, 1 challenge sent, 2 established.
	state int
	sess  *gateway.Session
}

// NewServerCodec returns a gateway.Server Codec factory.
func NewServerCodec(cfg ServerCodecConfig) func() gateway.Codec {
	return func() gateway.Codec { return &ServerCodec{cfg: cfg} }
}

const (
	codecHello = iota
	codecChallenge
	codecEstablished
)

// massivePartSize is the data per 0x600D part this server writes (OURS:
// below one frame; the parts' size the retail writer uses was not read).
const massivePartSize = 0x0f00

// Start sends the hello (READ: the server speaks first, 0x5000 unencrypted,
// handshake.md) and keys the connection with it.
func (c *ServerCodec) Start(sess *gateway.Session) error {
	c.mu.Lock()
	c.sess = sess
	c.hs = NewServerHandshake(c.cfg.Flags, c.cfg.Fixed, nil)
	// The hello goes plain (an empty security state encodes a plain frame
	// with count and check 0, as a server writes them).
	c.sec = &proto.RetailSecurity{Flags: c.hs.Hello.Flags}
	c.mu.Unlock()
	if err := sess.Send(&proto.Packet{Opcode: OpHandshake, Data: c.hs.Hello.Encode()}); err != nil {
		return err
	}
	sec, err := c.hs.Security()
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.sec = sec
	c.mu.Unlock()
	return nil
}

// ErrBeforeHandshake is a message other than 0x5000 / 0x9000 before the
// handshake ends (READ, 0x4b1dd2..0x4b1de6: the session ends, 0x8010).
var ErrBeforeHandshake = errors.New("retail: a message before the handshake finished")

// ReadPacket reads frames until one for the handlers, answering the
// handshake's own on the way.
func (c *ServerCodec) ReadPacket(r *bufio.Reader) (*proto.Packet, error) {
	for {
		raw, err := readRetailFrame(r)
		if err != nil {
			return nil, err
		}
		c.mu.Lock()
		sec, state := c.sec, c.state
		f, err := proto.DecodeRetailFrame(raw, sec)
		if err == nil {
			err = sec.CheckFromClient(f)
		}
		c.mu.Unlock()
		if err != nil {
			return nil, err
		}
		if state == codecEstablished {
			if f.Opcode == OpHandshake || f.Opcode == OpHandshakeAccept {
				return nil, fmt.Errorf("retail: 0x%04x after the handshake", f.Opcode)
			}
			if c.cfg.Log != nil {
				c.cfg.Log(false, f.Opcode, f.Payload)
			}
			return &proto.Packet{Opcode: f.Opcode, Data: f.Payload}, nil
		}
		switch {
		case f.Opcode == OpHandshake && state == codecHello:
			reply, final, err := c.hs.Respond(f.Payload, false)
			if err != nil {
				return nil, err
			}
			// The challenge goes plain under the hello's key; the session key
			// takes over after it (READ: the client switches on checking it).
			if err := c.sess.Send(&proto.Packet{Opcode: OpHandshake, Data: reply.Encode()}); err != nil {
				return nil, err
			}
			c.mu.Lock()
			c.sec.Cipher = final
			c.state = codecChallenge
			c.mu.Unlock()
		case f.Opcode == OpHandshakeAccept && (state == codecChallenge || c.hs.Hello.Flags&proto.RetailFlagHandshake == 0):
			// READ: the client's 0x9000 ends the handshake (and comes at once
			// when there is no key exchange, 0x4b1f92..0x4b20b1).
			c.mu.Lock()
			c.state = codecEstablished
			c.mu.Unlock()
		default:
			return nil, fmt.Errorf("%w: 0x%04x", ErrBeforeHandshake, f.Opcode)
		}
	}
}

// readRetailFrame reads one whole frame (proto.RetailFrameLen's bound).
func readRetailFrame(r *bufio.Reader) ([]byte, error) {
	head, err := r.Peek(2)
	if err != nil {
		return nil, err
	}
	n, err := proto.RetailFrameLen(head)
	if err != nil && !errors.Is(err, proto.ErrRetailNeedMore) {
		return nil, err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return buf, nil
}

// AppendFrame encodes p as the server sends it: count and check 0, encrypted
// when Encrypt says so, as 0x600D parts when Massive says so.
func (c *ServerCodec) AppendFrame(out []byte, p *proto.Packet) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sec == nil {
		return out, fmt.Errorf("retail: Send before the hello")
	}
	enc := c.cfg.Encrypt != nil && c.cfg.Encrypt(p.Opcode, p.Data)
	logged := c.state == codecEstablished && c.cfg.Log != nil
	if c.cfg.Massive != nil && c.cfg.Massive(p.Opcode) {
		// READ: the massive writer's frames are plain (+0x1d = 0, 0x41f580;
		// AgentServer's 0x437cf0 the same).
		for _, part := range MassiveParts(p.Opcode, p.Data, massivePartSize) {
			b, err := c.sec.EncodeServerFrame(OpMassive, part, false)
			if err != nil {
				return out, err
			}
			out = append(out, b...)
		}
		if logged {
			c.cfg.Log(true, p.Opcode, p.Data)
		}
		return out, nil
	}
	b, err := c.sec.EncodeServerFrame(p.Opcode, p.Data, enc)
	if err != nil {
		return out, err
	}
	if len(b) > proto.RetailMaxFrame {
		return out, fmt.Errorf("retail: a %d-byte frame for 0x%04x is over %d", len(b), p.Opcode, proto.RetailMaxFrame)
	}
	if logged {
		c.cfg.Log(true, p.Opcode, p.Data)
	}
	return append(out, b...), nil
}
