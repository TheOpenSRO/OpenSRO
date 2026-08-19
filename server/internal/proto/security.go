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
