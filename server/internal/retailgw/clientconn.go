package retailgw

// A retail client connection past the handshake (round 788): the client side
// of the framing for driving a server through login in tests -- the gateway's
// 0x6100 / 0x6101 / 0x6102 and the agent's 0x6103 and lobby. The handshake is
// Conversation's own (client.go); after it the caller sends and reads
// messages. Kept apart from Conversation and Probe, which stop at the list.

import (
	"context"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// ClientConn is one retail connection, client side, after the handshake
// and the client's 0x2001.
type ClientConn struct {
	conn    net.Conn
	conv    *Conversation
	buf     []byte
	massive Massive
	// Identity is the server's 0x2001 name, once ReadIdentity has run.
	Identity string
}

// DialClient connects to addr and runs the handshake as the retail client
// does, ending with the client's 0x2001 (READ: sent on the connected
// notification, CClientProcess::vslot_010 0x4ce8c0).
func DialClient(ctx context.Context, addr string, info ClientInfo) (*ClientConn, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	c := &ClientConn{conn: conn, conv: NewConversation(info)}
	for c.conv.state == stHello || c.conv.state == stChallenge {
		raw, err := c.readFrame()
		if err != nil {
			conn.Close()
			return nil, err
		}
		out, err := c.conv.Frame(raw)
		if err != nil {
			conn.Close()
			return nil, err
		}
		for _, o := range out {
			if _, err := conn.Write(o); err != nil {
				conn.Close()
				return nil, err
			}
		}
	}
	return c, nil
}

func (c *ClientConn) readFrame() ([]byte, error) {
	tmp := make([]byte, 4096)
	for {
		n, err := proto.RetailFrameLen(c.buf)
		if err == nil {
			raw := c.buf[:n]
			c.buf = append([]byte(nil), c.buf[n:]...)
			return raw, nil
		}
		if !errors.Is(err, proto.ErrRetailNeedMore) {
			return nil, err
		}
		k, err := c.conn.Read(tmp)
		if k > 0 {
			c.buf = append(c.buf, tmp[:k]...)
		}
		if err != nil {
			return nil, err
		}
	}
}

// Send sends one message, encrypted when asked (the client encrypts 0x2001,
// 0x6100..0x6103 and its lobby messages; READ, the allocator's argument).
func (c *ClientConn) Send(op uint16, payload []byte, encrypt bool) error {
	b, err := c.conv.sec.EncodeClientFrame(op, payload, encrypt)
	if err != nil {
		return err
	}
	_, err = c.conn.Write(b)
	return err
}

// Message is one message from the server; a massive one arrives whole.
type Message struct {
	Opcode    uint16
	Payload   []byte
	Encrypted bool
	Massive   bool
}

// Recv reads the next message, applying the client's checks to each frame
// (count and check 0, READ 0x4b0f60) and reassembling 0x600D.
func (c *ClientConn) Recv() (Message, error) {
	for {
		raw, err := c.readFrame()
		if err != nil {
			return Message{}, err
		}
		f, err := proto.DecodeRetailFrame(raw, c.conv.sec)
		if err != nil {
			return Message{}, err
		}
		if err := c.conv.sec.CheckFromServer(f); err != nil {
			return Message{}, err
		}
		if f.Opcode != OpMassive {
			return Message{Opcode: f.Opcode, Payload: f.Payload, Encrypted: f.Encrypted}, nil
		}
		op, data, done, err := c.massive.Feed(f.Payload)
		if err != nil {
			return Message{}, err
		}
		if done {
			return Message{Opcode: op, Payload: data, Encrypted: f.Encrypted, Massive: true}, nil
		}
	}
}

// Expect reads messages until one with opcode op, passing over the others
// (keep-alives), at most MaxFrames of them.
func (c *ClientConn) Expect(op uint16) (Message, error) {
	for range MaxFrames {
		m, err := c.Recv()
		if err != nil {
			return Message{}, fmt.Errorf("waiting for 0x%04x: %w", op, err)
		}
		if m.Opcode == op {
			return m, nil
		}
	}
	return Message{}, fmt.Errorf("no 0x%04x in %d messages", op, MaxFrames)
}

// ReadIdentity waits for the server's 0x2001 and keeps its name.
func (c *ClientConn) ReadIdentity() (string, error) {
	m, err := c.Expect(OpIdentity)
	if err != nil {
		return "", err
	}
	name, _, err := DecodeIdentity(m.Payload)
	if err != nil {
		return "", err
	}
	c.Identity = name
	return name, nil
}

// SetDeadline bounds the connection's reads and writes.
func (c *ClientConn) SetDeadline(t time.Time) error { return c.conn.SetDeadline(t) }

// Close hangs up.
func (c *ClientConn) Close() error { return c.conn.Close() }
