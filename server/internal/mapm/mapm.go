// Package mapm parses .m (JMXVMAPM) files — the per-region terrain
// heightmap inside Map.pk2, alongside that region's .o object-placement
// file (see server/internal/mapo).
//
// The overall block/grid structure (a region is a 6x6 grid of blocks,
// each block a 17x17 vertex mesh plus a 16x16 tile-flag grid) matches
// public private-server community documentation of this format (see
// docs/protocol/MAPM_FORMAT.md for the citation) — per docs/LEGAL.md,
// treating well-established public protocol documentation as a spec is
// standard clean-room practice, distinct from decompiling a binary. This
// package's own byte-for-byte verification against real files (see the
// format doc) is independent confirmation, not a blind copy: two real
// per-region file-size classes exist, using two different per-vertex
// record sizes (7 and 11 bytes) the public doc doesn't distinguish by
// name — this package calls them by their real per-vertex byte length
// rather than inventing a "shape" label, now that the exact byte layout
// (not just a size class) is confirmed for both.
//
// Parsing is fully deterministic: no resync scanning is needed, unlike
// this package's own earlier plausibility-based implementation — every
// real block is a fixed size once its per-vertex record length is known,
// and that per-vertex length can be read directly off the file's own
// total size (see detectVertexSize).
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
	magic          = "JMXVMAPM"
	magicLen       = 8
	versionLen     = 4
	headerLen      = magicLen + versionLen // 12
	blocksPerSide  = 6
	blockCount     = blocksPerSide * blocksPerSide // 36
	gridWidth      = 17
	vertexCount    = gridWidth * gridWidth // 289
	blockHeaderLen = 4 + 2                 // Flag(uint32) + EnvironmentID(uint16)
	planeInfoLen   = 1 + 1 + 4             // PlaneType(int8) + WaveID(uint8) + PlaneHeight(float32)
	tileFlagCount  = 16 * 16
	tileFlagLen    = tileFlagCount * 2 // 512, uint16 per tile, parsed and discarded
	heightInfoLen  = 4 + 4             // HeightMax + HeightMin

	// The two real, confirmed per-vertex record lengths. Height is a
	// real float32 at relative offset 0 in both (confirmed by decoding
	// real files and checking for smoothly-varying, plausible terrain
	// height sequences — not assumed from the public doc alone).
	vertexLen7  = 7  // real per-region file-size class ~92KB
	vertexLen11 = 11 // real per-region file-size class ~136-137KB

	// The two real, confirmed trailing "Reserved" byte counts following
	// each block's tile-flag grid — real, confirmed exactly by checking
	// that every one of a real file's 36 blocks parses with plausible
	// field values and the last block ends exactly at EOF. Their content
	// isn't used by anything here (unconfirmed meaning), only their
	// length, needed to advance past them correctly.
	reservedLen7  = 20 // paired with vertexLen7
	reservedLen11 = 70 // paired with vertexLen11
)

// Vertex is one real terrain mesh vertex. Height is a real, confirmed
// float32. Extra holds the vertex record's remaining raw bytes (a real
// per-tile texture-info uint16 + brightness byte for the 7-byte record;
// unconfirmed extra fields, including a real column/row-cycling pattern
// this project independently found, for the 11-byte one) — kept raw
// rather than mislabeled.
type Vertex struct {
	Height float32
	Extra  []byte
}

// Block is one real 17x17 (gridWidth x gridWidth) vertex sub-mesh, one of
// blockCount (36) making up a whole region in real 6x6 nested file order
// (row-major: index = bandRow*blocksPerSide + bandCol). Vertices is
// row-major within the block too (index = z*gridWidth + x), matching the
// public doc's own nested-loop order.
type Block struct {
	Flag          uint32
	EnvironmentID uint16
	Vertices      [vertexCount]Vertex
	PlaneType     int8
	WaveID        uint8
	PlaneHeight   float32
	HeightMax     float32
	HeightMin     float32
}

// Region is a parsed .m file. Blocks is always exactly blockCount (36)
// long on success.
type Region struct {
	// Version is the 4-byte tag after the magic, e.g. "1000".
	Version string
	Blocks  []Block
}

// Parse parses a .m file's raw bytes.
func Parse(data []byte) (*Region, error) {
	if len(data) < headerLen {
		return nil, errors.New("mapm: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("mapm: bad magic %q, want %q", data[0:magicLen], magic)
	}

	vertexLen, reservedLen, err := detectVertexSize(data)
	if err != nil {
		return nil, err
	}

	r := &Region{Version: string(data[magicLen:headerLen])}

	off := headerLen
	for b := 0; b < blockCount; b++ {
		var block Block
		block.Flag = binary.LittleEndian.Uint32(data[off:])
		block.EnvironmentID = binary.LittleEndian.Uint16(data[off+4:])
		off += blockHeaderLen

		for v := 0; v < vertexCount; v++ {
			vOff := off + v*vertexLen
			block.Vertices[v] = Vertex{
				Height: readFloat32(data, vOff),
				Extra:  append([]byte(nil), data[vOff+4:vOff+vertexLen]...),
			}
		}
		off += vertexCount * vertexLen

		block.PlaneType = int8(data[off])
		block.WaveID = data[off+1]
		block.PlaneHeight = readFloat32(data, off+2)
		off += planeInfoLen

		off += tileFlagLen // real per-tile flag grid, parsed and discarded -- not used

		block.HeightMax = readFloat32(data, off)
		block.HeightMin = readFloat32(data, off+4)
		off += heightInfoLen

		off += reservedLen // real trailing bytes, unconfirmed meaning, parsed and discarded

		r.Blocks = append(r.Blocks, block)
	}

	if off != len(data) {
		// A real, confirmed anomaly on a small minority of real files
		// (e.g. a real 0/0.m): the block data ends exactly as expected,
		// but a real all-zero trailer of unconfirmed purpose follows
		// (observed once at exactly 1,000 bytes). Only ever accepted as
		// all-zero padding, never guessed at as real trailing data.
		trailer := data[off:]
		for _, b := range trailer {
			if b != 0 {
				return nil, fmt.Errorf("mapm: parsed %d bytes but file is %d, and the %d leftover bytes aren't all zero", off, len(data), len(trailer))
			}
		}
	}

	return r, nil
}

// maxKnownTrailer bounds how much of a real, confirmed all-zero trailer
// (see Parse) a file is allowed to have beyond one of the two exact real
// totals below -- real files checked so far only ever showed exactly
// 1,000 such bytes; this is a generous multiple of that, not a precise
// bound, to avoid mistaking a genuinely malformed/truncated file for one
// with a real trailer.
const maxKnownTrailer = 8192

// detectVertexSize reports which of the two real, confirmed per-vertex
// record sizes (and their paired real Reserved-field length) this file's
// own total size implies. Real files fit exactly one of the two candidate
// exact totals, or that total plus a real, confirmed-zero-only trailer
// (see the caller) -- picks the larger candidate whenever the file is big
// enough to hold it (within maxKnownTrailer), since the two real totals
// are far enough apart (92,712 vs 136,116 bytes) that a genuine size-11
// file is never mistakable for a padded size-7 one at that bound.
func detectVertexSize(data []byte) (vertexLen, reservedLen int, err error) {
	fixedOverhead := blockHeaderLen + planeInfoLen + tileFlagLen + heightInfoLen
	block7 := fixedOverhead + vertexCount*vertexLen7 + reservedLen7
	block11 := fixedOverhead + vertexCount*vertexLen11 + reservedLen11
	total7 := headerLen + blockCount*block7
	total11 := headerLen + blockCount*block11

	switch {
	case len(data) >= total11 && len(data) <= total11+maxKnownTrailer:
		return vertexLen11, reservedLen11, nil
	case len(data) >= total7 && len(data) <= total7+maxKnownTrailer:
		return vertexLen7, reservedLen7, nil
	default:
		return 0, 0, fmt.Errorf("mapm: file size %d bytes doesn't match either known real layout (want %d, %d, or up to %d more of real zero padding)", len(data), total7, total11, maxKnownTrailer)
	}
}

func readFloat32(data []byte, off int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(data[off:]))
}
