// Package mapm parses .m (JMXVMAPM) files — the per-region terrain
// heightmap inside Map.pk2, alongside that region's .o object-placement
// file (see server/internal/mapo).
//
// No decompiled loader was found for this format in either sro_client.exe
// or EternityLib.dll (both fully Ghidra-analyzed, RTTI class names
// checked). Confirmed empirically, the same brute-force byte-analysis
// approach used for .bsk and .mapo, against 10 real files pulled directly
// from Map.pk2 — two structurally different tile record shapes were found,
// used by two different file-size classes of region (see
// docs/protocol/MAPM_FORMAT.md for the full derivation, including exactly
// how each shape was found and the small fraction of tiles this parser has
// to resync past rather than read directly).
//
// This package never writes .m files; it only parses ones a caller already
// has (typically extracted from Map.pk2 via server/internal/pk2).
package mapm

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	magic         = "JMXVMAPM"
	magicLen      = 8
	versionLen    = 4
	minHeaderLen  = 12 // magic(8) + version(4); the real header/first-tile boundary is detected, not fixed
	maxHeaderScan = 40 // bound on how far the shape/offset detection scan looks
	maxResync     = 600 // bound on how far the resync scan looks for the next tile -- see below
	detectRunLen  = 50 // how many consecutive tiles a candidate (shape, offset) must produce to be trusted
	heightMinOK   = -2000
	heightMaxOK   = 5000
)

// tileShape describes one of the two confirmed tile record layouts: total
// byte length, and the offset of the 4-byte height float within it.
type tileShape struct {
	length    int
	heightOff int
}

var (
	// shapeA is the layout used by the larger (~136-137KB) region file
	// class: 1 byte (plausibly a texture/terrain-type index, or a blend
	// weight — real data shows 200+ distinct values, too many to be a
	// small fixed catalog) + 4 unconfirmed bytes (two uint16-shaped
	// fields that change tile-to-tile in a locally structured way) +
	// height + 2 unconfirmed trailing bytes.
	shapeA = tileShape{length: 11, heightOff: 5}
	// shapeB is the layout used by the smaller (~92KB) region file class:
	// 2 unconfirmed leading bytes + height + 1 unconfirmed trailing byte.
	shapeB = tileShape{length: 7, heightOff: 2}
)

// Tile is one terrain tile. Height is the one field confirmed real across
// both known record shapes — a real-looking world-scale elevation value.
// Extra holds every other raw byte of the record (whose count and meaning
// differ by shape — see shapeA/shapeB above), kept raw rather than
// mislabeled.
type Tile struct {
	Height float32
	Extra  []byte
}

// Region is a parsed .m file.
type Region struct {
	// Version is the 4-byte tag after the magic, e.g. "1000".
	Version string
	Tiles   []Tile
}

// Parse parses a .m file's raw bytes.
//
// Real files use one of two tile record shapes (shapeA or shapeB above),
// and don't hold to a fixed stride perfectly even once the right shape is
// known — real data needed a byte-level resync (scanning forward for the
// next position with a plausible height value) to fully recover, the same
// technique server/internal/mapo needed for its variable-length trailers.
// Since there's no header field declaring which shape a file uses, Parse
// detects it: it tries every (shape, starting offset) combination in a
// small window right after the version tag, and picks whichever produces
// the longest unbroken run of plausible tiles — confirmed to correctly
// pick shapeA for every real file in the larger size class and shapeB for
// every real file in the smaller one.
//
// The resync bound (maxResync, 600 bytes) is wider than server/internal/mapo
// needed for the same mechanism: some real shapeB files interleave real
// tile data with long (up to 509 bytes observed) runs of a repeating
// non-tile pattern — plausibly a "no data here" run-length/mask section,
// not confirmed — between bands of real tiles. An earlier, narrower bound
// (64 bytes, matched to .mapo's much shorter gaps) made those files look
// like they only had a small fraction of their real tile data, stopping
// permanently at the first such run; widening the bound recovers the real
// tile bands on the far side and gets every real file checked to ~100%
// consumption. See docs/protocol/MAPM_FORMAT.md for the full derivation.
func Parse(data []byte) (*Region, error) {
	if len(data) < minHeaderLen {
		return nil, errors.New("mapm: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("mapm: bad magic %q, want %q", data[0:magicLen], magic)
	}

	r := &Region{Version: string(data[magicLen : magicLen+versionLen])}

	shape, start, ok := detectShape(data, magicLen+versionLen)
	if !ok {
		return nil, errors.New("mapm: no plausible tile data found")
	}

	off := start
	for off+shape.length <= len(data) {
		if !looksLikeTile(data, off, shape) {
			resynced, ok := resync(data, off, shape)
			if !ok {
				break
			}
			off = resynced
		}

		height := readFloat32(data, off+shape.heightOff)
		extra := make([]byte, 0, shape.length-4)
		extra = append(extra, data[off:off+shape.heightOff]...)
		extra = append(extra, data[off+shape.heightOff+4:off+shape.length]...)
		r.Tiles = append(r.Tiles, Tile{Height: height, Extra: extra})
		off += shape.length
	}

	if len(r.Tiles) == 0 {
		return nil, errors.New("mapm: no tiles parsed")
	}

	return r, nil
}

// detectShape tries every (shape, offset) combination in a small window
// starting at from, and returns whichever produces the longest unbroken
// run of plausible tiles at a fixed stride (no resync) — confirmed to
// reliably distinguish the two known real shapes from each other and from
// header padding on every real file checked.
func detectShape(data []byte, from int) (tileShape, int, bool) {
	limit := from + maxHeaderScan
	if limit > len(data) {
		limit = len(data)
	}
	bestRun := -1
	var bestShape tileShape
	bestOff := -1
	for _, shape := range []tileShape{shapeA, shapeB} {
		for off := from; off < limit; off++ {
			run := runLength(data, off, shape)
			if run > bestRun {
				bestRun = run
				bestShape = shape
				bestOff = off
			}
		}
	}
	if bestOff == -1 || bestRun == 0 {
		return tileShape{}, 0, false
	}
	return bestShape, bestOff, true
}

func runLength(data []byte, off int, shape tileShape) int {
	n := 0
	for n < detectRunLen && looksLikeTile(data, off, shape) {
		n++
		off += shape.length
	}
	return n
}

func resync(data []byte, off int, shape tileShape) (int, bool) {
	scanned := 0
	for off < len(data) && !looksLikeTile(data, off, shape) && scanned < maxResync {
		off++
		scanned++
	}
	return off, looksLikeTile(data, off, shape)
}

func looksLikeTile(data []byte, off int, shape tileShape) bool {
	if off+shape.length > len(data) {
		return false
	}
	return saneHeight(readFloat32(data, off+shape.heightOff))
}

func saneHeight(v float32) bool {
	if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
		return false
	}
	if v == 0 {
		return true
	}
	// Reject suspiciously tiny magnitudes too -- misaligned binary data
	// reads as subnormal-range float noise that a plain range check lets
	// through (confirmed the hard way: server/internal/mapo hit the same
	// false-positive shape with position floats).
	abs := math.Abs(float64(v))
	return abs > 1e-3 && float64(v) > heightMinOK && float64(v) < heightMaxOK
}

func readFloat32(data []byte, off int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(data[off:]))
}
