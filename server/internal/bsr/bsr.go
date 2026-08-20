// Package bsr parses .bsr (JMXVRES) "static object" resource files — a
// composite descriptor that assembles one or more .bms (mesh) files plus a
// .bmt (material) file, by relative path, into one placeable object. See
// docs/protocol/BSR_FORMAT.md for the on-disk layout, verified empirically
// against real extracted .bsr files and cross-checked against the real
// loader in sro_client.exe (which validates the magic byte-for-byte). No
// decompiler output is stored in this repo, only the resulting facts about
// the container format.
//
// This package never writes .bsr files; it only parses ones a caller
// already has (typically extracted from a pk2 archive via
// server/internal/pk2).
package bsr

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	magic       = "JMXVRES 0109"
	magicLen    = 12
	preambleEnd = 0x44 // fixed header size before the name string's length field (4 bytes shorter than .bms's own preamble)
	maxPathLen  = 512  // sanity bound for scanning; real paths are well under this
)

// Object is a parsed .bsr file.
type Object struct {
	Name         string
	MeshPath     string
	MaterialPath string
	// SubMeshPaths are additional .bms paths beyond MeshPath (e.g. a
	// building's separate wall/column/stair/tile pieces).
	SubMeshPaths []string
	// HasBounds is false if the bounding box couldn't be confidently
	// located (its exact byte offset varies slightly between real files
	// in ways not fully understood yet — see docs/protocol/BSR_FORMAT.md).
	HasBounds bool
	BoundsMin [3]float32
	BoundsMax [3]float32
}

// Parse parses a .bsr file's raw bytes.
func Parse(data []byte) (*Object, error) {
	if len(data) < preambleEnd {
		return nil, errors.New("bsr: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("bsr: bad magic %q, want %q", data[0:magicLen], magic)
	}

	off := preambleEnd
	name, off, err := readLenPrefixedString(data, off)
	if err != nil {
		return nil, fmt.Errorf("bsr: reading name: %w", err)
	}

	// The exact byte layout between the name and the mesh path isn't fully
	// understood (a fixed-looking header field that should point at the
	// mesh path turned out not to, in at least one real file) — so instead
	// of trusting an offset, scan forward for the first plausible
	// length-prefixed path string. This is the same technique that found
	// it correctly in every real .bsr file this was tested against.
	meshOff, ok := scanForPathString(data, off)
	if !ok {
		return nil, errors.New("bsr: couldn't locate mesh path")
	}
	meshPath, next, err := readLenPrefixedString(data, meshOff)
	if err != nil {
		return nil, fmt.Errorf("bsr: reading mesh path: %w", err)
	}

	obj := &Object{Name: name, MeshPath: meshPath}

	matOff, ok := scanForPathString(data, next)
	if !ok {
		return nil, errors.New("bsr: couldn't locate material path")
	}
	// Best-effort bounding box: observed as 6 floats (min xyz, max xyz) at
	// the very start of the gap between the mesh path and the material
	// path, in most real files checked — but not confirmed in all of them,
	// so this is skipped rather than guessed at when the gap is too short.
	if gap := matOff - next; gap >= 24 {
		for c := 0; c < 3; c++ {
			obj.BoundsMin[c] = readFloat32(data, next+c*4)
			obj.BoundsMax[c] = readFloat32(data, next+12+c*4)
		}
		obj.HasBounds = true
	}

	materialPath, off, err := readLenPrefixedString(data, matOff)
	if err != nil {
		return nil, fmt.Errorf("bsr: reading material path: %w", err)
	}
	obj.MaterialPath = materialPath

	if off+4 > len(data) {
		// No sub-mesh count/list present; a single-piece object.
		return obj, nil
	}
	subCount := binary.LittleEndian.Uint32(data[off:])
	off += 4
	if subCount > 1000 {
		// Implausible; treat as "no sub-mesh list" rather than erroring,
		// since not every .bsr necessarily has this trailing section.
		return obj, nil
	}
	for i := uint32(0); i < subCount; i++ {
		var path string
		path, off, err = readLenPrefixedString(data, off)
		if err != nil {
			return nil, fmt.Errorf("bsr: reading sub-mesh path %d/%d: %w", i+1, subCount, err)
		}
		obj.SubMeshPaths = append(obj.SubMeshPaths, path)
	}

	return obj, nil
}

// scanForPathString looks for the next plausible length-prefixed path
// string starting at or after off, returning its offset.
func scanForPathString(data []byte, off int) (int, bool) {
	for pos := off; pos+4 <= len(data); pos++ {
		n := int(binary.LittleEndian.Uint32(data[pos:]))
		if n <= 0 || n > maxPathLen || pos+4+n > len(data) {
			continue
		}
		if isPlausiblePath(data[pos+4 : pos+4+n]) {
			return pos, true
		}
	}
	return 0, false
}

func isPlausiblePath(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, c := range b {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '\\' || c == '.' || c == '_' || c == '-' || c == ' ':
		default:
			return false
		}
	}
	return true
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
