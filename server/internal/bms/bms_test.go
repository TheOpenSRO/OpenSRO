package bms

import (
	"encoding/binary"
	"math"
	"testing"
)

// buildSyntheticMesh writes a minimal, synthetic .bms-shaped buffer (never
// real game data) matching the layout confirmed against a real archive: see
// docs/protocol/BMS_FORMAT.md. It's a single triangle, not the 9-vertex
// fixture we verified by hand, to keep the fixture easy to read.
func buildSyntheticMesh(t *testing.T) []byte {
	t.Helper()

	name := "Tri01"
	material := "Mat01"

	// Header: magic(12) + u32(4) + 6 header pointers(24) + 2 reserved
	// u32(8) + 1 more u32(4) + 2 reserved u32(8) + flag u32(4) = 0x48
	// bytes, then the name string.
	buf := make([]byte, preambleEnd)
	copy(buf, magic)
	binary.LittleEndian.PutUint32(buf[0x3c:], 1) // observed-constant flag

	appendLenPrefixed := func(b []byte, s string) []byte {
		lp := make([]byte, 4+len(s))
		binary.LittleEndian.PutUint32(lp, uint32(len(s)))
		copy(lp[4:], s)
		return append(b, lp...)
	}
	buf = appendLenPrefixed(buf, name)
	buf = appendLenPrefixed(buf, material)

	// Unconfirmed u32 (observed constant 1), then vertex count.
	buf = binary.LittleEndian.AppendUint32(buf, 1)
	buf = binary.LittleEndian.AppendUint32(buf, 3)

	writeVertex := func(pos, normal [3]float32, uv [2]float32) {
		var rec [vertexRecSize]byte
		for i, f := range pos {
			binary.LittleEndian.PutUint32(rec[i*4:], float32bits(f))
		}
		for i, f := range normal {
			binary.LittleEndian.PutUint32(rec[0x0c+i*4:], float32bits(f))
		}
		binary.LittleEndian.PutUint32(rec[0x18:], float32bits(uv[0]))
		binary.LittleEndian.PutUint32(rec[0x1c:], float32bits(uv[1]))
		binary.LittleEndian.PutUint32(rec[0x24:], 0xFFFFFFFF)
		buf = append(buf, rec[:]...)
	}
	writeVertex([3]float32{0, 0, 0}, [3]float32{0, 1, 0}, [2]float32{0, 0})
	writeVertex([3]float32{1, 0, 0}, [3]float32{0, 1, 0}, [2]float32{1, 0})
	writeVertex([3]float32{0, 0, 1}, [3]float32{0, 1, 0}, [2]float32{0, 1})

	// hdr[1]: index section offset.
	indexOff := uint32(len(buf))
	binary.LittleEndian.PutUint32(buf[headerPtrsBase+1*4:], indexOff)
	buf = binary.LittleEndian.AppendUint32(buf, 1) // triangle count
	buf = binary.LittleEndian.AppendUint16(buf, 0)
	buf = binary.LittleEndian.AppendUint16(buf, 1)
	buf = binary.LittleEndian.AppendUint16(buf, 2)

	// hdr[4]: bounding box offset (min xyz, max xyz).
	bboxOff := uint32(len(buf))
	binary.LittleEndian.PutUint32(buf[headerPtrsBase+4*4:], bboxOff)
	for _, f := range []float32{0, 0, 0, 1, 0, 1} {
		buf = binary.LittleEndian.AppendUint32(buf, float32bits(f))
	}

	return buf
}

func float32bits(f float32) uint32 {
	return math.Float32bits(f)
}

func TestParse(t *testing.T) {
	data := buildSyntheticMesh(t)

	m, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if m.Name != "Tri01" || m.MaterialName != "Mat01" {
		t.Fatalf("unexpected names: %+v", m)
	}
	if len(m.Vertices) != 3 {
		t.Fatalf("expected 3 vertices, got %d", len(m.Vertices))
	}
	if len(m.Indices) != 3 {
		t.Fatalf("expected 3 indices (1 triangle), got %d", len(m.Indices))
	}
	if m.Indices[0] != 0 || m.Indices[1] != 1 || m.Indices[2] != 2 {
		t.Fatalf("unexpected indices: %v", m.Indices)
	}

	v1 := m.Vertices[1]
	if v1.Position != [3]float32{1, 0, 0} {
		t.Fatalf("unexpected v1 position: %v", v1.Position)
	}
	if v1.Normal != [3]float32{0, 1, 0} {
		t.Fatalf("unexpected v1 normal: %v", v1.Normal)
	}
	if v1.UV != [2]float32{1, 0} {
		t.Fatalf("unexpected v1 UV: %v", v1.UV)
	}

	if m.BoundsMin != [3]float32{0, 0, 0} || m.BoundsMax != [3]float32{1, 0, 1} {
		t.Fatalf("unexpected bounds: min=%v max=%v", m.BoundsMin, m.BoundsMax)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, preambleEnd)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	data := buildSyntheticMesh(t)
	// Cut off partway through the vertex array (well before the optional,
	// best-effort bounding-box tail) so this exercises a hard failure path.
	truncated := data[:preambleEnd+20]
	if _, err := Parse(truncated); err == nil {
		t.Fatal("expected error parsing truncated buffer, got nil")
	}
}
