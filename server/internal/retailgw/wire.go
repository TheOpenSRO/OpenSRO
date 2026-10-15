// Package retailgw speaks the original gateway protocol as far as a server
// list (round 681): the client side that reads a retail gateway's shard list
// and status (Probe, the reference the Godot client's RetailGatewayClient is
// held to byte for byte), and a fake retail gateway (Server) to test it
// without anyone else's server. Round 788 goes on to the login (the
// client's RunLogin, login_client.go; the fake's, fake_login.go).
//
// Round 788 added the server side for real use: ServerHandshake (the
// handshake both the fake and the real listeners run), ServerCodec (the
// retail framing as a gateway.Codec, so OpenSRO's own server speaks it --
// internal/retailsrv) and ClientConn (a client connection past the handshake,
// to drive a server through login in tests).
//
// The facts are in docs/protocol/opcodes/gateway.md and handshake.md, each
// labelled READ (the retail client's and GatewayServer's own code, with
// addresses), MEASURED, INFERRED or OURS.
package retailgw

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Opcodes of the exchange (READ: docs/protocol/opcodes/gateway.md).
const (
	OpHandshake        uint16 = 0x5000
	OpHandshakeAccept  uint16 = 0x9000
	OpIdentity         uint16 = 0x2001
	OpMassive          uint16 = 0x600D
	OpPatchRequest     uint16 = 0x6100
	OpPatchReply       uint16 = 0xA100
	OpShardListRequest uint16 = 0x6101
	OpShardListReply   uint16 = 0xA101
)

// Module names (READ: "SR_Client" at sro_client 0xdd3050, passed to the net
// layer's init at 0x844b8b and sent in 0x2001 and 0x6100; "GatewayServer" at
// 0xe1b310, the identity the client answers with 0x6100, 0x4cea72).
const (
	ClientModule  = "SR_Client"
	GatewayModule = "GatewayServer"
)

// Limits (OURS): a gateway's list is a few dozen bytes per shard.
const (
	MaxShards       = 64
	MaxFarms        = 64
	MaxMassiveParts = 16
	MaxMassiveSize  = 0x8000
)

// Shard is one 0xA101 entry (READ, sro_client CClientProcess::FUN_004cda30,
// and GatewayServer 0x412c80).
type Shard struct {
	ID       uint16
	Name     string
	Current  uint16
	Capacity uint16
	State    byte
	Farm     byte
}

// Farm is one 0xA101 farm entry.
type Farm struct {
	ID   byte
	Name string
}

// ShardList is a whole 0xA101.
type ShardList struct {
	Farms  []Farm
	Shards []Shard
}

// FarmByteFor reports whether a gateway serving this content id appends the
// farm id byte to each shard (READ, GatewayServer 0x412d7b..0x412daa: the
// server's own content id compared with 3, 5, 9, 10, 0x1a, 0x1c, 0x15, 0x16,
// 0x17, 0x22). The client reads the byte when a mode word of its own is 1 or
// 4 (FUN_004cda30); where that word is set is OPEN.
func FarmByteFor(contentID byte) bool {
	switch contentID {
	case 3, 5, 9, 10, 0x15, 0x16, 0x17, 0x1a, 0x1c, 0x22:
		return true
	}
	return false
}

// errShort is a payload that ends early.
var errShort = errors.New("ends early")

type reader struct {
	p   []byte
	off int
}

func (r *reader) u8() (byte, error) {
	if r.off+1 > len(r.p) {
		return 0, errShort
	}
	v := r.p[r.off]
	r.off++
	return v, nil
}

func (r *reader) u16() (uint16, error) {
	if r.off+2 > len(r.p) {
		return 0, errShort
	}
	v := binary.LittleEndian.Uint16(r.p[r.off:])
	r.off += 2
	return v, nil
}

func (r *reader) u32() (uint32, error) {
	if r.off+4 > len(r.p) {
		return 0, errShort
	}
	v := binary.LittleEndian.Uint32(r.p[r.off:])
	r.off += 4
	return v, nil
}

func (r *reader) bytes(n int) ([]byte, error) {
	if n < 0 || r.off+n > len(r.p) {
		return nil, errShort
	}
	v := r.p[r.off : r.off+n]
	r.off += n
	return v, nil
}

// str reads a u16-length string (READ: CClientProcess::FUN_004d36a0; the
// sender writes lstrlenA's length then the bytes, 0x4cc920).
func (r *reader) str() (string, error) {
	n, err := r.u16()
	if err != nil {
		return "", err
	}
	b, err := r.bytes(int(n))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func (r *reader) done() bool { return r.off == len(r.p) }

type writer struct{ b []byte }

func (w *writer) u8(v byte)    { w.b = append(w.b, v) }
func (w *writer) u16(v uint16) { w.b = binary.LittleEndian.AppendUint16(w.b, v) }
func (w *writer) u32(v uint32) { w.b = binary.LittleEndian.AppendUint32(w.b, v) }
func (w *writer) str(s string) {
	w.u16(uint16(len(s)))
	w.b = append(w.b, s...)
}

// EncodeShardList writes a 0xA101 payload as GatewayServer does (0x405800,
// 0x412c80): per farm u8 1, u8 id, string name; u8 0; per shard u8 1, u16
// id, string name, u16 current, u16 capacity, u8 state, and u8 farm id when
// farmByte; u8 0.
func EncodeShardList(l ShardList, farmByte bool) []byte {
	var w writer
	for _, f := range l.Farms {
		w.u8(1)
		w.u8(f.ID)
		w.str(f.Name)
	}
	w.u8(0)
	for _, s := range l.Shards {
		w.u8(1)
		w.u16(s.ID)
		w.str(s.Name)
		w.u16(s.Current)
		w.u16(s.Capacity)
		w.u8(s.State)
		if farmByte {
			w.u8(s.Farm)
		}
	}
	w.u8(0)
	return w.b
}

// DecodeShardList reads a 0xA101 payload strictly (OURS: the client stops a
// loop at any byte other than 1; here a terminator must be 0, the payload
// must end exactly after the last one, and the counts are capped).
func DecodeShardList(p []byte, farmByte bool) (ShardList, error) {
	var l ShardList
	r := &reader{p: p}
	fail := func(what string, err error) (ShardList, error) {
		return ShardList{}, fmt.Errorf("0xA101 %s: %w", what, err)
	}
	for {
		flag, err := r.u8()
		if err != nil {
			return fail("farm flag", err)
		}
		if flag == 0 {
			break
		}
		if flag != 1 {
			return fail("farm flag", fmt.Errorf("is %d, not 0 or 1", flag))
		}
		if len(l.Farms) >= MaxFarms {
			return fail("farms", fmt.Errorf("more than %d", MaxFarms))
		}
		var f Farm
		if f.ID, err = r.u8(); err != nil {
			return fail("farm id", err)
		}
		if f.Name, err = r.str(); err != nil {
			return fail("farm name", err)
		}
		l.Farms = append(l.Farms, f)
	}
	for {
		flag, err := r.u8()
		if err != nil {
			return fail("shard flag", err)
		}
		if flag == 0 {
			break
		}
		if flag != 1 {
			return fail("shard flag", fmt.Errorf("is %d, not 0 or 1", flag))
		}
		if len(l.Shards) >= MaxShards {
			return fail("shards", fmt.Errorf("more than %d", MaxShards))
		}
		var s Shard
		if s.ID, err = r.u16(); err != nil {
			return fail("shard id", err)
		}
		if s.Name, err = r.str(); err != nil {
			return fail("shard name", err)
		}
		if s.Current, err = r.u16(); err != nil {
			return fail("shard current", err)
		}
		if s.Capacity, err = r.u16(); err != nil {
			return fail("shard capacity", err)
		}
		if s.State, err = r.u8(); err != nil {
			return fail("shard state", err)
		}
		if farmByte {
			if s.Farm, err = r.u8(); err != nil {
				return fail("shard farm", err)
			}
		}
		l.Shards = append(l.Shards, s)
	}
	if !r.done() {
		return fail("end", fmt.Errorf("%d bytes after the last terminator", len(p)-r.off))
	}
	return l, nil
}

// DecodeShardListFor reads a 0xA101 with the layout FarmByteFor gives the
// content id, and failing that the other one (OURS: which layout the CLIENT
// reads is set by a word whose writer is OPEN, so the server's rule is tried
// first and the other kept as a fallback).
func DecodeShardListFor(p []byte, contentID byte) (ShardList, bool, error) {
	first := FarmByteFor(contentID)
	l, err := DecodeShardList(p, first)
	if err == nil {
		return l, first, nil
	}
	l2, err2 := DecodeShardList(p, !first)
	if err2 == nil {
		return l2, !first, nil
	}
	return ShardList{}, first, err
}

// ServerHello is a gateway's 0x5000 (READ: the server sender
// CNetEngine::FUN_00965c20 in SR_GameServer, and the client reader
// ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake 0x4b1da0):
//
//	u8 flags
//	flags&2:  u8[8] Blowfish key
//	flags&4:  u32 count seed, u32 crc seed
//	flags&16: u8[8] challenge (the second 0x5000)
//	else flags&8: u8[8] handshake key, u32 G, u32 P, u32 A
type ServerHello struct {
	Flags        byte
	BlowfishKey  [8]byte
	CountSeed    uint32
	CRCSeed      uint32
	HandshakeKey [8]byte
	G, P, A      uint32
	Challenge    [8]byte
}

// Encode writes the hello's payload.
func (h ServerHello) Encode() []byte {
	var w writer
	w.u8(h.Flags)
	if h.Flags&0x02 != 0 {
		w.b = append(w.b, h.BlowfishKey[:]...)
	}
	if h.Flags&0x04 != 0 {
		w.u32(h.CountSeed)
		w.u32(h.CRCSeed)
	}
	if h.Flags&0x10 != 0 {
		w.b = append(w.b, h.Challenge[:]...)
	} else if h.Flags&0x08 != 0 {
		w.b = append(w.b, h.HandshakeKey[:]...)
		w.u32(h.G)
		w.u32(h.P)
		w.u32(h.A)
	}
	return w.b
}

// DecodeServerHello reads a 0x5000 strictly: the fields its flags name and
// nothing after them (OURS: the client does not look past them).
func DecodeServerHello(p []byte) (ServerHello, error) {
	var h ServerHello
	r := &reader{p: p}
	var err error
	if h.Flags, err = r.u8(); err != nil {
		return h, fmt.Errorf("0x5000 flags: %w", err)
	}
	if h.Flags&0x02 != 0 {
		b, err := r.bytes(8)
		if err != nil {
			return h, fmt.Errorf("0x5000 Blowfish key: %w", err)
		}
		copy(h.BlowfishKey[:], b)
	}
	if h.Flags&0x04 != 0 {
		if h.CountSeed, err = r.u32(); err != nil {
			return h, fmt.Errorf("0x5000 count seed: %w", err)
		}
		if h.CRCSeed, err = r.u32(); err != nil {
			return h, fmt.Errorf("0x5000 crc seed: %w", err)
		}
	}
	if h.Flags&0x10 != 0 {
		b, err := r.bytes(8)
		if err != nil {
			return h, fmt.Errorf("0x5000 challenge: %w", err)
		}
		copy(h.Challenge[:], b)
	} else if h.Flags&0x08 != 0 {
		b, err := r.bytes(8)
		if err != nil {
			return h, fmt.Errorf("0x5000 handshake key: %w", err)
		}
		copy(h.HandshakeKey[:], b)
		for _, f := range []*uint32{&h.G, &h.P, &h.A} {
			if *f, err = r.u32(); err != nil {
				return h, fmt.Errorf("0x5000 key exchange: %w", err)
			}
		}
	}
	if !r.done() {
		return h, fmt.Errorf("0x5000 (flags 0x%02x): %d bytes after its fields", h.Flags, len(p)-r.off)
	}
	return h, nil
}

// EncodeIdentity is a 0x2001 payload: the module name and a byte (READ: the
// client sends ClientModule and 0, CClientProcess::vslot_010 0x4ce8c0, and
// reads a string and a byte, vslot_014 0x4ce9d0).
func EncodeIdentity(name string, b byte) []byte {
	var w writer
	w.str(name)
	w.u8(b)
	return w.b
}

// DecodeIdentity reads a 0x2001 payload strictly.
func DecodeIdentity(p []byte) (string, byte, error) {
	r := &reader{p: p}
	name, err := r.str()
	if err != nil {
		return "", 0, fmt.Errorf("0x2001 name: %w", err)
	}
	b, err := r.u8()
	if err != nil {
		return "", 0, fmt.Errorf("0x2001 byte: %w", err)
	}
	if !r.done() {
		return "", 0, fmt.Errorf("0x2001: %d bytes after its fields", len(p)-r.off)
	}
	return name, b, nil
}

// EncodePatchRequest is a 0x6100 payload (READ, 0x4cea72..0x4ceaba: the
// content id byte, ClientModule, the u32 version).
func EncodePatchRequest(contentID byte, version uint32) []byte {
	var w writer
	w.u8(contentID)
	w.str(ClientModule)
	w.u32(version)
	return w.b
}

// DecodePatchRequest reads a 0x6100 (the fake gateway's side; READ,
// GatewayServer 0x4051a0 reads the same three fields and drops a client whose
// message is short).
func DecodePatchRequest(p []byte) (contentID byte, module string, version uint32, err error) {
	r := &reader{p: p}
	if contentID, err = r.u8(); err != nil {
		return
	}
	if module, err = r.str(); err != nil {
		return
	}
	version, err = r.u32()
	return
}

// MassiveParts splits a message into 0x600D payloads (READ, GatewayServer
// 0x41f7d0 and 0x41f900): a header [u8 1, u16 part count, u16 opcode], then
// each part [u8 0, data]. partSize is the data per part (OURS for the fake).
func MassiveParts(op uint16, data []byte, partSize int) [][]byte {
	if partSize <= 0 {
		partSize = len(data)
	}
	var parts [][]byte
	for off := 0; off < len(data) || (off == 0 && len(parts) == 0); off += partSize {
		end := min(off+partSize, len(data))
		parts = append(parts, append([]byte{0}, data[off:end]...))
		if end == len(data) {
			break
		}
	}
	var w writer
	w.u8(1)
	w.u16(uint16(len(parts)))
	w.u16(op)
	return append([][]byte{w.b}, parts...)
}

// Massive reassembles 0x600D messages (OURS limits: MaxMassiveParts,
// MaxMassiveSize).
type Massive struct {
	op    uint16
	left  int
	data  []byte
	ready bool
}

// Feed takes one 0x600D payload; done reports a whole message in op/data.
func (m *Massive) Feed(p []byte) (op uint16, data []byte, done bool, err error) {
	r := &reader{p: p}
	kind, err := r.u8()
	if err != nil {
		return 0, nil, false, fmt.Errorf("0x600D: empty")
	}
	switch kind {
	case 1:
		if m.ready {
			return 0, nil, false, fmt.Errorf("0x600D: a second header before the first message ended")
		}
		n, err1 := r.u16()
		o, err2 := r.u16()
		if err1 != nil || err2 != nil || !r.done() {
			return 0, nil, false, fmt.Errorf("0x600D header: not u8 1, u16 count, u16 opcode")
		}
		if n == 0 || int(n) > MaxMassiveParts {
			return 0, nil, false, fmt.Errorf("0x600D header: %d parts (1-%d)", n, MaxMassiveParts)
		}
		m.op, m.left, m.data, m.ready = o, int(n), nil, true
		return 0, nil, false, nil
	case 0:
		if !m.ready {
			return 0, nil, false, fmt.Errorf("0x600D: a part before its header")
		}
		if len(m.data)+len(p)-1 > MaxMassiveSize {
			return 0, nil, false, fmt.Errorf("0x600D: over %d bytes", MaxMassiveSize)
		}
		m.data = append(m.data, p[1:]...)
		m.left--
		if m.left == 0 {
			m.ready = false
			return m.op, m.data, true, nil
		}
		return 0, nil, false, nil
	}
	return 0, nil, false, fmt.Errorf("0x600D: kind %d, not 0 or 1", kind)
}
