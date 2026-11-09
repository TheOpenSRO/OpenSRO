// Package relay is the front's proxy and the world hosts' end of it (round
// 869 lane W2, OURS, docs/protocol/game_worlds.md 12.2): a front keeps each
// client's one TCP connection and opens an internal stream to the process
// that owns the character's world; when the character moves to a world on
// another process, the host it leaves asks the front to re-route, and the
// front opens a stream to the new host and closes the old one. The client's
// protocol is unchanged -- it never learns there is more than one process.
//
// The stream is OpenSRO's own framing (proto.Read / proto.Write, no
// security, as every production session runs) with a few control frames in
// an internal opcode range the front never forwards either way:
//
//	front -> host  OpHello    the first frame: the shared secret, the
//	                          player's address, and a hand-off or a recovery
//	host -> front  OpBind     the account and character now in the world on
//	                          the stream (what a recovery restores)
//	host -> front  OpReroute  move this client to another host, with the
//	                          hand-off the new host continues from
//
// The host's session layer runs the hand-off itself (internal/session); this
// package only carries it.
package relay

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// The control opcodes (OURS): 0xFE00..0xFE0F, never on a client's wire.
const (
	OpHello   uint16 = 0xFE00
	OpAdopt   uint16 = 0xFE01 // the host's synthetic packet for a hello with a hand-off
	OpBind    uint16 = 0xFE02
	OpReroute uint16 = 0xFE03
)

// Version is the relay protocol's version: a host refuses a hello of
// another (the rolling deploy's check, game_worlds.md 12.4).
const Version = "869w2.1"

// IsControl reports an opcode of the relay's own range.
func IsControl(op uint16) bool { return op&0xFFF0 == 0xFE00 }

// Bind is who is in the world on a stream.
type Bind struct {
	Account  int64  `json:"account"`
	Username string `json:"username"`
	Char     int64  `json:"char"`
}

// Hello is a stream's first frame.
type Hello struct {
	Secret  string `json:"secret"`
	Version string `json:"version"`
	Front   string `json:"front"`
	Client  string `json:"client"`
	// Handoff is the session layer's hand-off (a character moving here
	// from another host), nil for a fresh login.
	Handoff json.RawMessage `json:"handoff,omitempty"`
	// Recover is a character whose host's stream broke: put it back at its
	// return point.
	Recover *Bind `json:"recover,omitempty"`
}

// Reroute is a host's request to move its client.
type Reroute struct {
	Host    string          `json:"host"`
	Addr    string          `json:"addr"`
	Handoff json.RawMessage `json:"handoff"`
	// Consumed is how many of the client's frames the host handled on the
	// stream: the front sends the ones after them to the new host, so a
	// frame the client sent while the move was decided is not lost.
	Consumed int64 `json:"consumed"`
}

// helloKey is the session value the host codec stores the hello under.
const helloKey = "relay.hello"

// HelloOf is the hello sess's stream opened with, if it is a relayed one.
func HelloOf(sess *gateway.Session) (*Hello, bool) {
	if sess == nil {
		return nil, false
	}
	v, ok := sess.Get(helloKey)
	if !ok {
		return nil, false
	}
	h, ok := v.(*Hello)
	return h, ok
}

// Relayed reports a session a front relays.
func Relayed(sess *gateway.Session) bool {
	_, ok := HelloOf(sess)
	return ok
}

func control(op uint16, v any) *proto.Packet {
	b, _ := json.Marshal(v)
	return &proto.Packet{Opcode: op, Data: b}
}

// SendBind tells sess's front who is in the world on it (no-op for a session
// not relayed).
func SendBind(sess *gateway.Session, b Bind) error {
	if !Relayed(sess) {
		return nil
	}
	return sess.Send(control(OpBind, b))
}

// SendReroute asks sess's front to move its client to r's host.
func SendReroute(sess *gateway.Session, r Reroute) error {
	if !Relayed(sess) {
		return errors.New("relay: not a relayed session")
	}
	r.Consumed = Consumed(sess)
	p := control(OpReroute, r)
	if len(p.Data) > proto.MaxPayload {
		return fmt.Errorf("relay: a hand-off of %d bytes does not fit one frame", len(p.Data))
	}
	return sess.Send(p)
}

// ErrBadHello is a stream whose first frame is not a valid hello.
var ErrBadHello = errors.New("relay: bad hello")

// HostCodec is the world host's end of the streams (a gateway.Codec on the
// host's relay listener).
type HostCodec struct {
	Secret string
	sess   *gateway.Session
	hello  bool
	// read counts the client's frames handed to the handlers.
	read atomic.Int64
}

// consumedKey holds the codec's frame count.
const consumedKey = "relay.consumed"

// Consumed is how many of the client's frames sess's handlers have been
// given (each is handled before the next is read).
func Consumed(sess *gateway.Session) int64 {
	if v, ok := sess.Get(consumedKey); ok {
		if c, ok := v.(*atomic.Int64); ok {
			return c.Load()
		}
	}
	return 0
}

// NewHostCodec is gateway.Server.Codec for the relay listener.
func NewHostCodec(secret string) func() gateway.Codec {
	return func() gateway.Codec { return &HostCodec{Secret: secret} }
}

// Start implements gateway.Codec.
func (c *HostCodec) Start(sess *gateway.Session) error {
	c.sess = sess
	return nil
}

// ReadPacket implements gateway.Codec: the hello first (answered by an
// OpAdopt packet for the handlers when it carries a hand-off or a recovery),
// then the client's frames.
func (c *HostCodec) ReadPacket(r *bufio.Reader) (*proto.Packet, error) {
	if !c.hello {
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			return nil, err
		}
		if p.Opcode != OpHello {
			return nil, ErrBadHello
		}
		var h Hello
		if err := json.Unmarshal(p.Data, &h); err != nil {
			return nil, ErrBadHello
		}
		if subtle.ConstantTimeCompare([]byte(h.Secret), []byte(c.Secret)) != 1 {
			return nil, fmt.Errorf("%w: wrong secret", ErrBadHello)
		}
		if h.Version != Version {
			return nil, fmt.Errorf("%w: version %q, this host runs %q", ErrBadHello, h.Version, Version)
		}
		c.hello = true
		h.Secret = ""
		c.sess.Set(helloKey, &h)
		c.sess.Set(consumedKey, &c.read)
		if h.Client != "" {
			c.sess.SetRemoteAddr(gateway.RelayAddr{Text: h.Client})
		}
		if h.Handoff != nil || h.Recover != nil {
			return &proto.Packet{Opcode: OpAdopt, Data: append([]byte(nil), p.Data...)}, nil
		}
	}
	for {
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			return nil, err
		}
		if IsControl(p.Opcode) {
			continue // a front never forwards these; drop what slips by
		}
		c.read.Add(1)
		return p, nil
	}
}

// AppendFrame implements gateway.Codec.
func (c *HostCodec) AppendFrame(out []byte, p *proto.Packet) ([]byte, error) {
	var b bytes.Buffer
	if err := proto.Write(&b, p, nil, nil); err != nil {
		return out, err
	}
	return append(out, b.Bytes()...), nil
}

// writeFrame writes one frame to w.
func writeFrame(w io.Writer, p *proto.Packet) error {
	var b bytes.Buffer
	if err := proto.Write(&b, p, nil, nil); err != nil {
		return err
	}
	_, err := w.Write(b.Bytes())
	return err
}

// dialHello opens a stream to addr and sends h.
func dialHello(ctx context.Context, dial func(ctx context.Context, addr string) (net.Conn, error), addr string, h Hello) (net.Conn, error) {
	conn, err := dial(ctx, addr)
	if err != nil {
		return nil, err
	}
	if err := writeFrame(conn, control(OpHello, h)); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func unmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

// SendUnbind tells sess's front nobody is in the world on it any more (a
// logout, a kick): the stream's end that follows is not a recovery.
func SendUnbind(sess *gateway.Session) error {
	if !Relayed(sess) {
		return nil
	}
	return sess.Send(control(OpBind, Bind{}))
}
