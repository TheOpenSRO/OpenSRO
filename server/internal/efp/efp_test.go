package efp

import (
	"encoding/binary"
	"testing"
)

func appendU32(b []byte, v uint32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], v)
	return append(b, tmp[:]...)
}

func appendLenPrefixed(b []byte, s string) []byte {
	b = appendU32(b, uint32(len(s)))
	return append(b, []byte(s)...)
}

// build0011 writes a minimal, synthetic version-"0011" .efp-shaped buffer
// (never real game data) matching the layout confirmed against 24 real
// files: see docs/protocol/EFP_FORMAT.md.
func build0011(t *testing.T) []byte {
	t.Helper()
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, ' ')
	buf = append(buf, []byte("0011")...)
	buf = appendU32(buf, 0) // unconfirmed u32
	buf = appendLenPrefixed(buf, "myeffect")
	buf = appendU32(buf, 2) // top-level count

	// Entry 1: a "leaf" property with some opaque value bytes before the
	// next name starts.
	buf = appendLenPrefixed(buf, "NormalTimeLife")
	buf = append(buf, 0, 0, 0, 0, 0, 0, 0, 0) // 8 bytes of opaque value

	// Entry 2: another property, with a differently-sized value.
	buf = appendLenPrefixed(buf, "StaticEmit")
	buf = append(buf, make([]byte, 20)...) // 20 bytes of opaque value

	return buf
}

func TestParse0011(t *testing.T) {
	data := build0011(t)

	e, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if e.Version != "0011" {
		t.Fatalf("unexpected version: %q", e.Version)
	}
	if e.Name != "myeffect" {
		t.Fatalf("unexpected name: %q", e.Name)
	}
	if e.Count != 2 {
		t.Fatalf("unexpected count: %d", e.Count)
	}
	if len(e.Entries) != 2 {
		t.Fatalf("expected 2 entries, got %d: %+v", len(e.Entries), e.Entries)
	}
	if e.Entries[0].Name != "NormalTimeLife" || len(e.Entries[0].Value) != 8 {
		t.Fatalf("unexpected entry 1: %+v", e.Entries[0])
	}
	if e.Entries[1].Name != "StaticEmit" || len(e.Entries[1].Value) != 20 {
		t.Fatalf("unexpected entry 2: %+v", e.Entries[1])
	}
}

// build0013 writes a minimal, synthetic version-"0013" buffer, matching
// the layout confirmed against 5 real files with this version tag.
func build0013(t *testing.T) []byte {
	t.Helper()
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, ' ')
	buf = append(buf, []byte("0013")...)
	buf = appendU32(buf, 0x3f000000)         // unconfirmed float32 (0.5)
	buf = append(buf, make([]byte, 12)...)   // 12 reserved bytes, observed zero
	buf = appendU32(buf, 193)                // unconfirmed u32
	buf = appendLenPrefixed(buf, "fireball") // effect name
	buf = appendU32(buf, 1)                  // top-level count

	buf = appendLenPrefixed(buf, "NormalTimeLife")
	buf = append(buf, 0, 0, 0, 0)

	return buf
}

func TestParse0013(t *testing.T) {
	data := build0013(t)

	e, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if e.Version != "0013" {
		t.Fatalf("unexpected version: %q", e.Version)
	}
	if e.Name != "fireball" {
		t.Fatalf("unexpected name: %q", e.Name)
	}
	if len(e.Entries) != 1 || e.Entries[0].Name != "NormalTimeLife" {
		t.Fatalf("unexpected entries: %+v", e.Entries)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, 30)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsUnknownVersion(t *testing.T) {
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, ' ')
	buf = append(buf, []byte("9999")...)
	buf = append(buf, make([]byte, 20)...)
	if _, err := Parse(buf); err == nil {
		t.Fatal("expected error parsing buffer with an unrecognized version, got nil")
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	data := build0011(t)
	if _, err := Parse(data[:20]); err == nil {
		t.Fatal("expected error parsing truncated buffer, got nil")
	}
}
