package cpd

import (
	"encoding/binary"
	"testing"
)

// buildHeader writes a real-shaped .cpd header (magic + 2 unconfirmed u32
// + 20 reserved bytes + 2 unconfirmed u16, matching every real sample
// checked) followed by a real length-prefixed name string.
func buildHeader(name string) []byte {
	buf := make([]byte, headerLen)
	copy(buf, magic)
	binary.LittleEndian.PutUint32(buf[12:], 66) // unconfirmed field A
	binary.LittleEndian.PutUint32(buf[16:], 70) // unconfirmed field B
	binary.LittleEndian.PutUint16(buf[40:], 2)  // unconfirmed field C
	binary.LittleEndian.PutUint16(buf[42:], 3)  // unconfirmed field D

	buf = binary.LittleEndian.AppendUint32(buf, uint32(len(name)))
	buf = append(buf, name...)
	return buf
}

func appendLenPrefixed(b []byte, s string) []byte {
	b = binary.LittleEndian.AppendUint32(b, uint32(len(s)))
	return append(b, s...)
}

// TestParseFlatSubCount mirrors the real st_sand_01.cpd shape: a flat real
// sub-count (unconfirmed field this package doesn't rely on) followed
// directly by 2 real .bsr path entries.
func TestParseFlatSubCount(t *testing.T) {
	data := buildHeader("st_sand_01")
	data = binary.LittleEndian.AppendUint32(data, 0) // real reserved/unconfirmed field
	data = binary.LittleEndian.AppendUint32(data, 0) // real reserved/unconfirmed field
	data = binary.LittleEndian.AppendUint32(data, 2) // real sub-count (unused by this package)
	data = appendLenPrefixed(data, `res\nature\particle\st_sand01.bsr`)
	data = appendLenPrefixed(data, `res\nature\particle\st_sand02.bsr`)

	c, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if c.Name != "st_sand_01" {
		t.Fatalf("unexpected name: %q", c.Name)
	}
	if len(c.BsrPaths) != 2 {
		t.Fatalf("expected 2 real .bsr paths, got %d: %v", len(c.BsrPaths), c.BsrPaths)
	}
	if c.BsrPaths[0] != `res\nature\particle\st_sand01.bsr` || c.BsrPaths[1] != `res\nature\particle\st_sand02.bsr` {
		t.Fatalf("unexpected paths: %v", c.BsrPaths)
	}
}

// TestParseWithDuplicateAndMidListField mirrors the real x_mas_tree_b.cpd
// shape: real unconfirmed fields, a real duplicate entry, and a real
// unconfirmed count-like field sitting between two entries. The scanning
// approach must recover all 9 real entries regardless.
func TestParseWithDuplicateAndMidListField(t *testing.T) {
	data := buildHeader("x_mas_tree_b")
	data = binary.LittleEndian.AppendUint32(data, 3) // real unconfirmed field
	data = binary.LittleEndian.AppendUint32(data, 2) // real unconfirmed field
	data = appendLenPrefixed(data, `res\bldg\common\event-xmas\x_mas_tree_b.bsr`)
	data = binary.LittleEndian.AppendUint32(data, 8) // real unconfirmed mid-list field
	data = appendLenPrefixed(data, `res\bldg\common\event-xmas\x_mas_tree_b.bsr`)
	data = appendLenPrefixed(data, `res\bldg\common\event-xmas\x_mas_tree_bcandle.bsr`)
	data = appendLenPrefixed(data, `res\bldg\common\event-xmas\x_mas_tree_bdeco.bsr`)

	c, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(c.BsrPaths) != 4 {
		t.Fatalf("expected 4 real .bsr paths, got %d: %v", len(c.BsrPaths), c.BsrPaths)
	}
	if c.BsrPaths[0] != c.BsrPaths[1] {
		t.Fatalf("expected the real duplicate entry to survive: %v", c.BsrPaths)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	data := buildHeader("x")
	data[0] = 'X'
	if _, err := Parse(data); err == nil {
		t.Error("expected error for bad magic, got nil")
	}
}

func TestParseRejectsTooSmall(t *testing.T) {
	if _, err := Parse([]byte{1, 2, 3}); err == nil {
		t.Error("expected error for too-small buffer, got nil")
	}
}

func TestParseNoTrailingData(t *testing.T) {
	data := buildHeader("empty")
	c, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(c.BsrPaths) != 0 {
		t.Fatalf("expected no real .bsr paths, got %v", c.BsrPaths)
	}
}
