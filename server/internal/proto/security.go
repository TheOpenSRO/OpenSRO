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
