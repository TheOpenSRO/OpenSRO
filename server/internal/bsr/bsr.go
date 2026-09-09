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
	"strings"
)

const (
	magic       = "JMXVRES 0109"
	magicLen    = 12
	preambleEnd = 0x44 // fixed header size before the name string's length field (4 bytes shorter than .bms's own preamble)
	maxPathLen  = 512  // sanity bound for scanning; real paths are well under this

	// Section offset table in the header. Every real file checked
	// (characters, buildings and nature objects alike) has these four
	// pointing at the count word that starts each list.
	offPtrMaterial  = 0x0C
	offPtrMesh      = 0x10
	offPtrSkeleton  = 0x14
	offPtrAnimation = 0x18

	// offType holds the object type in its low uint16 — the game's own
	// classification, authored in the file, not inferred from the path or
	// from which order the fields happen to appear in.
	offType = 0x40

	TypeCharacter = 1
	TypeBuilding  = 2
	TypeNature    = 4

	// animationHeaderWords is the two words between the animation section
	// pointer and its count. Both observed identical (4096, then 0) in
	// every real file checked; their meaning isn't confirmed, so they are
	// skipped rather than interpreted.
	animationHeaderWords = 2
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

	// IsCharacter is set for TypeCharacter files — NPCs, monsters and the
	// player's own body. These are skinned models: the mesh pieces mean
	// nothing without the skeleton, so a caller should assemble them as a
	// character rather than placing them as rigid scenery.
	IsCharacter    bool
	SkeletonPath   string
	AnimationPaths []string
}

// AllMeshPaths returns every mesh piece, primary included, in file order —
// for callers that don't care which one the file happened to list first.
func (o *Object) AllMeshPaths() []string {
	out := make([]string, 0, 1+len(o.SubMeshPaths))
	if o.MeshPath != "" {
		out = append(out, o.MeshPath)
	}
	return append(out, o.SubMeshPaths...)
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

	// The header's section table is the authored answer, and it is used for
	// every object type — not just characters, as it was at first.
	//
	// Measured across a real Data.pk2's 8,539 .bsr files
	// (client/tools/sweep_bsr.gd): the table parses and chains for 7,978 of
	// them, and on a verified 1,500-file sample every mesh path it produces
	// resolves to a real file — zero unresolved. The forward scan below
	// returned a duplicated mesh for 2,787 files and a different mesh count
	// for 3,770, including objects where it found one piece and the table
	// found six. The 7% the table cannot read fall back to the scan.
	if sections, ok := parseSections(data); ok && len(sections.Meshes) > 0 {
		objType := int(binary.LittleEndian.Uint32(data[offType:]) & 0xFFFF)
		// A character with no skeleton is a contradiction — its pieces are
		// skin — so let it fall through to the scan instead.
		if objType != TypeCharacter || len(sections.Skeletons) > 0 {
			obj := &Object{
				Name:           name,
				MeshPath:       sections.Meshes[0],
				SubMeshPaths:   sections.Meshes[1:],
				AnimationPaths: sections.Animations,
			}
			if len(sections.Materials) > 0 {
				obj.MaterialPath = sections.Materials[0]
			}
			if len(sections.Skeletons) > 0 {
				obj.SkeletonPath = sections.Skeletons[0]
			}
			obj.IsCharacter = objType == TypeCharacter && obj.SkeletonPath != ""
			return obj, nil
		}
	}

	// The exact byte layout between the name and the mesh/material paths
	// isn't fully understood (a fixed-looking header field that should
	// point at the mesh path turned out not to, in at least one real
	// file) — so instead of trusting an offset, scan forward for the
	// first plausible length-prefixed path string. Real files were also
	// found to genuinely differ in *field order*: "building"-category
	// files (`res\bldg\...`) put the mesh path first, then the bounding
	// box, then the material path; "nature"-category files
	// (`res\nature\...`, e.g. vegetation/scatter objects) put the
	// bounding box and material path first, with the mesh path last —
	// see docs/protocol/BSR_FORMAT.md. Scanning independently for the
	// first string ending in ".bms" and the first ending in ".bmt" (not
	// "whichever plausible string comes first, unconditionally called
	// the mesh path") finds the right field either way, since it doesn't
	// assume an order.
	meshOff, meshFound := scanForPathStringWithSuffix(data, off, ".bms")
	matOff, matFound := scanForPathStringWithSuffix(data, off, ".bmt")
	if !matFound {
		return nil, errors.New("bsr: couldn't locate material path")
	}
	materialPath, matEnd, err := readLenPrefixedString(data, matOff)
	if err != nil {
		return nil, fmt.Errorf("bsr: reading material path: %w", err)
	}

	if !meshFound {
		// A real, genuine mesh-less variant, not a parse failure: real
		// "*_particle.bsr" files (e.g. wreck_sship_particle.bsr, placed
		// over 1,200 times combined across a real client's map data —
		// found auditing this project's own full real object catalog,
		// 2026-08-25) carry a real material plus one or more real .efp
		// particle-effect references instead of any .bms mesh at all —
		// they're invisible particle-emitter markers, not scenery with a
		// missing/corrupt mesh. Returning a real Object with an empty
		// MeshPath (same "empty is a real, valid value" treatment
		// MaterialPath already gets below) lets a caller render just the
		// real particle effect (once this project has a real .efp
		// renderer) or skip the object's visual entirely, instead of
		// treating every one of these as a hard failure.
		return &Object{Name: name, MaterialPath: materialPath}, nil
	}
	meshPath, meshEnd, err := readLenPrefixedString(data, meshOff)
	if err != nil {
		return nil, fmt.Errorf("bsr: reading mesh path: %w", err)
	}

	obj := &Object{Name: name, MeshPath: meshPath, MaterialPath: materialPath}

	if meshOff >= matOff {
		// Nature-category order (material, then mesh) — confirmed real,
		// but nothing past the mesh path is understood for this layout
		// yet (no confirmed bounding-box position or sub-mesh-list
		// convention), so this is where a real file's real data ends as
		// far as this reader is concerned. Not guessed at.
		return obj, nil
	}

	// Building-category order (mesh, then material): best-effort bounding
	// box, observed as 6 floats (min xyz, max xyz) at the very start of
	// the gap between the mesh path and the material path in most real
	// files checked — but not confirmed in all of them, so this is
	// skipped rather than guessed at when the gap is too short.
	if gap := matOff - meshEnd; gap >= 24 {
		for c := 0; c < 3; c++ {
			obj.BoundsMin[c] = readFloat32(data, meshEnd+c*4)
			obj.BoundsMax[c] = readFloat32(data, meshEnd+12+c*4)
		}
		obj.HasBounds = true
	}

	off = matEnd
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
	// A real, larger multi-piece building (2026-08-23: found live-testing
	// real Jangan palace buildings) can have its declared subCount not
	// exactly match how many further length-prefixed strings are still
	// real path-shaped data -- the exact real cause isn't confirmed (a
	// real trailing per-piece field this project's simpler samples never
	// had enough pieces to expose, most likely). Keep whatever real
	// sub-mesh paths parsed successfully and stop, rather than discarding
	// the already-confirmed-real MeshPath/MaterialPath along with them
	// over one bad trailing sub-piece.
	for i := uint32(0); i < subCount; i++ {
		var path string
		path, off, err = readLenPrefixedString(data, off)
		if err != nil {
			break
		}
		// A real sub-mesh path that isn't a plausible ".bms" path
		// (2026-08-23: found live-testing real Jangan-adjacent trees) is
		// never a real, usable sub-mesh reference -- no real file has an
		// empty name or a single stray byte like "6" as a mesh path. It
		// means the true real sub-mesh list already ended and this read
		// has spilled into the file's own trailing boilerplate, which can
		// contain real byte sequences that happen to parse as a
		// valid-looking but wrong length-prefixed string rather than
		// failing outright (an exactly empty string from `tre_bank02.bsr`;
		// a single real byte "6" from `tre_maple01.bsr`). Stop here, same
		// as a real read failure.
		if !isPlausiblePath([]byte(path)) || !strings.HasSuffix(strings.ToLower(path), ".bms") {
			break
		}
		obj.SubMeshPaths = append(obj.SubMeshPaths, path)
	}

	return obj, nil
}

// scanForPathStringWithSuffix looks for the next plausible length-prefixed
// path string starting at or after off whose content ends with suffix
// (case-insensitive — real paths use inconsistent casing throughout this
// project's data), returning its offset. Filtering by suffix (rather than
// accepting the first plausible string unconditionally) is what lets one
// scan correctly find the mesh path or material path regardless of which
// order a real file puts them in.
func scanForPathStringWithSuffix(data []byte, off int, suffix string) (int, bool) {
	for pos := off; pos+4 <= len(data); pos++ {
		n := int(binary.LittleEndian.Uint32(data[pos:]))
		if n <= 0 || n > maxPathLen || pos+4+n > len(data) {
			continue
		}
		candidate := data[pos+4 : pos+4+n]
		if isPlausiblePath(candidate) && strings.HasSuffix(strings.ToLower(string(candidate)), suffix) {
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

// Sections are the four count-prefixed lists the header's offset table
// addresses.
type Sections struct {
	Materials  []string
	Meshes     []string
	Animations []string
	Skeletons  []string
}

// parseSections reads a file's four sections through the header's offset
// table, without deciding what to do with them.
//
// Nothing here is searched for: each section starts with a count word at
// the offset the header names, and the entries that follow abut one
// another exactly, so reading one section leaves the cursor on the next
// section's first byte. That chaining is what makes the layout checkable
// rather than guessed — every section is verified to end exactly where the
// header says the next one begins, and any mismatch reports false so the
// caller can fall back to the forward scan.
func parseSections(data []byte) (*Sections, bool) {
	ptrMaterial := int(binary.LittleEndian.Uint32(data[offPtrMaterial:]))
	ptrMesh := int(binary.LittleEndian.Uint32(data[offPtrMesh:]))
	ptrSkeleton := int(binary.LittleEndian.Uint32(data[offPtrSkeleton:]))
	ptrAnimation := int(binary.LittleEndian.Uint32(data[offPtrAnimation:]))
	for _, ptr := range []int{ptrMaterial, ptrMesh, ptrSkeleton, ptrAnimation} {
		if ptr < preambleEnd || ptr+4 > len(data) {
			return nil, false
		}
	}

	// Materials: a count, then one uint32 (unconfirmed — an index or flag,
	// always small) in front of each path.
	materials, end, ok := readStringList(data, ptrMaterial, ".bmt", 4)
	if !ok || len(materials) == 0 || end != ptrMesh {
		return nil, false
	}

	// Meshes: a count, then the paths back to back with no per-entry field.
	meshes, end, ok := readStringList(data, ptrMesh, ".bms", 0)
	if !ok || len(meshes) == 0 || end != ptrAnimation {
		return nil, false
	}

	out := &Sections{Materials: materials, Meshes: meshes}

	// Animations sit behind two unconfirmed words, then the usual count.
	if anims, end, ok := readStringList(data, ptrAnimation+animationHeaderWords*4, ".ban", 0); ok && end == ptrSkeleton {
		out.Animations = anims
	}
	if skeletons, _, ok := readStringList(data, ptrSkeleton, ".bsk", 0); ok {
		out.Skeletons = skeletons
	}
	return out, true
}

// readStringList reads a count-prefixed list of length-prefixed path
// strings at off, each entry preceded by leadBytes of unread per-entry
// data. Every path must end with suffix, which is what turns "these bytes
// parsed" into "these bytes are the list the header promised". It returns
// the paths and the offset just past the list.
func readStringList(data []byte, off int, suffix string, leadBytes int) ([]string, int, bool) {
	if off+4 > len(data) {
		return nil, 0, false
	}
	count := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if count <= 0 || count > 1000 {
		return nil, 0, false
	}
	paths := make([]string, 0, count)
	for i := 0; i < count; i++ {
		off += leadBytes
		path, next, err := readLenPrefixedString(data, off)
		if err != nil {
			return nil, 0, false
		}
		if !isPlausiblePath([]byte(path)) || !strings.HasSuffix(strings.ToLower(path), suffix) {
			return nil, 0, false
		}
		paths = append(paths, path)
		off = next
	}
	return paths, off, true
}
