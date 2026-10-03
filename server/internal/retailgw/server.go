package retailgw

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Fault makes the fake gateway misbehave in one way (for tests).
type Fault int

const (
	FaultNone Fault = iota
	// FaultStallAfterHello sends the 0x5000 and then nothing.
	FaultStallAfterHello
	// FaultBadSignature sends a wrong 0x10 challenge.
	FaultBadSignature
	// FaultCheckByte sends the 0xA101 with a non-zero check byte.
	FaultCheckByte
	// FaultTruncatedList cuts the 0xA101 payload short (a whole frame).
	FaultTruncatedList
	// FaultMalformedList puts a 7 where a shard's flag byte belongs.
	FaultMalformedList
	// FaultTruncatedFrame sends half of the 0xA101 frame and closes.
	FaultTruncatedFrame
	// FaultOversizeFrame announces a frame over proto.RetailMaxFrame.
	FaultOversizeFrame
	// FaultNotGateway names itself AgentServer in 0x2001.
	FaultNotGateway
	// FaultFlood sends keep-alives (0x2002) instead of the list.
	FaultFlood
	// FaultFloodBytes sends 20 large unknown frames instead of the list.
	FaultFloodBytes
)

// Config is one fake gateway. The zero value of each field is the retail
// behaviour READ in docs/protocol/opcodes/gateway.md unless noted.
type Config struct {
	List ShardList
	// ContentID decides the farm byte (FarmByteFor) and is what 0x6100 must
	// carry; Version likewise (0 accepts any).
	ContentID byte
	Version   uint32
	// Flags of the first 0x5000 (0 means 0x0E, the retail set: Blowfish,
	// security bytes, key exchange).
	Flags byte
	// Refuse, when non-zero, answers 0x6100 with [2, Refuse].
	Refuse byte
	// PlainPatchReply sends 0xA100 as a plain frame instead of the massive
	// 0x600D pair GatewayServer uses (0x4053ab, 0x41f7d0).
	PlainPatchReply bool
	// EncryptList encrypts the 0xA101 (GatewayServer sends it plain, alloc(0)
	// at 0x405816; a proxy may not).
	EncryptList bool
	Fault       Fault
	// CRCSeeds, when set, is the crc seed of each successive connection
	// (the last one repeats); otherwise a random seed with a known table.
	CRCSeeds []uint32
	// Fixed, when set, replaces every random value of the handshake.
	Fixed *Fixed
	// Record, when set, receives every frame each way, and a nil b from the
	// server when the fake itself hangs up.
	Record func(conn int, fromServer bool, b []byte)
	Logf   func(format string, args ...any)
}

// Fixed handshake values (tests and transcripts).
type Fixed struct {
	BlowfishKey  [8]byte
	CountSeed    uint32
	HandshakeKey [8]byte
	G, P         uint32
	Y            uint32 // the server's private value
}

// Server is a fake retail gateway.
type Server struct {
	cfg   Config
	ln    net.Listener
	mu    sync.Mutex
	conns int
	wg    sync.WaitGroup
}

// Listen starts a fake gateway on addr ("127.0.0.1:0" for a free port).
func Listen(addr string, cfg Config) (*Server, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	if cfg.Flags == 0 {
		cfg.Flags = proto.RetailFlagBlowfish | proto.RetailFlagSecurity | proto.RetailFlagHandshake
	}
	if cfg.Logf == nil {
		cfg.Logf = log.Printf
	}
	s := &Server{cfg: cfg, ln: ln}
	s.wg.Add(1)
	go s.accept()
	return s, nil
}

// Addr is where it listens.
func (s *Server) Addr() string { return s.ln.Addr().String() }

// Close stops it and waits for its connections.
func (s *Server) Close() error {
	err := s.ln.Close()
	s.wg.Wait()
	return err
}

// Connections counts the connections accepted so far.
func (s *Server) Connections() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.conns
}

func (s *Server) accept() {
	defer s.wg.Done()
	for {
		c, err := s.ln.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		n := s.conns
		s.conns++
		s.mu.Unlock()
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer c.Close()
			_ = c.SetDeadline(time.Now().Add(10 * time.Second))
			if err := s.serve(c, n); err != nil && !errors.Is(err, io.EOF) {
				s.cfg.Logf("retailgw fake: connection %d: %v", n, err)
			}
		}()
	}
}

func random32() uint32 {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return binary.LittleEndian.Uint32(b[:])
}

func randomPrime() uint32 {
	for {
		p, err := rand.Prime(rand.Reader, 31)
		if err == nil && p.Cmp(big.NewInt(1<<31)) < 0 {
			return uint32(p.Uint64())
		}
	}
}

type sconn struct {
	s    *Server
	c    net.Conn
	n    int
	sec  *proto.RetailSecurity
	h    ServerHello
	y, k uint32
	key1 *proto.RetailCipher
}

func (sc *sconn) write(b []byte) error {
	if sc.s.cfg.Record != nil {
		sc.s.cfg.Record(sc.n, true, append([]byte(nil), b...))
	}
	_, err := sc.c.Write(b)
	return err
}

func (sc *sconn) frame(op uint16, payload []byte, encrypt bool) error {
	b, err := sc.sec.EncodeServerFrame(op, payload, encrypt)
	if err != nil {
		return err
	}
	return sc.write(b)
}

func (s *Server) serve(c net.Conn, n int) error {
	cfg := s.cfg
	sc := &sconn{s: s, c: c, n: n}
	h := ServerHello{Flags: cfg.Flags}
	if f := cfg.Fixed; f != nil {
		h.BlowfishKey, h.CountSeed, h.HandshakeKey, h.G, h.P, sc.y = f.BlowfishKey, f.CountSeed, f.HandshakeKey, f.G, f.P, f.Y
	} else {
		_, _ = rand.Read(h.BlowfishKey[:])
		_, _ = rand.Read(h.HandshakeKey[:])
		h.CountSeed = random32()
		// READ (0x4c6fc0): two random primes, the smaller is G.
		a, b := randomPrime(), randomPrime()
		h.G, h.P = min(a, b), max(a, b)
		sc.y = random32() & 0x7fffffff
	}
	switch {
	case len(cfg.CRCSeeds) > 0:
		h.CRCSeed = cfg.CRCSeeds[min(n, len(cfg.CRCSeeds)-1)]
	default:
		for {
			h.CRCSeed = random32()
			if proto.CRCIndexKnown(proto.CRCIndex(h.CRCSeed)) {
				break
			}
		}
	}
	h.A = proto.ModPow(h.G, sc.y, h.P)
	sc.h = h
	sc.sec = &proto.RetailSecurity{Flags: h.Flags}
	if err := sc.write(mustFrame(sc.sec.EncodeServerFrame(OpHandshake, h.Encode(), false))); err != nil {
		return err
	}
	if h.Flags&proto.RetailFlagSecurity != 0 {
		sc.sec.Count = proto.CountSeeds(h.CountSeed)
		t, ok := proto.CRCTable(proto.CRCIndex(h.CRCSeed))
		if !ok {
			// The client must hang up before sending anything; nothing to check.
			sc.sec.CRC = nil
		} else {
			sc.sec.CRC = t
		}
	}
	if h.Flags&proto.RetailFlagBlowfish != 0 {
		ci, err := proto.NewRetailCipher(h.BlowfishKey[:])
		if err != nil {
			return err
		}
		sc.sec.Cipher = ci
	}
	var buf []byte
	tmp := make([]byte, 4096)
	for {
		for {
			fl, err := proto.RetailFrameLen(buf)
			if errors.Is(err, proto.ErrRetailNeedMore) {
				break
			}
			if err != nil {
				return err
			}
			raw := buf[:fl]
			if cfg.Record != nil {
				cfg.Record(n, false, append([]byte(nil), raw...))
			}
			buf = buf[fl:]
			if cfg.Fault == FaultStallAfterHello {
				continue // read, never answered
			}
			done, err := sc.onFrame(raw)
			if err != nil || done {
				if cfg.Record != nil {
					cfg.Record(n, true, nil)
				}
				return err
			}
		}
		k, err := c.Read(tmp)
		if k > 0 {
			buf = append(buf, tmp[:k]...)
		}
		if err != nil {
			return err
		}
	}
}

func mustFrame(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

// onFrame is the gateway's side, one client frame (READ: the server branch
// of _OnMsgReceivedBeforeHandshake, 0x4b20b6..0x4b2207, and GatewayServer's
// 0x6100/0x6101 handlers). done ends the connection.
func (sc *sconn) onFrame(raw []byte) (bool, error) {
	cfg := sc.s.cfg
	f, err := proto.DecodeRetailFrame(raw, sc.sec)
	if err != nil {
		return true, err
	}
	if err := sc.sec.CheckFromClient(f); err != nil {
		return true, err
	}
	switch f.Opcode {
	case OpHandshake:
		if sc.h.Flags&proto.RetailFlagHandshake == 0 || len(f.Payload) != 12 {
			return true, fmt.Errorf("a 0x5000 of %d bytes (the gateway's \"Handshake Recipient Size\")", len(f.Payload))
		}
		b := binary.LittleEndian.Uint32(f.Payload)
		sc.k = proto.ModPow(b, sc.y, sc.h.P)
		key1, err := proto.NewRetailCipher(sl(proto.KeyTransform(proto.Pair(sc.h.A, b), sc.k, byte(sc.k&3))))
		if err != nil {
			return true, err
		}
		sc.key1 = key1
		want := proto.KeyTransform(proto.Pair(b, sc.h.A), sc.k, byte(b&7))
		key1.EncryptBlock(want[:])
		if string(want[:]) != string(f.Payload[4:12]) {
			return true, fmt.Errorf("the client's challenge does not match (\"Handshake RecipientInfo Error\")")
		}
		chal := proto.KeyTransform(proto.Pair(sc.h.A, b), sc.k, byte(sc.h.A&7))
		key1.EncryptBlock(chal[:])
		if cfg.Fault == FaultBadSignature {
			chal[0] ^= 0xff
		}
		reply := ServerHello{Flags: proto.RetailFlagChallenge, Challenge: chal}
		if err := sc.frame(OpHandshake, reply.Encode(), false); err != nil {
			return true, err
		}
		final, err := proto.NewRetailCipher(sl(proto.KeyTransform(sc.h.HandshakeKey, sc.k, 3)))
		if err != nil {
			return true, err
		}
		sc.sec.Cipher = final
		return false, nil
	case OpHandshakeAccept:
		name := GatewayModule
		if cfg.Fault == FaultNotGateway {
			name = "AgentServer"
		}
		return false, sc.frame(OpIdentity, EncodeIdentity(name, 0), false)
	case OpIdentity:
		return false, nil
	case OpPatchRequest:
		cid, module, ver, err := DecodePatchRequest(f.Payload)
		if err != nil {
			return true, fmt.Errorf("0x6100: %v (\"certificate client module : invalid msg data\")", err)
		}
		reply := []byte{1}
		switch {
		case cfg.Refuse != 0:
			reply = []byte{2, cfg.Refuse}
		case module != ClientModule || (cfg.ContentID != 0 && cid != cfg.ContentID):
			reply = []byte{2, 1}
		case cfg.Version != 0 && ver != cfg.Version:
			reply = []byte{2, 2}
		}
		if cfg.PlainPatchReply {
			return false, sc.frame(OpPatchReply, reply, false)
		}
		for _, p := range MassiveParts(OpPatchReply, reply, 0) {
			if err := sc.frame(OpMassive, p, false); err != nil {
				return true, err
			}
		}
		return false, nil
	case OpShardListRequest:
		return sc.sendList()
	}
	return false, nil
}

func (sc *sconn) sendList() (bool, error) {
	cfg := sc.s.cfg
	payload := EncodeShardList(cfg.List, FarmByteFor(cfg.ContentID))
	switch cfg.Fault {
	case FaultTruncatedList:
		payload = payload[:len(payload)-3]
	case FaultMalformedList:
		// The first shard's flag byte follows the farm list's terminator.
		at := 1
		for _, f := range cfg.List.Farms {
			at += 1 + 1 + 2 + len(f.Name)
		}
		payload[at] = 7
	case FaultOversizeFrame:
		return true, sc.write([]byte{0xff, 0x7f, 0x01, 0xa1})
	case FaultFlood:
		// 12000 six-byte keep-alives, more than a probe's 64 KiB (OURS),
		// recorded first and written at once so a recording is the same
		// whenever the client hangs up.
		var all []byte
		for range 12000 {
			b, err := sc.sec.EncodeServerFrame(0x2002, nil, false)
			if err != nil {
				return true, err
			}
			if cfg.Record != nil {
				cfg.Record(sc.n, true, b)
			}
			all = append(all, b...)
		}
		_, err := sc.c.Write(all)
		return true, err
	case FaultFloodBytes:
		// 20 frames of 4000 bytes: past a probe's 64 KiB in under its frame
		// count (OURS).
		var all []byte
		for range 20 {
			b, err := sc.sec.EncodeServerFrame(0x2002, make([]byte, 4000), false)
			if err != nil {
				return true, err
			}
			if cfg.Record != nil {
				cfg.Record(sc.n, true, b)
			}
			all = append(all, b...)
		}
		_, err := sc.c.Write(all)
		return true, err
	}
	b, err := sc.sec.EncodeServerFrame(OpShardListReply, payload, cfg.EncryptList)
	if err != nil {
		return true, err
	}
	switch cfg.Fault {
	case FaultCheckByte:
		if b[0]&0x80 != 0 {
			return true, fmt.Errorf("FaultCheckByte needs a plain list")
		}
		b[5] = 0x5a
	case FaultTruncatedFrame:
		return true, sc.write(b[:len(b)/2])
	}
	return false, sc.write(b)
}
