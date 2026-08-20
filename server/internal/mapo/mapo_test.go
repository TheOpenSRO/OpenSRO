package mapo

import (
	"encoding/binary"
	"math"
	"testing"
)

func appendU32(b []byte, v uint32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], v)
	return append(b, tmp[:]...)
}

func appendFloat32(b []byte, v float32) []byte {
	return appendU32(b, math.Float32bits(v))
}

// buildSyntheticRegion writes a minimal, synthetic .o-shaped buffer (never
// real game data) matching the layout confirmed against 2 real files: see
// docs/protocol/MAPO_FORMAT.md.
func buildSyntheticRegion(t *testing.T) []byte {
	t.Helper()

	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, []byte("1001")...)
	buf = appendU32(buf, 0) // unconfirmed header field
	buf = appendU32(buf, 0) // unconfirmed header field

	// Object 1: no trailing bytes beyond the fixed 28, immediately
	// followed by object 2.
	buf = appendU32(buf, 1805)
	buf = appendFloat32(buf, 287.14)
	buf = appendFloat32(buf, 219.43)
	buf = appendFloat32(buf, 157.65)
	buf = append(buf, make([]byte, 12)...) // unconfirmed fixed 12 bytes

	// Object 2: a real trailing block (zero padding + a small nonzero
	// tail value, matching the shape seen in every real file checked)
	// before object 3 starts.
	buf = appendU32(buf, 1159)
	buf = appendFloat32(buf, 414.19)
	buf = appendFloat32(buf, 183.37)
	buf = appendFloat32(buf, 318.94)
	buf = append(buf, make([]byte, 12)...) // unconfirmed fixed 12 bytes
	buf = append(buf, 0, 0, 0, 0, 3, 0)    // trailing block

	// Object 3: the last object, no trailer, end of file right after.
	buf = appendU32(buf, 1798)
	buf = appendFloat32(buf, 471.84)
	buf = appendFloat32(buf, 206.89)
	buf = appendFloat32(buf, 40.23)
	buf = append(buf, make([]byte, 12)...) // unconfirmed fixed 12 bytes

	return buf
}

func TestParse(t *testing.T) {
	data := buildSyntheticRegion(t)

	r, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if r.Version != "1001" {
		t.Fatalf("unexpected version: %q", r.Version)
	}
	if len(r.Objects) != 3 {
		t.Fatalf("expected 3 objects, got %d: %+v", len(r.Objects), r.Objects)
	}

	if r.Objects[0].TypeID != 1805 || len(r.Objects[0].Extra) != 0 {
		t.Fatalf("unexpected object 1: %+v", r.Objects[0])
	}
	if r.Objects[0].Position != [3]float32{287.14, 219.43, 157.65} {
		t.Fatalf("unexpected object 1 position: %+v", r.Objects[0].Position)
	}

	if r.Objects[1].TypeID != 1159 || len(r.Objects[1].Extra) != 6 {
		t.Fatalf("unexpected object 2: %+v", r.Objects[1])
	}

	if r.Objects[2].TypeID != 1798 || len(r.Objects[2].Extra) != 0 {
		t.Fatalf("unexpected object 3: %+v", r.Objects[2])
	}
}

func TestParseEmptyRegion(t *testing.T) {
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, []byte("1000")...)
	buf = append(buf, make([]byte, 200)...) // all-zero, no plausible records

	r, err := Parse(buf)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if r.Version != "1000" {
		t.Fatalf("unexpected version: %q", r.Version)
	}
	if len(r.Objects) != 0 {
		t.Fatalf("expected 0 objects in an all-zero region, got %d", len(r.Objects))
	}
}

// TestParseNarrowerHeader exercises a real, confirmed complication: some
// real files have an 18-byte header (2 bytes narrower than the usual 20)
// before the first record -- found via cross-checking against additional
// real samples beyond the one this format was originally cracked against.
// See docs/protocol/MAPO_FORMAT.md.
func TestParseNarrowerHeader(t *testing.T) {
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, []byte("1001")...)
	buf = appendU32(buf, 0) // unconfirmed header field, only 4 bytes here (not 8)

	buf = appendU32(buf, 1489)
	buf = appendFloat32(buf, 56.8)
	buf = appendFloat32(buf, 167.0)
	buf = appendFloat32(buf, 22.98)
	buf = append(buf, make([]byte, 12)...)

	r, err := Parse(buf)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(r.Objects) != 1 || r.Objects[0].TypeID != 1489 {
		t.Fatalf("expected to recover the object past a narrower header, got %+v", r.Objects)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, minHeaderLen+10)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	if _, err := Parse(make([]byte, minHeaderLen-1)); err == nil {
		t.Fatal("expected error parsing a buffer too small for a header, got nil")
	}
}
