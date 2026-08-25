package ddj

import (
	"encoding/binary"
	"testing"
)

// buildSyntheticDDJ writes a minimal, synthetic .ddj-shaped buffer (never
// real game data): the confirmed 20-byte wrapper around a standard,
// uncompressed-RGBA DDS file just large enough to hold its header plus a
// few pixels. See docs/protocol/DDJ_FORMAT.md.
func buildSyntheticDDJ(t *testing.T, width, height uint32, fourCC string) []byte {
	t.Helper()

	pixelBytes := 4 // uncompressed RGBA
	if fourCC != "" {
		pixelBytes = 0 // compressed formats' size isn't computed here; unused in tests that pass fourCC
	}
	dds := make([]byte, 4+ddsHeaderSize+int(width*height)*pixelBytes)
	copy(dds, "DDS ")
	binary.LittleEndian.PutUint32(dds[4:], ddsHeaderSize)
	binary.LittleEndian.PutUint32(dds[4+8:], height)
	binary.LittleEndian.PutUint32(dds[4+12:], width)
	binary.LittleEndian.PutUint32(dds[4+24:], 1) // mip count

	pf := dds[4+72:]
	binary.LittleEndian.PutUint32(pf[0:], 32) // DDS_PIXELFORMAT dwSize
	if fourCC != "" {
		binary.LittleEndian.PutUint32(pf[4:], 0x4) // DDPF_FOURCC
		copy(pf[8:12], fourCC)
	} else {
		binary.LittleEndian.PutUint32(pf[4:], 0x41) // DDPF_RGB | DDPF_ALPHAPIXELS
		binary.LittleEndian.PutUint32(pf[12:], 32)  // dwRGBBitCount
	}

	buf := make([]byte, wrapperSize+len(dds))
	copy(buf, magic)
	binary.LittleEndian.PutUint32(buf[0x0c:], uint32(len(buf)-magicLen))
	binary.LittleEndian.PutUint32(buf[0x10:], 3)
	copy(buf[wrapperSize:], dds)
	return buf
}

func TestParseUncompressed(t *testing.T) {
	data := buildSyntheticDDJ(t, 32, 64, "")

	tex, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if tex.Width != 32 || tex.Height != 64 {
		t.Fatalf("unexpected dimensions: %dx%d", tex.Width, tex.Height)
	}
	if tex.FourCC != "" {
		t.Fatalf("expected no FourCC for uncompressed texture, got %q", tex.FourCC)
	}
	if len(tex.DDS) < 4+ddsHeaderSize {
		t.Fatalf("DDS payload too short: %d bytes", len(tex.DDS))
	}
	if string(tex.DDS[0:4]) != "DDS " {
		t.Fatalf("DDS payload doesn't start with DDS magic: %q", tex.DDS[0:4])
	}
}

func TestParseCompressed(t *testing.T) {
	data := buildSyntheticDDJ(t, 128, 128, "DXT1")

	tex, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if tex.FourCC != "DXT1" {
		t.Fatalf("expected FourCC DXT1, got %q", tex.FourCC)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, wrapperSize+4)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseToleratesMismatchedSizeField(t *testing.T) {
	// Real file (Prim\Mtrl\Item\China\weapon\shield_90.ddj, 2026-08-24) has
	// a 0x0c field that doesn't equal len(data)-magicLen even though it's
	// an otherwise well-formed, fully parseable texture -- see Parse's own
	// comment. Parsing must succeed regardless of this field's value.
	data := buildSyntheticDDJ(t, 4, 4, "")
	binary.LittleEndian.PutUint32(data[0x0c:], 0xFFFFFFFF)
	if _, err := Parse(data); err != nil {
		t.Fatalf("Parse: %v", err)
	}
}

func TestParseRejectsBadDDSMagic(t *testing.T) {
	data := buildSyntheticDDJ(t, 4, 4, "")
	copy(data[ddsMagicOff:], "NOPE")
	if _, err := Parse(data); err == nil {
		t.Fatal("expected error parsing buffer with bad embedded DDS magic, got nil")
	}
}
