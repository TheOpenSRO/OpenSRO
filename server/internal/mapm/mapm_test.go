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

// buildSyntheticRegionShapeA writes a minimal, synthetic .m-shaped buffer
// (never real game data) using shapeA (11-byte tiles), the layout
// confirmed against the larger (~136-137KB) real file size class: see
// docs/protocol/MAPM_FORMAT.md. Repeats enough tiles for the shape/offset
// detector to confidently distinguish this from shapeB or header padding.
func buildSyntheticRegionShapeA(t *testing.T, heights []float32) []byte {
	t.Helper()

	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, []byte("1000")...)
	buf = append(buf, make([]byte, 12)...) // unconfirmed header bytes

	for _, h := range heights {
		buf = append(buf, 97, 0, 0, 0xff, 0xff)
		buf = appendFloat32(buf, h)
		buf = append(buf, 0, 0)
	}
	return buf
}

func buildSyntheticRegionShapeB(t *testing.T, heights []float32) []byte {
	t.Helper()

	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, []byte("1000")...)
	buf = append(buf, make([]byte, 12)...) // unconfirmed header bytes

	for _, h := range heights {
		buf = append(buf, 5, 200)
		buf = appendFloat32(buf, h)
		buf = append(buf, 1)
	}
	return buf
}

func repeatHeights(v float32, n int) []float32 {
	out := make([]float32, n)
	for i := range out {
		out[i] = v
	}
	return out
}

func TestParseShapeA(t *testing.T) {
	heights := append(repeatHeights(11.08, detectRunLen+2), 12.61)
	data := buildSyntheticRegionShapeA(t, heights)

	r, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if r.Version != "1000" {
		t.Fatalf("unexpected version: %q", r.Version)
	}
	// >= rather than ==: the all-zero header bytes right before the real
	// data can themselves look like one harmless leading all-zero tile to
	// the shape/offset detector (a zero height always passes the sanity
	// check) -- confirmed to happen on real files too (see
	// docs/protocol/MAPM_FORMAT.md), not a bug worth fighting in the
	// fixture.
	if len(r.Tiles) < len(heights) {
		t.Fatalf("expected at least %d tiles, got %d", len(heights), len(r.Tiles))
	}
	if extra := r.Tiles[len(r.Tiles)-2].Extra; len(extra) != 7 { // 11-byte record minus the 4-byte height field
		t.Fatalf("unexpected shapeA extra length: %d", len(extra))
	}
	last := r.Tiles[len(r.Tiles)-1]
	if math.Abs(float64(last.Height-12.61)) > 0.01 {
		t.Fatalf("unexpected last tile height: %v", last.Height)
	}
}

func TestParseShapeB(t *testing.T) {
	heights := append(repeatHeights(19.66, detectRunLen+2), 18.28)
	data := buildSyntheticRegionShapeB(t, heights)

	r, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// >= rather than == -- see the matching comment in TestParseShapeA.
	if len(r.Tiles) < len(heights) {
		t.Fatalf("expected at least %d tiles, got %d", len(heights), len(r.Tiles))
	}
	if extra := r.Tiles[len(r.Tiles)-2].Extra; len(extra) != 3 { // 7-byte record minus the 4-byte height field
		t.Fatalf("unexpected shapeB extra length: %d", len(extra))
	}
	last := r.Tiles[len(r.Tiles)-1]
	if math.Abs(float64(last.Height-18.28)) > 0.01 {
		t.Fatalf("unexpected last tile height: %v", last.Height)
	}
}

// TestParseResyncSkipsUnreadableBytes exercises the resync path in
// isolation: a short gap of unreadable bytes that the natural fixed-stride
// read can't pass, confirming the mechanism advances instead of erroring
// out. The gap is deliberately short and its own value chosen (matching
// the same technique used for server/internal/mapo's equivalent test) so
// no candidate offset within it coincidentally looks like a plausible
// tile — a longer or differently-chosen gap can't guarantee that, since
// the sanity check looks ahead of each candidate offset into what may be
// real (and possibly coincidentally sane-looking) record bytes. That
// inherent ambiguity is real and is documented in
// docs/protocol/MAPM_FORMAT.md, not hidden by this test.
func TestParseResyncSkipsUnreadableBytes(t *testing.T) {
	heights := repeatHeights(11.08, detectRunLen+2)
	buf := buildSyntheticRegionShapeA(t, heights)

	gapStart := len(buf)
	buf = append(buf, 0x44) // one byte the fixed-stride read can't skip past on its own
	tile2Start := len(buf)

	buf = append(buf, 97, 0, 0, 0xff, 0xff)
	buf = appendFloat32(buf, 12.61)
	buf = append(buf, 0, 0)

	for off := gapStart; off < tile2Start; off++ {
		if looksLikeTile(buf, off, shapeA) {
			t.Fatalf("fixture bug: offset %d unexpectedly looks like a tile before the resync target", off)
		}
	}

	r, err := Parse(buf)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// >= rather than == -- see the matching comment in TestParseShapeA.
	if len(r.Tiles) < len(heights)+1 {
		t.Fatalf("expected the resync to recover at least %d tiles, got %d", len(heights)+1, len(r.Tiles))
	}
	last := r.Tiles[len(r.Tiles)-1]
	if math.Abs(float64(last.Height-12.61)) > 0.01 {
		t.Fatalf("expected the resync to recover the real last tile height, got %+v", last)
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

func TestParseRejectsNoTiles(t *testing.T) {
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = append(buf, []byte("1000")...)
	// Not even enough room for one tile record of either known shape.
	if _, err := Parse(buf); err == nil {
		t.Fatal("expected error parsing a region with no room for tile data, got nil")
	}
}
