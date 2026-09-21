package proto

import (
	"bytes"
	"math"
	"testing"
)

// The angle scale, checked against the two anchors the binaries' own constants
// fix rather than against this package's output.
//
// The full-turn anchor is the point of the test: the engine's constant is
// 65535, NOT 65536, so a full turn encodes to 0xffff and does NOT wrap to 0. A
// reimplementation that reached for the "obvious" 65536 would pass every other
// case here and fail this one.
func TestEncodeMovementAngle(t *testing.T) {
	cases := []struct {
		name string
		rad  float64
		want uint16
	}{
		{"zero", 0, 0},
		{"quarter turn", math.Pi / 2, 16384},
		{"half turn", math.Pi, 32768},
		{"three quarter turn", 3 * math.Pi / 2, 49151},
		{"full turn", 2 * math.Pi, 65535},
	}
	for _, c := range cases {
		if got := EncodeMovementAngle(c.rad); got != c.want {
			t.Errorf("%s: EncodeMovementAngle(%v) = %d, want %d", c.name, c.rad, got, c.want)
		}
	}
}

// The constant is the float32 of 180/pi, not 180/pi. Pinned because the
// difference is invisible until it is compared against the original: a
// full-precision 180/pi shifts the encoded angle, and this is the one place
// that records which of the two the engine uses.
func TestMovementAngleConstantIsFloat32Widened(t *testing.T) {
	if want := float64(float32(180 / math.Pi)); movementDegreesPerRadian != want {
		t.Errorf("movementDegreesPerRadian = %.17g, want float64(float32(180/pi)) = %.17g",
			movementDegreesPerRadian, want)
	}
	if movementDegreesPerRadian == 180/math.Pi {
		t.Error("movementDegreesPerRadian is full-precision 180/pi; the binaries hold the float32 of it")
	}
}

// Byte-for-byte against the layout table in docs/protocol/opcodes/movement.md.
// These are hand-written from the spec, not captured from Encode's output.
func TestMovementEncodeLayout(t *testing.T) {
	cases := []struct {
		name string
		m    Movement
		want []byte
	}{
		{
			// kind 0 selects the heading form: the +0x14 byte, then the
			// angle. A quarter turn is 16384 = 0x4000.
			name: "heading",
			m:    Movement{Kind: MovementKindHeading, HeadingByte: 0x07, AngleRadians: math.Pi / 2},
			want: []byte{0x00, 0x07, 0x00, 0x40},
		},
		{
			// The optional second byte sits between the kind and the rest.
			name: "heading with the optional extra byte",
			m: Movement{Kind: MovementKindHeading, Extra: 0x2a, HasExtra: true,
				HeadingByte: 0x07, AngleRadians: math.Pi / 2},
			want: []byte{0x00, 0x2a, 0x07, 0x00, 0x40},
		},
		{
			// A region WITHOUT the world bit carries three uint16s.
			name: "destination, region-local",
			m: Movement{Kind: 1, Region: 0x6100,
				LocalX: 100, LocalY: 200, LocalZ: 300},
			want: []byte{0x01, 0x00, 0x61, 100, 0, 200, 0, 0x2c, 0x01},
		},
		{
			// A region WITH the world bit carries three float32s. 1.0 is
			// 0x3f800000, 2.0 is 0x40000000, -1.0 is 0xbf800000.
			name: "destination, world coordinates",
			m: Movement{Kind: 1, Region: MovementRegionWorldBit | 0x0100,
				X: 1, Y: 2, Z: -1},
			want: []byte{0x01, 0x00, 0x81,
				0x00, 0x00, 0x80, 0x3f,
				0x00, 0x00, 0x00, 0x40,
				0x00, 0x00, 0x80, 0xbf},
		},
	}
	for _, c := range cases {
		if got := c.m.Encode(); !bytes.Equal(got, c.want) {
			t.Errorf("%s: Encode() = % x, want % x", c.name, got, c.want)
		}
	}
}

func TestMovementRoundTrip(t *testing.T) {
	cases := []struct {
		name     string
		m        Movement
		hasExtra bool
	}{
		{"heading", Movement{Kind: MovementKindHeading, HeadingByte: 9}, false},
		{"heading with extra", Movement{Kind: MovementKindHeading, Extra: 3, HasExtra: true, HeadingByte: 9}, true},
		{"region-local", Movement{Kind: 1, Region: 0x6100, LocalX: 1, LocalY: 2, LocalZ: 3}, false},
		{"world", Movement{Kind: 1, Region: MovementRegionWorldBit, X: 1.5, Y: -2.5, Z: 3.5}, false},
	}
	for _, c := range cases {
		got, _, err := DecodeMovement(c.m.Encode(), c.hasExtra)
		if err != nil {
			t.Errorf("%s: DecodeMovement: %v", c.name, err)
			continue
		}
		// AngleRadians is deliberately not round-tripped -- the wire
		// carries the encoded 16-bit angle and DecodeMovement refuses to
		// invent back the radians. Compare everything else.
		want := c.m
		want.AngleRadians = 0
		if *got != want {
			t.Errorf("%s: round trip = %+v, want %+v", c.name, *got, want)
		}
	}
}

// The heading form's angle survives the wire even though the radians do not.
func TestMovementDecodeReturnsEncodedAngle(t *testing.T) {
	m := Movement{Kind: MovementKindHeading, HeadingByte: 1, AngleRadians: math.Pi}
	_, angle, err := DecodeMovement(m.Encode(), false)
	if err != nil {
		t.Fatalf("DecodeMovement: %v", err)
	}
	if angle != 32768 {
		t.Errorf("decoded angle = %d, want 32768", angle)
	}
}

func TestMovementDecodeTruncated(t *testing.T) {
	full := (&Movement{Kind: 1, Region: MovementRegionWorldBit, X: 1, Y: 2, Z: 3}).Encode()
	for n := 0; n < len(full); n++ {
		if _, _, err := DecodeMovement(full[:n], false); err != ErrShortMovement {
			t.Errorf("DecodeMovement(%d of %d bytes) err = %v, want ErrShortMovement", n, len(full), err)
		}
	}
	if _, _, err := DecodeMovement(full, false); err != nil {
		t.Errorf("DecodeMovement(full) err = %v, want nil", err)
	}
}
