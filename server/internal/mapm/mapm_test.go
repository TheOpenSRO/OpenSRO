package mapm

import (
	"encoding/binary"
	"math"
	"testing"
)

func appendFloat32(b []byte, v float32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], math.Float32bits(v))
	return append(b, tmp[:]...)
}

func appendU16(b []byte, v uint16) []byte {
	var tmp [2]byte
	binary.LittleEndian.PutUint16(tmp[:], v)
	return append(b, tmp[:]...)
}

func appendU32(b []byte, v uint32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], v)
	return append(b, tmp[:]...)
}

// buildBlock writes one real-shaped block: header, vertexCount vertices
// (each heightFn(v) plus vertexLen-4 filler bytes), plane info, the
// tile-flag grid, height info, and reservedLen trailing bytes — the exact
// real structure confirmed in docs/protocol/MAPM_FORMAT.md.
func buildBlock(buf []byte, vertexLen, reservedLen int, heightFn func(v int) float32) []byte {
	buf = appendU32(buf, 0) // Flag
	buf = appendU16(buf, 0) // EnvironmentID
	for v := 0; v < vertexCount; v++ {
		buf = appendFloat32(buf, heightFn(v))
		buf = append(buf, make([]byte, vertexLen-4)...)
	}
	buf = append(buf, 0xff)         // PlaneType = -1 (Normal)
	buf = append(buf, 0)            // WaveID
	buf = appendFloat32(buf, 0)     // PlaneHeight
	buf = append(buf, make([]byte, tileFlagLen)...)
	buf = appendFloat32(buf, 0) // HeightMax
	buf = appendFloat32(buf, 0) // HeightMin
	buf = append(buf, make([]byte, reservedLen)...)
	return buf
}

// buildRegion builds a full, real-shaped region: blockCount (36) blocks in
// real nested order, each built by buildBlock. heightFn is called with
// (blockIndex, vertexIndex) so tests can make specific vertices
// distinguishable.
func buildRegion(vertexLen, reservedLen int, heightFn func(block, v int) float32) []byte {
	buf := []byte(magic)
	buf = append(buf, []byte("1000")...)
	for b := 0; b < blockCount; b++ {
		buf = buildBlock(buf, vertexLen, reservedLen, func(v int) float32 { return heightFn(b, v) })
	}
	return buf
}

func TestParseVertexLen7(t *testing.T) {
	data := buildRegion(vertexLen7, reservedLen7, func(block, v int) float32 {
		if block == 0 && v == 5 {
			return 182.67
		}
		return 0
	})

	r, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if r.Version != "1000" {
		t.Fatalf("unexpected version: %q", r.Version)
	}
	if len(r.Blocks) != blockCount {
		t.Fatalf("got %d blocks, want %d", len(r.Blocks), blockCount)
	}
	if h := r.Blocks[0].Vertices[5].Height; math.Abs(float64(h-182.67)) > 0.01 {
		t.Errorf("block 0 vertex 5 height = %v, want 182.67", h)
	}
	if len(r.Blocks[0].Vertices[5].Extra) != vertexLen7-4 {
		t.Errorf("extra length = %d, want %d", len(r.Blocks[0].Vertices[5].Extra), vertexLen7-4)
	}
}

func TestParseVertexLen11(t *testing.T) {
	data := buildRegion(vertexLen11, reservedLen11, func(block, v int) float32 {
		if block == 35 && v == vertexCount-1 {
			return 11.08
		}
		return 0
	})

	r, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(r.Blocks) != blockCount {
		t.Fatalf("got %d blocks, want %d", len(r.Blocks), blockCount)
	}
	last := r.Blocks[35].Vertices[vertexCount-1]
	if math.Abs(float64(last.Height-11.08)) > 0.01 {
		t.Errorf("last vertex height = %v, want 11.08", last.Height)
	}
	if len(last.Extra) != vertexLen11-4 {
		t.Errorf("extra length = %d, want %d", len(last.Extra), vertexLen11-4)
	}
}

func TestParseBlockFields(t *testing.T) {
	buf := []byte(magic)
	buf = append(buf, []byte("1000")...)
	for b := 0; b < blockCount; b++ {
		flag := uint32(0)
		envID := uint16(0)
		if b == 3 {
			flag = 1
			envID = 42
		}
		buf = appendU32(buf, flag)
		buf = appendU16(buf, envID)
		for v := 0; v < vertexCount; v++ {
			buf = appendFloat32(buf, 0)
			buf = append(buf, make([]byte, vertexLen7-4)...)
		}
		planeType := byte(0xff)
		if b == 3 {
			planeType = 1 // Ice
		}
		buf = append(buf, planeType)
		buf = append(buf, 7) // WaveID
		buf = appendFloat32(buf, 12.5)
		buf = append(buf, make([]byte, tileFlagLen)...)
		buf = appendFloat32(buf, 200.0) // HeightMax
		buf = appendFloat32(buf, -5.0)  // HeightMin
		buf = append(buf, make([]byte, reservedLen7)...)
	}

	r, err := Parse(buf)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	block3 := r.Blocks[3]
	if block3.Flag != 1 {
		t.Errorf("Flag = %d, want 1", block3.Flag)
	}
	if block3.EnvironmentID != 42 {
		t.Errorf("EnvironmentID = %d, want 42", block3.EnvironmentID)
	}
	if block3.PlaneType != 1 {
		t.Errorf("PlaneType = %d, want 1", block3.PlaneType)
	}
	if block3.WaveID != 7 {
		t.Errorf("WaveID = %d, want 7", block3.WaveID)
	}
	if block3.HeightMax != 200.0 || block3.HeightMin != -5.0 {
		t.Errorf("HeightMax/Min = %v/%v, want 200/-5", block3.HeightMax, block3.HeightMin)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, headerLen+10)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	if _, err := Parse(make([]byte, headerLen-1)); err == nil {
		t.Fatal("expected error parsing a buffer too small for a header, got nil")
	}
}

func TestParseRejectsUnrecognizedSize(t *testing.T) {
	buf := []byte(magic)
	buf = append(buf, []byte("1000")...)
	buf = append(buf, make([]byte, 100)...) // not a multiple of blockCount, not a real block size either
	if _, err := Parse(buf); err == nil {
		t.Fatal("expected error parsing a region with an unrecognized body size, got nil")
	}
}

func TestParseRejectsTruncatedMidBlock(t *testing.T) {
	data := buildRegion(vertexLen7, reservedLen7, func(block, v int) float32 { return 0 })
	// Cut off partway through the last block -- body length is no longer
	// evenly divisible by blockCount, so this must be rejected outright.
	truncated := data[:len(data)-5]
	if _, err := Parse(truncated); err == nil {
		t.Fatal("expected error parsing a region truncated mid-block, got nil")
	}
}
