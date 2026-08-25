// Package bms parses .bms (JMXVBMS) mesh files — the actual triangle-mesh
// geometry format referenced by .bsr "static object" resource files. See
// docs/protocol/BMS_FORMAT.md for the on-disk layout, which was verified
// empirically the same way as the pk2 fix: decompiling the real loader
// (sro_client.exe) to confirm the vertex record's field layout, then
// cross-checking against real extracted .bms files. No decompiler output is
// stored in this repo, only the resulting facts about the container format.
//
// This package never writes .bms files; it only parses ones a caller
// already has (typically extracted from a pk2 archive via
// server/internal/pk2).
package bms

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	magic          = "JMXVBMS 0110"
	magicLen       = 12
	preambleEnd    = 0x48 // fixed header size before the name string, for version "0110"
	indexRecSize   = 6    // 3x uint16 per triangle
	numHeaderPtrs  = 6
	headerPtrsBase = 0x10
)

// vertexRecSizeCandidates are the two real per-vertex record sizes found in
// real files: 44 bytes (position+normal+uv+12 unconfirmed trailing bytes —
// the only size this project's earlier samples, all small character
// hair/face/body-part meshes, ever showed) and 52 bytes (found 2026-08-23,
// live-testing real, larger Jangan palace building meshes — the same
// leading position+normal+uv fields, but 20 trailing bytes instead of 12).
// Real per-file evidence for 52: pulling and parsing a real
// `cj_pal_bigdoor_roof01.bms` (676 vertices) at the documented 44-byte
// stride produced NaN values and wildly non-unit-length normals starting
// at vertex 1 — but at 52 bytes, all 676 real vertices decode with a
// unit-length normal and no NaNs, and the vertex array lands almost
// exactly on the file's own header-given index-section offset (hdr[1]),
// with only a small (78-81 byte, varies slightly per file) real trailing
// gap this project hasn't identified yet. No real per-file flag
// distinguishing the two sizes has been found (an "unconfirmed uint32"
// field right before the vertex count doesn't correlate: observed values
// 12/5/0 on real 52-byte files and 92/0 on real 44-byte files — 0 appears
// in both), so detectVertexRecSize picks whichever real size makes every
// vertex's normal come out unit-length, the same self-validating technique
// already used for .m's two real per-vertex sizes (see
// server/internal/mapm's detectVertexSize).
var vertexRecSizeCandidates = [2]int{44, 52}

// Vertex is one mesh vertex. Position, Normal and UV are confirmed fields;
// each on-disk record has further trailing bytes (12 or 20, depending on
// the real per-file record size — see vertexRecSizeCandidates) not yet
// confirmed to have consistent per-vertex meaning (a real archive shows
// them varying on at least one vertex, e.g. differing from the constant
// 0xFFFFFFFF/0 seen elsewhere), so they're kept raw rather than
// mis-labeled.
type Vertex struct {
	Position [3]float32
	Normal   [3]float32
	UV       [2]float32
	Extra    []byte
}

// Mesh is a parsed .bms file.
type Mesh struct {
	Name         string
	MaterialName string
	Vertices     []Vertex
	// Indices is a flat triangle list; len(Indices) is always a multiple of 3.
	Indices   []uint16
	BoundsMin [3]float32
	BoundsMax [3]float32
}

// Parse parses a .bms file's raw bytes.
func Parse(data []byte) (*Mesh, error) {
	if len(data) < preambleEnd {
		return nil, errors.New("bms: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("bms: bad magic %q, want %q", data[0:magicLen], magic)
	}

	var hdr [numHeaderPtrs]uint32
	for i := range hdr {
		hdr[i] = binary.LittleEndian.Uint32(data[headerPtrsBase+i*4:])
	}

	off := preambleEnd
	name, off, err := readLenPrefixedString(data, off)
	if err != nil {
		return nil, fmt.Errorf("bms: reading name: %w", err)
	}
	materialName, off, err := readLenPrefixedString(data, off)
	if err != nil {
		return nil, fmt.Errorf("bms: reading material name: %w", err)
	}

	if off+8 > len(data) {
		return nil, errors.New("bms: truncated before vertex count")
	}
	// A u32 field of unconfirmed purpose (observed values 12, 92, 5, 0 — not
	// a reliable signal for anything, see vertexRecSizeCandidates) precedes
	// the vertex count.
	off += 4
	vertexCount := binary.LittleEndian.Uint32(data[off:])
	off += 4

	vertexRecSize, err := detectVertexRecSize(data, off, int(vertexCount), int(hdr[1]))
	if err != nil {
		return nil, err
	}

	vertexEnd := off + int(vertexCount)*vertexRecSize
	if vertexEnd > len(data) {
		return nil, fmt.Errorf("bms: vertex array (count=%d) runs past end of file", vertexCount)
	}
	vertices := make([]Vertex, vertexCount)
	for i := range vertices {
		rec := data[off+i*vertexRecSize : off+(i+1)*vertexRecSize]
		v := &vertices[i]
		for c := 0; c < 3; c++ {
			v.Position[c] = readFloat32(rec, c*4)
			v.Normal[c] = readFloat32(rec, 0x0c+c*4)
		}
		v.UV[0] = readFloat32(rec, 0x18)
		v.UV[1] = readFloat32(rec, 0x1c)
		v.Extra = append([]byte(nil), rec[0x20:vertexRecSize]...)
	}

	// Indices: located via the header's own pointer table (hdr[1]), not by
	// arithmetic from the vertex array's end, since header fields we don't
	// yet understand may affect what comes between the two.
	indexOff := int(hdr[1])
	if indexOff+4 > len(data) {
		return nil, errors.New("bms: index section offset (hdr[1]) out of range")
	}
	triCount := binary.LittleEndian.Uint32(data[indexOff:])
	indexStart := indexOff + 4
	indexEnd := indexStart + int(triCount)*indexRecSize
	if indexEnd > len(data) {
		return nil, fmt.Errorf("bms: index array (triangles=%d) runs past end of file", triCount)
	}
	indices := make([]uint16, triCount*3)
	for i := range indices {
		indices[i] = binary.LittleEndian.Uint16(data[indexStart+i*2:])
	}

	// Bounding box: 6 floats (min xyz, max xyz) at the header's hdr[4]
	// pointer.
	m := &Mesh{
		Name:         name,
		MaterialName: materialName,
		Vertices:     vertices,
		Indices:      indices,
	}
	bboxOff := int(hdr[4])
	if bboxOff+24 <= len(data) {
		for c := 0; c < 3; c++ {
			m.BoundsMin[c] = readFloat32(data, bboxOff+c*4)
			m.BoundsMax[c] = readFloat32(data, bboxOff+12+c*4)
		}
	}

	return m, nil
}

// detectVertexRecSize picks whichever real candidate size in
// vertexRecSizeCandidates makes every one of vertexCount real vertices
// starting at off decode a real, plausible unit-length normal (see
// vertexRecSizeCandidates's doc comment for the real evidence this is
// based on) — the same self-validating approach server/internal/mapm's
// detectVertexSize already uses for that format's own two real per-vertex
// sizes. Returns an error only if vertexCount doesn't fit in the file at
// either candidate size, or if no candidate is being tried because both
// would run past the file/index-section bound.
func detectVertexRecSize(data []byte, off, vertexCount, indexOff int) (int, error) {
	bestSize := 0
	bestBad := -1
	for _, size := range vertexRecSizeCandidates {
		end := off + vertexCount*size
		if end > len(data) || (indexOff > 0 && end > indexOff) {
			continue
		}
		bad := 0
		for i := 0; i < vertexCount; i++ {
			rec := data[off+i*size : off+(i+1)*size]
			var n [3]float32
			for c := 0; c < 3; c++ {
				n[c] = readFloat32(rec, 0x0c+c*4)
			}
			length := math.Sqrt(float64(n[0]*n[0] + n[1]*n[1] + n[2]*n[2]))
			if math.IsNaN(length) || length < 0.9 || length > 1.1 {
				bad++
			}
		}
		if bestBad == -1 || bad < bestBad {
			bestBad = bad
			bestSize = size
		}
	}
	if bestBad == -1 {
		return 0, fmt.Errorf("bms: vertex array (count=%d) doesn't fit in the file at any known real record size", vertexCount)
	}
	return bestSize, nil
}

func readLenPrefixedString(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before string length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n < 0 || off+n > len(data) {
		return "", off, fmt.Errorf("string length %d out of range", n)
	}
	return string(data[off : off+n]), off + n, nil
}

func readFloat32(b []byte, off int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(b[off:]))
}
