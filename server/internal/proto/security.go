package proto

// RollingByte is the per-session rolling one-byte generator described in
// docs/protocol/opcodes/handshake.md: seeded once at handshake time from key
// material, then advanced by one step for each packet sent on the session.
// It is independent of that packet's actual contents — it's a keystream-like
// counter, not a checksum.
//
// This does not (yet) implement the separate multi-table CRC-32-style byte
// also described in that doc — see its Status section for why.
type RollingByte struct {
	state [3]byte // seeded at handshake time; state[0] advances each call
}

// NewRollingByte constructs a RollingByte from its three seed bytes, as
// derived during the handshake key exchange (not yet implemented here — see
// the doc's Encryption section).
func NewRollingByte(seed0, seed1, seed2 byte) *RollingByte {
	return &RollingByte{state: [3]byte{seed0, seed1, seed2}}
}

// Next returns this session's next security byte and advances the internal
// state by one step.
func (r *RollingByte) Next() byte {
	b := (^r.state[0] + r.state[1]) * r.state[2]
	b = (b >> 4) ^ b
	r.state[0] = b
	return b
}

// lfsrByte runs a 32-bit linear feedback shift register 32 rounds forward
// from seed and returns the low byte of the result. Each round: compute a
// feedback bit by XOR-ing five tapped, progressively-shifted versions of the
// register together (shift amounts 2, 2, 1, 1, 1, each XORed against the
// register's current value); old bit 0 moves to the new bit 31 (a rotate),
// and the new bit 0 becomes the feedback bit. See
// docs/protocol/opcodes/handshake.md for why this specific tap arrangement
// is documented as a fact rather than guessed at.
func lfsrByte(seed uint32) byte {
	v := seed
	for range 32 {
		tap := (v >> 2) ^ v
		tap = (tap >> 2) ^ v
		tap = (tap >> 1) ^ v
		tap = (tap >> 1) ^ v
		tap = (tap >> 1) ^ v
		feedback := tap & 1

		oldBit0 := (v & 1) << 31
		v = ((v >> 1) &^ 1) | oldBit0 | feedback
	}
	return byte(v)
}

// DeriveSeed expands a 32-bit session seed into the three seed bytes
// RollingByte needs, matching the handshake key-derivation behavior in
// docs/protocol/opcodes/handshake.md: four LFSR-derived bytes (from the
// seed and three simple variations of it) get XORed pairwise, substituting
// 1 for a 0 result to avoid a degenerate all-zero state.
func DeriveSeed(seed uint32) (b0, b1, b2 byte) {
	a := lfsrByte(seed)
	b := lfsrByte(seed + 1)
	c := lfsrByte(seed + 2)
	d := lfsrByte(seed + 3)

	x := a ^ b
	y := c ^ d
	if x == 0 {
		x = 1
	}
	if y == 0 {
		y = 1
	}
	return x ^ y, x, y
}

// PacketChecksum is a from-scratch, originally-designed stand-in for the
// second security field docs/protocol/opcodes/handshake.md describes: a
// reflected CRC-32-style running checksum, folded to one byte, selected from
// one of several per-session tables by a small index. The real client's
// actual table contents were deliberately never pulled from the binary (see
// the doc's point 3 and docs/LEGAL.md policy #2 -- that would be copying
// literal proprietary data, not documenting a fact about behavior), so this
// generates its own table family with the same shape and purpose instead of
// reproducing the original bit-for-bit. Like RollingByte/DeriveSeed, this
// is a reference implementation only -- see docs/protocol/PROTOCOL_DECISION.md:
// this project's real client<->server link doesn't use either.
type PacketChecksum struct {
	table [256]uint32
	acc   uint32
}

// NewPacketChecksum builds one session's checksum state, deriving its table
// from tableIndex (1-255; see checksumTable for why 0 isn't special-cased
// away, it just yields the same table as any other index).
func NewPacketChecksum(tableIndex byte) *PacketChecksum {
	return &PacketChecksum{table: checksumTable(tableIndex), acc: 0xFFFFFFFF}
}

// checksumTable derives one of this design's 256 candidate tables from
// index: a standard reflected-CRC table-generation loop (8 rounds per byte,
// shifting right and conditionally XORing in the polynomial), but over a
// polynomial folded with index rather than the fixed, well-known CRC-32
// polynomial -- so each index yields a distinct, deterministic table without
// needing 256 literal tables stored anywhere.
func checksumTable(index byte) [256]uint32 {
	const basePoly uint32 = 0xedb88320
	poly := basePoly ^ (uint32(index) * 0x01000193)

	var table [256]uint32
	for i := range 256 {
		v := uint32(i)
		for range 8 {
			if v&1 != 0 {
				v = (v >> 1) ^ poly
			} else {
				v >>= 1
			}
		}
		table[i] = v
	}
	return table
}

// Update feeds one more payload byte through the running checksum.
func (c *PacketChecksum) Update(b byte) {
	c.acc = (c.acc >> 8) ^ c.table[byte(c.acc)^b]
}

// Byte folds the current 32-bit accumulator down to the single header byte
// this design carries: plain 8-bit addition (no carry) of the accumulator's
// four constituent bytes, matching the real protocol's fold step.
func (c *PacketChecksum) Byte() byte {
	return byte(c.acc) + byte(c.acc>>8) + byte(c.acc>>16) + byte(c.acc>>24)
}
