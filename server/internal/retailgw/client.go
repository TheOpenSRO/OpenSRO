package retailgw

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// ClientInfo is what a retail client tells the gateway about itself in
// 0x6100 (READ): the content id -- the first byte of the archive's
// DIVISIONINFO.TXT, which the launcher passes on the command line (silkroad.exe
// 0x4370a7, 0x4331dd) and the client hands the net layer (0x844b7e) -- and the
// version, the decimal number in Media.pk2's SV.T (CGame 0x846b4e..0x846c52).
type ClientInfo struct {
	ContentID byte
	Version   uint32
}

// ErrRetry is a session that cannot be continued here but a new connection
// may succeed: the gateway chose a checksum table whose polynomial is not
// the standard one (proto.CRCIndexKnown), and gets a new random choice per
// connection.
var ErrRetry = errors.New("retail: the session's checksum table is unknown; reconnect")

type convState int

const (
	stHello convState = iota
	stChallenge
	stIdentity
	stPatch
	stList
	stDone
)

// Conversation is the client's side of the exchange up to the shard list,
// with no socket: Frame takes each whole frame the server sent and returns
// the frames to send back. The Godot client's RetailGatewayClient is the
// same machine; the transcripts in client/scripts/frontend/testdata hold the
// two to identical bytes.
type Conversation struct {
	Info ClientInfo
	// PrivateX is the key exchange's private value. The client takes a
	// fresh GUID's first dword & 0x7fffffff (READ, CoCreateGuid at
	// 0x4c7078..0x4c7082); NewConversation draws it from crypto/rand.
	PrivateX uint32

	state   convState
	sec     *proto.RetailSecurity
	hello   ServerHello
	b, k    uint32
	key1    *proto.RetailCipher
	massive Massive
	frames  int

	// List is the answer once Done.
	List     ShardList
	FarmByte bool
}

// NewConversation starts one connection's exchange.
func NewConversation(info ClientInfo) *Conversation {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return &Conversation{Info: info, PrivateX: binary.LittleEndian.Uint32(b[:]) & 0x7fffffff}
}

// Done reports that the shard list has arrived.
func (c *Conversation) Done() bool { return c.state == stDone }

// MaxFrames bounds the frames one exchange takes (OURS: keep-alives and the
// like are passed over, but not for ever).
const MaxFrames = 64

// Frame handles one whole frame from the server.
func (c *Conversation) Frame(raw []byte) ([][]byte, error) {
	c.frames++
	if c.frames > MaxFrames {
		return nil, fmt.Errorf("more than %d frames without the list", MaxFrames)
	}
	f, err := proto.DecodeRetailFrame(raw, c.sec)
	if err != nil {
		return nil, err
	}
	if c.state != stHello {
		if err := c.sec.CheckFromServer(f); err != nil {
			return nil, err
		}
	}
	switch c.state {
	case stHello, stChallenge:
		// READ (0x4b1dd2): before the handshake completes, anything but
		// 0x5000 ends the session.
		if f.Opcode != OpHandshake {
			return nil, fmt.Errorf("opcode 0x%04x before the handshake finished (only 0x5000 is accepted)", f.Opcode)
		}
		h, err := DecodeServerHello(f.Payload)
		if err != nil {
			return nil, err
		}
		if c.state == stHello {
			return c.onHello(h)
		}
		return c.onChallenge(h)
	case stIdentity:
		if f.Opcode != OpIdentity {
			return nil, nil // OURS: anything else (a keep-alive) is passed over
		}
		name, _, err := DecodeIdentity(f.Payload)
		if err != nil {
			return nil, err
		}
		if name != GatewayModule {
			return nil, fmt.Errorf("the server is %q, not %s (the client asks only a gateway for the list)", name, GatewayModule)
		}
		c.state = stPatch
		return c.send(OpPatchRequest, EncodePatchRequest(c.Info.ContentID, c.Info.Version), true)
	case stPatch, stList:
		op, data := f.Opcode, f.Payload
		if op == OpMassive {
			var done bool
			op, data, done, err = c.massive.Feed(f.Payload)
			if err != nil {
				return nil, err
			}
			if !done {
				return nil, nil
			}
		}
		if c.state == stPatch && op == OpPatchReply {
			if len(data) < 1 {
				return nil, fmt.Errorf("0xA100 is empty")
			}
			if data[0] != 1 {
				code := -1
				if len(data) > 1 {
					code = int(data[1])
				}
				return nil, fmt.Errorf("the gateway refused this client in 0xA100: result %d, code %d (%s)", data[0], code, patchCodeText(code))
			}
			c.state = stList
			return c.send(OpShardListRequest, nil, true)
		}
		if c.state == stList && op == OpShardListReply {
			l, farm, err := DecodeShardListFor(data, c.Info.ContentID)
			if err != nil {
				return nil, err
			}
			c.List, c.FarmByte = l, farm
			c.state = stDone
			return nil, nil
		}
		return nil, nil
	}
	return nil, fmt.Errorf("a frame after the list")
}

// patchCodeText names the 0xA100 refusal codes the client's handler
// switches on (READ, CClientProcess::vslot_015 0x4cf0c0: 2 the patch path,
// 4 GatewayServer's "not in service" reply [2, 4] at 0x4053c8; INFERRED
// meanings).
func patchCodeText(code int) string {
	switch code {
	case 2:
		return "a newer client is needed (patch)"
	case 4:
		return "the server is not in service"
	}
	return "see docs/protocol/opcodes/gateway.md"
}

func (c *Conversation) send(op uint16, payload []byte, encrypt bool) ([][]byte, error) {
	b, err := c.sec.EncodeClientFrame(op, payload, encrypt)
	if err != nil {
		return nil, err
	}
	return [][]byte{b}, nil
}

func (c *Conversation) onHello(h ServerHello) ([][]byte, error) {
	if h.Flags&proto.RetailFlagChallenge != 0 {
		return nil, fmt.Errorf("0x5000 flags 0x%02x: a challenge before the key exchange", h.Flags)
	}
	if h.Flags&^(proto.RetailFlagBlowfish|proto.RetailFlagSecurity|proto.RetailFlagHandshake) != 0 {
		// 0x01 (no set-up at all) and the unused bits: not supported (OURS).
		return nil, fmt.Errorf("0x5000 flags 0x%02x: a variant this client does not speak", h.Flags)
	}
	c.hello = h
	c.sec = &proto.RetailSecurity{Flags: h.Flags}
	if h.Flags&proto.RetailFlagSecurity != 0 {
		idx := proto.CRCIndex(h.CRCSeed)
		t, ok := proto.CRCTable(idx)
		if !ok {
			return nil, fmt.Errorf("%w (index %d)", ErrRetry, idx)
		}
		c.sec.Count = proto.CountSeeds(h.CountSeed)
		c.sec.CRC = t
	}
	if h.Flags&proto.RetailFlagBlowfish != 0 {
		ci, err := proto.NewRetailCipher(h.BlowfishKey[:])
		if err != nil {
			return nil, err
		}
		c.sec.Cipher = ci
	}
	if h.Flags&proto.RetailFlagHandshake == 0 {
		// READ (0x4b1f92..0x4b20b1): no key exchange -- accept at once.
		out, err := c.send(OpHandshakeAccept, nil, false)
		if err != nil {
			return nil, err
		}
		return c.established(out)
	}
	if h.P < 2 {
		return nil, fmt.Errorf("0x5000: modulus %d (the client would divide by zero)", h.P)
	}
	c.b = proto.ModPow(h.G, c.PrivateX, h.P)
	c.k = proto.ModPow(h.A, c.PrivateX, h.P)
	key1, err := proto.NewRetailCipher(sl(proto.KeyTransform(proto.Pair(h.A, c.b), c.k, byte(c.k&3))))
	if err != nil {
		return nil, err
	}
	c.key1 = key1
	chal := proto.KeyTransform(proto.Pair(c.b, h.A), c.k, byte(c.b&7))
	key1.EncryptBlock(chal[:])
	var w writer
	w.u32(c.b)
	w.b = append(w.b, chal[:]...)
	c.state = stChallenge
	return c.send(OpHandshake, w.b, false)
}

func (c *Conversation) onChallenge(h ServerHello) ([][]byte, error) {
	if h.Flags != proto.RetailFlagChallenge {
		return nil, fmt.Errorf("0x5000 flags 0x%02x where the challenge (0x10) was due", h.Flags)
	}
	want := proto.KeyTransform(proto.Pair(c.hello.A, c.b), c.k, byte(c.hello.A&7))
	c.key1.EncryptBlock(want[:])
	if want != h.Challenge {
		return nil, fmt.Errorf("the server's challenge does not match (the client's \"Handshake ServerSignature Error\")")
	}
	final, err := proto.NewRetailCipher(sl(proto.KeyTransform(c.hello.HandshakeKey, c.k, 3)))
	if err != nil {
		return nil, err
	}
	c.sec.Cipher = final
	out, err := c.send(OpHandshakeAccept, nil, false)
	if err != nil {
		return nil, err
	}
	return c.established(out)
}

// established follows the accept with the client's identity (READ: 0x2001
// with ClientModule and 0, encrypted, CClientProcess::vslot_010; sent on the
// session's connected notification, INFERRED to follow the accept).
func (c *Conversation) established(out [][]byte) ([][]byte, error) {
	id, err := c.send(OpIdentity, EncodeIdentity(ClientModule, 0), true)
	if err != nil {
		return nil, err
	}
	c.state = stIdentity
	return append(out, id...), nil
}

func sl(v [8]byte) []byte { return v[:] }

// ProbeOptions bound one Probe (OURS).
type ProbeOptions struct {
	Info        ClientInfo
	Budget      time.Duration // the whole probe, every attempt
	MaxAttempts int           // connections, for ErrRetry
	MaxBytes    int           // read per attempt
	// PrivateX, when set, replaces the random private value (tests).
	PrivateX *uint32
}

// DefaultProbeOptions are the Godot client's limits (OURS).
func DefaultProbeOptions(info ClientInfo) ProbeOptions {
	return ProbeOptions{Info: info, Budget: 4 * time.Second, MaxAttempts: 3, MaxBytes: 64 << 10}
}

// Probe asks the gateway at addr for its shard list and closes.
func Probe(ctx context.Context, addr string, opt ProbeOptions) (ShardList, error) {
	ctx, cancel := context.WithTimeout(ctx, opt.Budget)
	defer cancel()
	var last error
	for attempt := 1; attempt <= max(opt.MaxAttempts, 1); attempt++ {
		l, err := probeOnce(ctx, addr, opt)
		if err == nil {
			return l, nil
		}
		last = err
		if !errors.Is(err, ErrRetry) {
			return ShardList{}, err
		}
	}
	return ShardList{}, fmt.Errorf("after %d attempts: %w", opt.MaxAttempts, last)
}

func probeOnce(ctx context.Context, addr string, opt ProbeOptions) (ShardList, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return ShardList{}, err
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	c := NewConversation(opt.Info)
	if opt.PrivateX != nil {
		c.PrivateX = *opt.PrivateX
	}
	var buf []byte
	tmp := make([]byte, 4096)
	read := 0
	for !c.Done() {
		for {
			n, err := proto.RetailFrameLen(buf)
			if errors.Is(err, proto.ErrRetailNeedMore) {
				break
			}
			if err != nil {
				return ShardList{}, err
			}
			out, err := c.Frame(buf[:n])
			buf = buf[n:]
			if err != nil {
				return ShardList{}, err
			}
			for _, o := range out {
				if _, err := conn.Write(o); err != nil {
					return ShardList{}, err
				}
			}
			if c.Done() {
				return c.List, nil
			}
		}
		n, err := conn.Read(tmp)
		if n > 0 {
			read += n
			if read > opt.MaxBytes {
				return ShardList{}, fmt.Errorf("more than %d bytes without the list", opt.MaxBytes)
			}
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return ShardList{}, fmt.Errorf("the connection ended before the list: %w", err)
		}
	}
	return c.List, nil
}
