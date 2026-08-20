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
	vertexRecSize  = 44
	indexRecSize   = 6 // 3x uint16 per triangle
	numHeaderPtrs  = 6
	headerPtrsBase = 0x10
)

// Vertex is one mesh vertex. Position, Normal and UV are confirmed fields;
// each 44-byte on-disk record has 12 further bytes (offsets 0x20-0x2B) not
// yet confirmed to have consistent per-vertex meaning (a real archive shows
// them varying on at least one vertex, e.g. differing from the constant
// 0xFFFFFFFF/0 seen elsewhere), so they're kept raw rather than
// mis-labeled.
type Vertex struct {
	Position [3]float32
	Normal   [3]float32
	UV       [2]float32
	Extra    [12]byte
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
	// A u32 field of unconfirmed purpose (observed value 1) precedes the
	// vertex count.
	off += 4
	vertexCount := binary.LittleEndian.Uint32(data[off:])
	off += 4

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
		copy(v.Extra[:], rec[0x20:0x2c])
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
