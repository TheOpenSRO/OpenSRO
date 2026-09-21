package proto

import (
	"encoding/binary"
	"errors"
	"math"
)

// The 0x7021 movement payload, specified in docs/protocol/opcodes/movement.md.
//
// This is the first REAL payload layout encoded in this package -- opcodes.go's
// header note ("payload layouts are documented in login.md, not encoded here
// yet") describes the state before it. It is the request a client sends to move
// a player AND the message the original server's own monster AI composes to
// move a monster: one path, not two, so implementing it implements both.
//
// Recovered from both binaries (round 364). The server's serialiser at
// 0x0048bad0 appends through a helper whose argument type the decompiler drops,
// so the FIELD WIDTHS below come from the client's twin at 0x009ebbf0, whose
// append helper takes an explicit byte count.

// MovementKindHeading is the kind byte selecting the heading form: no
// destination, just a direction to walk in. Any other value selects the
// destination form. 0xff trips the original server's own assert.
const MovementKindHeading byte = 0

// MovementRegionWorldBit is the bit in the region word that says the three
// coordinates are float32 world/dungeon coordinates rather than region-local
// uint16s. Same encoding this project recovered for positions elsewhere:
// region span 1920, local coordinates [0, 1920).
const MovementRegionWorldBit uint16 = 0x8000

// The angle scale, read as IEEE doubles out of both PE images and
// byte-identical between them (server .rdata 0x00b45c38/0x00b45c30/0x00b45c28,
// client 0x00dde8f0/0x00dde7a8/0x00dde7b0).
//
// movementDegreesPerRadian is NOT 180/pi (57.295779513082320). It is the
// float32 of 180/pi widened to double, which is what both binaries store, so
// the engine's degree conversion carries float32 precision. Using a
// full-precision 180/pi here would disagree with the original in the low bits
// of the encoded angle.
const (
	movementDegreesPerRadian = 57.295780181884766
	movementDegreesPerTurn   = 360.0
	movementAngleFullTurn    = 65535.0
)

// EncodeMovementAngle converts a heading in radians to the engine's 16-bit
// angle: round(radians * 57.295780181884766 / 360 * 65535).
//
// A FULL TURN MAPS TO 65535, not 65536 -- that is the constant the binaries
// hold, not a simplification of one.
//
// NOT READ, so not reproduced bit-for-bit: the original computes this on the
// x87 stack and the width of its intermediates (and therefore its exact
// rounding at a tie) is not recovered. This rounds half away from zero in
// float64. Expect agreement to within a unit of the encoded angle, not
// necessarily to the bit.
//
// Whether the engine ever passes a negative heading is likewise not read. A
// negative result truncates modulo 2^16, matching what the original's
// unsigned conversion does on x86.
func EncodeMovementAngle(radians float64) uint16 {
	turns := radians * movementDegreesPerRadian / movementDegreesPerTurn
	return uint16(uint32(int64(math.Round(turns * movementAngleFullTurn))))
}

// Movement is one decoded 0x7021 payload.
type Movement struct {
	// Kind selects the form: MovementKindHeading, or anything else for a
	// destination.
	Kind byte

	// Extra is the optional second byte. The caller of the original
	// serialiser decides whether it is present; the monster AI passes zero
	// and so never emits it. WHAT IT CARRIES IS NOT READ.
	Extra    byte
	HasExtra bool

	// HeadingByte is the one-byte field at the record's +0x14, emitted
	// before the angle in the heading form. Its WIDTH is settled; its
	// MEANING is not read, which is why it has no better name.
	HeadingByte byte
	// AngleRadians is the heading. Encoded through EncodeMovementAngle.
	AngleRadians float64

	// Region is the destination's region word. Its MovementRegionWorldBit
	// decides which of the two coordinate triples below is on the wire.
	Region uint16
	// X, Y, Z are world/dungeon coordinates, used when Region has
	// MovementRegionWorldBit set.
	X, Y, Z float32
	// LocalX, LocalY, LocalZ are region-local coordinates, used otherwise.
	LocalX, LocalY, LocalZ uint16
}

// ErrShortMovement is returned when a payload ends before a field it promised.
var ErrShortMovement = errors.New("proto: truncated 0x7021 movement payload")

// Encode renders the payload exactly as the original serialiser does.
func (m *Movement) Encode() []byte {
	out := []byte{m.Kind}
	if m.HasExtra {
		out = append(out, m.Extra)
	}
	if m.Kind == MovementKindHeading {
		out = append(out, m.HeadingByte)
		return binary.LittleEndian.AppendUint16(out, EncodeMovementAngle(m.AngleRadians))
	}
	out = binary.LittleEndian.AppendUint16(out, m.Region)
	if m.Region&MovementRegionWorldBit != 0 {
		for _, f := range [3]float32{m.X, m.Y, m.Z} {
			out = binary.LittleEndian.AppendUint32(out, math.Float32bits(f))
		}
		return out
	}
	for _, v := range [3]uint16{m.LocalX, m.LocalY, m.LocalZ} {
		out = binary.LittleEndian.AppendUint16(out, v)
	}
	return out
}

// DecodeMovement parses a 0x7021 payload. hasExtra says whether the optional
// second byte is present, because NOTHING IN THE PAYLOAD ITSELF SAYS SO -- the
// original decides it at the call site, so a decoder has to be told.
//
// AngleRadians is left zero: the wire carries the encoded 16-bit angle, and
// converting back would invent precision the sender did not send. Callers that
// want the raw value read it from the returned angle.
func DecodeMovement(b []byte, hasExtra bool) (m *Movement, angle uint16, err error) {
	if len(b) < 1 {
		return nil, 0, ErrShortMovement
	}
	m = &Movement{Kind: b[0]}
	b = b[1:]
	if hasExtra {
		if len(b) < 1 {
			return nil, 0, ErrShortMovement
		}
		m.Extra, m.HasExtra = b[0], true
		b = b[1:]
	}
	if m.Kind == MovementKindHeading {
		if len(b) < 3 {
			return nil, 0, ErrShortMovement
		}
		m.HeadingByte = b[0]
		return m, binary.LittleEndian.Uint16(b[1:3]), nil
	}
	if len(b) < 2 {
		return nil, 0, ErrShortMovement
	}
	m.Region = binary.LittleEndian.Uint16(b[0:2])
	b = b[2:]
	if m.Region&MovementRegionWorldBit != 0 {
		if len(b) < 12 {
			return nil, 0, ErrShortMovement
		}
		m.X = math.Float32frombits(binary.LittleEndian.Uint32(b[0:4]))
		m.Y = math.Float32frombits(binary.LittleEndian.Uint32(b[4:8]))
		m.Z = math.Float32frombits(binary.LittleEndian.Uint32(b[8:12]))
		return m, 0, nil
	}
	if len(b) < 6 {
		return nil, 0, ErrShortMovement
	}
	m.LocalX = binary.LittleEndian.Uint16(b[0:2])
	m.LocalY = binary.LittleEndian.Uint16(b[2:4])
	m.LocalZ = binary.LittleEndian.Uint16(b[4:6])
	return m, 0, nil
}
