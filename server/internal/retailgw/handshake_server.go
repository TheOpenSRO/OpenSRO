package retailgw

// The server's half of the retail handshake (round 788), shared by the fake
// gateway (Server) and the real listeners' codec (ServerCodec). READ: the
// server branch (mode 0) of ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake,
// 0x4b20b6..0x4b2207 in sro_client's copy of the net engine, and the hello's
// writer CNetEngine::FUN_00965c20 in SR_GameServer (handshake.md, "The
// client's side, READ (round 681)").

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// DefaultServerFlags is the hello's flag set retail sends: Blowfish, the
// security bytes and the key exchange (READ: 0x0E, handshake.md).
const DefaultServerFlags = proto.RetailFlagBlowfish | proto.RetailFlagSecurity | proto.RetailFlagHandshake

// ServerHandshake is one connection's key exchange, server side.
type ServerHandshake struct {
	Hello ServerHello
	// Y is the server's private value; K the shared secret once the client's
	// 0x5000 has arrived.
	Y, K uint32
}

// NewServerHandshake makes a hello. With fixed nil every value is random:
// the keys and the count seed from crypto/rand; G and P two random 31-bit
// primes, the smaller as G (READ 0x4c6fc0); Y & 0x7fffffff (READ 0x4c6ff0);
// A = G^Y mod P. crcSeed draws the crc seed; nil draws a random one whose
// table index this package can build (proto.CRCIndexKnown -- the server
// chooses, so a server never picks one of the 37 tables it cannot build).
func NewServerHandshake(flags byte, fixed *Fixed, crcSeed func() uint32) *ServerHandshake {
	if flags == 0 {
		flags = DefaultServerFlags
	}
	hs := &ServerHandshake{}
	h := ServerHello{Flags: flags}
	if f := fixed; f != nil {
		h.BlowfishKey, h.CountSeed, h.HandshakeKey, h.G, h.P, hs.Y = f.BlowfishKey, f.CountSeed, f.HandshakeKey, f.G, f.P, f.Y
	} else {
		_, _ = rand.Read(h.BlowfishKey[:])
		_, _ = rand.Read(h.HandshakeKey[:])
		h.CountSeed = random32()
		a, b := randomPrime(), randomPrime()
		h.G, h.P = min(a, b), max(a, b)
		hs.Y = random32() & 0x7fffffff
	}
	if crcSeed != nil {
		h.CRCSeed = crcSeed()
	} else {
		h.CRCSeed = RandomKnownCRCSeed()
	}
	h.A = proto.ModPow(h.G, hs.Y, h.P)
	hs.Hello = h
	return hs
}

// RandomKnownCRCSeed is a random crc seed whose checksum table can be built.
func RandomKnownCRCSeed() uint32 {
	for {
		s := random32()
		if proto.CRCIndexKnown(proto.CRCIndex(s)) {
			return s
		}
	}
}

// Security is the connection's state once the hello is sent (READ, the
// client's set-up on the same hello, CNetEngine::FUN_004b0cc0): the rolling
// byte's state from the count seed, the checksum table from the crc seed, and
// Blowfish keyed with the hello's key. A crc seed whose table cannot be built
// leaves CRC nil (the fake's test of a client that must hang up).
func (hs *ServerHandshake) Security() (*proto.RetailSecurity, error) {
	h := hs.Hello
	sec := &proto.RetailSecurity{Flags: h.Flags}
	if h.Flags&proto.RetailFlagSecurity != 0 {
		sec.Count = proto.CountSeeds(h.CountSeed)
		if t, ok := proto.CRCTable(proto.CRCIndex(h.CRCSeed)); ok {
			sec.CRC = t
		}
	}
	if h.Flags&proto.RetailFlagBlowfish != 0 {
		ci, err := proto.NewRetailCipher(h.BlowfishKey[:])
		if err != nil {
			return nil, err
		}
		sec.Cipher = ci
	}
	return sec, nil
}

// Respond takes the client's 12-byte 0x5000 (u32 B, the 8-byte challenge)
// and returns the 0x10 hello to send back and the session cipher that
// replaces the hello's key from then on (READ, the table of handshake.md:
// K = B^Y mod P; key1 = T((A, B), K, K & 3); the client's challenge must be
// key1(T((B, A), K, B & 7)) -- "Handshake RecipientInfo Error" otherwise; the
// server's is key1(T((A, B), K, A & 7)); the session key T(handshake key, K,
// 3)). corrupt flips the server's challenge (the fake's FaultBadSignature).
func (hs *ServerHandshake) Respond(payload []byte, corrupt bool) (ServerHello, *proto.RetailCipher, error) {
	h := hs.Hello
	if h.Flags&proto.RetailFlagHandshake == 0 || len(payload) != 12 {
		return ServerHello{}, nil, fmt.Errorf("a 0x5000 of %d bytes (the gateway's \"Handshake Recipient Size\")", len(payload))
	}
	b := binary.LittleEndian.Uint32(payload)
	hs.K = proto.ModPow(b, hs.Y, h.P)
	key1, err := proto.NewRetailCipher(sl(proto.KeyTransform(proto.Pair(h.A, b), hs.K, byte(hs.K&3))))
	if err != nil {
		return ServerHello{}, nil, err
	}
	want := proto.KeyTransform(proto.Pair(b, h.A), hs.K, byte(b&7))
	key1.EncryptBlock(want[:])
	if string(want[:]) != string(payload[4:12]) {
		return ServerHello{}, nil, fmt.Errorf("the client's challenge does not match (\"Handshake RecipientInfo Error\")")
	}
	chal := proto.KeyTransform(proto.Pair(h.A, b), hs.K, byte(h.A&7))
	key1.EncryptBlock(chal[:])
	if corrupt {
		chal[0] ^= 0xff
	}
	final, err := proto.NewRetailCipher(sl(proto.KeyTransform(h.HandshakeKey, hs.K, 3)))
	if err != nil {
		return ServerHello{}, nil, err
	}
	return ServerHello{Flags: proto.RetailFlagChallenge, Challenge: chal}, final, nil
}
