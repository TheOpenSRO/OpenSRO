package proto

// The original gateway protocol's per-connection security, as READ from the
// retail client's network engine (round 681; docs/protocol/opcodes/handshake.md,
// "The client's side, READ"). Every function here is an independent
// implementation of a behaviour described in that doc; no table, key or code
// bytes were copied from any binary (docs/LEGAL.md policy #2).

import (
	"encoding/binary"
	"hash/crc32"
	"sort"

	"golang.org/x/crypto/blowfish"
)

// DefaultCountSeed replaces a count seed of 0 (READ, sro_client 0x4b0cf7:
// `mov eax,0x9abfb3b6` when the handshake's count seed is zero).
const DefaultCountSeed uint32 = 0x9abfb3b6

// lfsr32 runs the 32-round generator of handshake.md point 1 and returns the
// whole register (READ, sro_client 0x4afb80: the state is updated in place,
// so successive calls chain).
func lfsr32(v uint32) uint32 {
	for range 32 {
		tap := (v >> 2) ^ v
		tap = (tap >> 2) ^ v
		tap = (tap >> 1) ^ v
		tap = (tap >> 1) ^ v
		tap = (tap >> 1) ^ v
		v = ((v>>1)|(v<<31))&^1 | tap&1
	}
	return v
}

// CountSeeds expands a handshake count seed into the rolling byte's three
// state bytes (READ, sro_client 0x4b0cc0..0x4b0d51): four chained generator
// runs v1..v4 from the seed; a = low(v1) ^ low(v2), b = low(v4) ^ low(v3),
// each 0 -> 1; state = {a ^ b, a, b}. A seed of 0 is DefaultCountSeed.
func CountSeeds(seed uint32) [3]byte {
	if seed == 0 {
		seed = DefaultCountSeed
	}
	v1 := lfsr32(seed)
	v2 := lfsr32(v1)
	v3 := lfsr32(v2)
	v4 := lfsr32(v3)
	a := byte(v1) ^ byte(v2)
	b := byte(v4) ^ byte(v3)
	if a == 0 {
		a = 1
	}
	if b == 0 {
		b = 1
	}
	return [3]byte{a ^ b, a, b}
}

// CRCIndex is the checksum table a handshake's crc seed selects (READ,
// sro_client 0x4bf9c0): its low byte, 0 -> 1.
func CRCIndex(crcSeed uint32) byte {
	i := byte(crcSeed)
	if i == 0 {
		i = 1
	}
	return i
}

// unknownCRCIndices are the table indices whose polynomial is NOT the
// standard CRC-32 table's entry at that index. MEASURED (round 681): the
// 256-polynomial list the client's table builder (sro_client 0x4bf900, from
// 0xee44a0) reads, compared on the render box with the CRC-32 table computed
// from the public polynomial 0xedb88320: 218 of the 255 usable entries are
// equal, these 37 differ (and entry 0, never used: CRCIndex maps 0 to 1).
// GatewayServer.exe and SR_GameServer.exe hold the identical list. Their
// values were not taken: a session whose index is one of these cannot be
// checksummed here, and the caller reconnects for another index.
var unknownCRCIndices = []byte{
	18, 19, 55, 58, 73, 88, 121, 123, 125, 145, 175, 176, 177, 182, 184, 192, 193, 198, 199,
	200, 208, 216, 217, 240, 241, 242, 243, 244, 245, 246, 248, 250, 251, 252, 253, 254, 255,
}

// CRCIndexKnown reports whether the checksum table at index can be built
// (index 1..255; see unknownCRCIndices).
func CRCIndexKnown(index byte) bool {
	if index == 0 {
		return false
	}
	i := sort.Search(len(unknownCRCIndices), func(k int) bool { return unknownCRCIndices[k] >= index })
	return i == len(unknownCRCIndices) || unknownCRCIndices[i] != index
}

// crcPolynomial is the polynomial of table index (READ: the builder reads
// the index'th u32 of its list), for a known index: the standard reflected
// CRC-32 table's entry at that index (MEASURED equal, above).
func crcPolynomial(index byte) uint32 {
	return crc32.IEEETable[index]
}

// CRCTable builds checksum table index (READ, sro_client 0x4bf900: for each
// i, v = i, then eight reflected steps v = v&1 ? v>>1 ^ poly : v>>1 -- the
// textbook reflected-CRC table for that polynomial). ok is false for an
// index whose polynomial is unknown.
func CRCTable(index byte) (t *[256]uint32, ok bool) {
	if !CRCIndexKnown(index) {
		return nil, false
	}
	poly := crcPolynomial(index)
	var tab [256]uint32
	for i := range 256 {
		v := uint32(i)
		for range 8 {
			if v&1 != 0 {
				v = v>>1 ^ poly
			} else {
				v >>= 1
			}
		}
		tab[i] = v
	}
	return &tab, true
}

// CheckByte is a frame's checksum byte (READ, sro_client 0x4bf9e0): the
// accumulator starts at 0xffffffff for each frame, takes every byte as
// acc = acc>>8 ^ table[(b ^ acc) & 0xff], and is folded to one byte by
// adding its four bytes (no final XOR). frame is the whole frame -- the
// 6-byte header with the checksum byte zero, then the payload.
func CheckByte(t *[256]uint32, frame []byte) byte {
	acc := uint32(0xffffffff)
	for _, b := range frame {
		acc = acc>>8 ^ t[byte(acc)^b]
	}
	return byte(acc) + byte(acc>>8) + byte(acc>>16) + byte(acc>>24)
}

// NextCountByte advances the rolling byte (handshake.md point 2; READ again
// at sro_client 0x4b1eb6) and returns it.
func NextCountByte(state *[3]byte) byte {
	b := (^state[0] + state[1]) * state[2]
	b = b>>4 ^ b
	state[0] = b
	return b
}

// KeyTransform is the handshake's key mixing (READ, sro_client 0x4c4230):
// byte i of v becomes v[i] ^ (v[i] + key byte (i % 4) + keyByte), the key's
// bytes little-endian.
func KeyTransform(v [8]byte, key uint32, keyByte byte) [8]byte {
	var k [4]byte
	binary.LittleEndian.PutUint32(k[:], key)
	for i := range 8 {
		v[i] ^= v[i] + k[i%4] + keyByte
	}
	return v
}

// ModPow is base^exp mod m in 64-bit arithmetic (READ, sro_client 0x4c6e50:
// square-and-multiply with __allmul/__aullrem; exp 0 gives 1). m must not be
// 0 (the client would divide by zero; callers refuse such a handshake).
func ModPow(base, exp, m uint32) uint32 {
	result := uint64(1)
	b := uint64(base)
	mod := uint64(m)
	if exp == 0 {
		return 1
	}
	for exp != 0 {
		if exp&1 != 0 {
			result = result * b % mod
		}
		exp >>= 1
		b = b * b % mod
	}
	return uint32(result)
}

// Pair packs two u32s little-endian into 8 bytes, the layout the handshake
// mixes and encrypts (READ: the values are stored to consecutive dwords).
func Pair(lo, hi uint32) [8]byte {
	var v [8]byte
	binary.LittleEndian.PutUint32(v[0:], lo)
	binary.LittleEndian.PutUint32(v[4:], hi)
	return v
}

// RetailCipher is the session's Blowfish: the standard cipher (its P-array
// and S-boxes MEASURED in the client equal to the published pi digits, and
// the key schedule READ at sro_client 0x4aa4c0 to take key bytes
// big-endian), applied to 8-byte blocks whose two halves are loaded as
// LITTLE-endian u32s (READ, 0x4a9d40 takes *(u32*)block and *(u32*)(block+4)).
type RetailCipher struct {
	c *blowfish.Cipher
}

// NewRetailCipher keys the cipher (the handshake's keys are 8 bytes).
func NewRetailCipher(key []byte) (*RetailCipher, error) {
	c, err := blowfish.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return &RetailCipher{c: c}, nil
}

func swapHalves(b []byte) {
	b[0], b[1], b[2], b[3] = b[3], b[2], b[1], b[0]
	b[4], b[5], b[6], b[7] = b[7], b[6], b[5], b[4]
}

// EncryptBlock encrypts one 8-byte block in place.
func (r *RetailCipher) EncryptBlock(b []byte) {
	swapHalves(b[:8])
	r.c.Encrypt(b[:8], b[:8])
	swapHalves(b[:8])
}

// DecryptBlock decrypts one 8-byte block in place.
func (r *RetailCipher) DecryptBlock(b []byte) {
	swapHalves(b[:8])
	r.c.Decrypt(b[:8], b[:8])
	swapHalves(b[:8])
}

// PaddedLen rounds n up to whole 8-byte blocks (READ: the client's encrypt
// zero-pads the last block, 0x4aa8d0).
func PaddedLen(n int) int { return (n + 7) &^ 7 }

// Encrypt returns data zero-padded to whole blocks and encrypted.
func (r *RetailCipher) Encrypt(data []byte) []byte {
	out := make([]byte, PaddedLen(len(data)))
	copy(out, data)
	for i := 0; i < len(out); i += 8 {
		r.EncryptBlock(out[i : i+8])
	}
	return out
}

// Decrypt decrypts whole blocks (len(data) % 8 == 0) into a new slice.
func (r *RetailCipher) Decrypt(data []byte) []byte {
	out := append([]byte(nil), data...)
	for i := 0; i+8 <= len(out); i += 8 {
		r.DecryptBlock(out[i : i+8])
	}
	return out
}
