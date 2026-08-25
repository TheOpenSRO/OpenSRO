package bsr

import (
	"encoding/binary"
	"math"
	"testing"
)

// buildSyntheticObject writes a minimal, synthetic .bsr-shaped buffer
// (never real game data) matching the layout confirmed against real
// archives: see docs/protocol/BSR_FORMAT.md. Mirrors the two real files
// that parsed cleanly (a name, a mesh path, a 6-float bounding box, a
// material path, then a count-prefixed list of further mesh paths).
func buildSyntheticObject(t *testing.T, name, meshPath, materialPath string, subPaths []string) []byte {
	t.Helper()

	buf := make([]byte, preambleEnd)
	copy(buf, magic)

	appendLenPrefixed := func(b []byte, s string) []byte {
		lp := make([]byte, 4+len(s))
		binary.LittleEndian.PutUint32(lp, uint32(len(s)))
		copy(lp[4:], s)
		return append(b, lp...)
	}
	buf = appendLenPrefixed(buf, name)

	// Two unconfirmed u32 fields (observed values 10, 2) plus reserved
	// padding, matching what real files were seen to have before the mesh
	// path.
	buf = binary.LittleEndian.AppendUint32(buf, 10)
	buf = binary.LittleEndian.AppendUint32(buf, 2)
	buf = append(buf, make([]byte, 40)...)

	buf = appendLenPrefixed(buf, meshPath)

	// Bounding box (6 floats) + the constant-looking sentinel/flag tail
	// observed in every real file checked.
	for _, f := range []float32{-5, 0, -5, 5, 10, 5} {
		buf = binary.LittleEndian.AppendUint32(buf, float32bits(f))
	}
	buf = append(buf, make([]byte, 36)...)

	buf = appendLenPrefixed(buf, materialPath)

	buf = binary.LittleEndian.AppendUint32(buf, uint32(len(subPaths)))
	for _, p := range subPaths {
		buf = appendLenPrefixed(buf, p)
	}

	return buf
}

func float32bits(f float32) uint32 {
	return math.Float32bits(f)
}

func TestParse(t *testing.T) {
	data := buildSyntheticObject(t, "TestObj01",
		`prim\mesh\bldg\testobj01.bms`,
		`prim\mtrl\bldg\testobj01.bmt`,
		[]string{`prim\mesh\bldg\testobj01_part2.bms`, `prim\mesh\bldg\testobj01_part3.bms`})

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	if obj.Name != "TestObj01" {
		t.Fatalf("unexpected name: %q", obj.Name)
	}
	if obj.MeshPath != `prim\mesh\bldg\testobj01.bms` {
		t.Fatalf("unexpected mesh path: %q", obj.MeshPath)
	}
	if obj.MaterialPath != `prim\mtrl\bldg\testobj01.bmt` {
		t.Fatalf("unexpected material path: %q", obj.MaterialPath)
	}
	if !obj.HasBounds {
		t.Fatal("expected bounds to be located")
	}
	if obj.BoundsMin != [3]float32{-5, 0, -5} || obj.BoundsMax != [3]float32{5, 10, 5} {
		t.Fatalf("unexpected bounds: min=%v max=%v", obj.BoundsMin, obj.BoundsMax)
	}
	if len(obj.SubMeshPaths) != 2 {
		t.Fatalf("expected 2 sub-mesh paths, got %d: %v", len(obj.SubMeshPaths), obj.SubMeshPaths)
	}
	if obj.SubMeshPaths[0] != `prim\mesh\bldg\testobj01_part2.bms` {
		t.Fatalf("unexpected sub-mesh path[0]: %q", obj.SubMeshPaths[0])
	}
}

// TestParseSubMeshCountOverdeclared covers a real failure mode found
// live-testing real Jangan palace buildings (2026-08-23): a declared
// sub-mesh count larger than how many further real path strings are
// actually present. Parse must return the real primary mesh/material data
// plus whatever real sub-mesh paths did parse, not fail the whole object.
func TestParseSubMeshCountOverdeclared(t *testing.T) {
	data := buildSyntheticObject(t, "TestObj02",
		`prim\mesh\bldg\testobj02.bms`,
		`prim\mtrl\bldg\testobj02.bmt`,
		[]string{`prim\mesh\bldg\testobj02_part2.bms`})
	// Overwrite the declared sub-mesh count (the uint32 right before the
	// one real sub-mesh path) to claim 3 real paths follow when only 1
	// actually does.
	subCountOff := len(data) - (4 + len(`prim\mesh\bldg\testobj02_part2.bms`)) - 4
	binary.LittleEndian.PutUint32(data[subCountOff:], 3)

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v, want a graceful partial result instead of an error", err)
	}
	if obj.MeshPath != `prim\mesh\bldg\testobj02.bms` {
		t.Fatalf("unexpected mesh path: %q", obj.MeshPath)
	}
	if len(obj.SubMeshPaths) != 1 {
		t.Fatalf("expected 1 real sub-mesh path to survive, got %d: %v", len(obj.SubMeshPaths), obj.SubMeshPaths)
	}
}

// TestParseStopsAtEmptySubMeshPath covers a real failure mode found
// live-testing a real Jangan-adjacent tree (2026-08-23, `tre_bank02.bsr`):
// a real zero-length sub-mesh path, which is never a real usable reference
// (it means the real sub-mesh list already ended and this read spilled
// into the file's own trailing boilerplate). Parse must stop there rather
// than recording a sub-mesh path nothing can ever resolve.
func TestParseStopsAtEmptySubMeshPath(t *testing.T) {
	data := buildSyntheticObject(t, "TestObj03",
		`prim\mesh\bldg\testobj03.bms`,
		`prim\mtrl\bldg\testobj03.bmt`,
		[]string{`prim\mesh\bldg\testobj03_part2.bms`, ""})

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(obj.SubMeshPaths) != 1 {
		t.Fatalf("expected 1 real sub-mesh path (empty one dropped), got %d: %v", len(obj.SubMeshPaths), obj.SubMeshPaths)
	}
	if obj.SubMeshPaths[0] != `prim\mesh\bldg\testobj03_part2.bms` {
		t.Fatalf("unexpected sub-mesh path[0]: %q", obj.SubMeshPaths[0])
	}
}

// TestParseStopsAtGarbageSubMeshPath covers a second real shape of the same
// real failure mode (2026-08-23, `tre_maple01.bsr`): a real *non-empty*
// garbage sub-mesh path (a single stray real byte, "6", not a plausible
// ".bms" path) read from the file's own trailing boilerplate. Parse must
// stop there rather than recording it, same as the empty-path case.
func TestParseStopsAtGarbageSubMeshPath(t *testing.T) {
	data := buildSyntheticObject(t, "TestObj04",
		`prim\mesh\bldg\testobj04.bms`,
		`prim\mtrl\bldg\testobj04.bmt`,
		[]string{`prim\mesh\bldg\testobj04_part2.bms`, "6"})

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(obj.SubMeshPaths) != 1 {
		t.Fatalf("expected 1 real sub-mesh path (garbage one dropped), got %d: %v", len(obj.SubMeshPaths), obj.SubMeshPaths)
	}
	if obj.SubMeshPaths[0] != `prim\mesh\bldg\testobj04_part2.bms` {
		t.Fatalf("unexpected sub-mesh path[0]: %q", obj.SubMeshPaths[0])
	}
}

// buildSyntheticNatureObject writes a minimal, synthetic .bsr-shaped
// buffer (never real game data) matching the real "nature"-category field
// order confirmed against a real center_asia_plant01_01.bsr: name, two
// unconfirmed u32 fields + padding, bounding box + sentinel tail,
// material path, a count field, then the mesh path last -- the opposite
// order from the "building"-category layout buildSyntheticObject models.
// See docs/protocol/BSR_FORMAT.md.
func buildSyntheticNatureObject(t *testing.T, name, materialPath, meshPath string) []byte {
	t.Helper()

	buf := make([]byte, preambleEnd)
	copy(buf, magic)

	appendLenPrefixed := func(b []byte, s string) []byte {
		lp := make([]byte, 4+len(s))
		binary.LittleEndian.PutUint32(lp, uint32(len(s)))
		copy(lp[4:], s)
		return append(b, lp...)
	}
	buf = appendLenPrefixed(buf, name)

	buf = binary.LittleEndian.AppendUint32(buf, 11)
	buf = binary.LittleEndian.AppendUint32(buf, 2)
	buf = append(buf, make([]byte, 44)...)

	// Bounding box (6 floats) + sentinel/flag tail, real-shaped but before
	// either path this time.
	for _, f := range []float32{-1, 0, -1, 1, 2, 1} {
		buf = binary.LittleEndian.AppendUint32(buf, float32bits(f))
	}
	buf = append(buf, make([]byte, 36)...)

	buf = appendLenPrefixed(buf, materialPath)
	buf = binary.LittleEndian.AppendUint32(buf, 1) // real files show a "1" field here
	buf = appendLenPrefixed(buf, meshPath)

	return buf
}

func TestParseNatureCategoryOrder(t *testing.T) {
	data := buildSyntheticNatureObject(t, "test_plant01",
		`prim\mtrl\nature\test_plant01.bmt`,
		`prim\mesh\nature\test_plant01.bms`)

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if obj.MeshPath != `prim\mesh\nature\test_plant01.bms` {
		t.Fatalf("unexpected mesh path: %q", obj.MeshPath)
	}
	if obj.MaterialPath != `prim\mtrl\nature\test_plant01.bmt` {
		t.Fatalf("unexpected material path: %q", obj.MaterialPath)
	}
	if obj.HasBounds {
		t.Fatal("expected HasBounds false for the nature-category order (position not confirmed)")
	}
	if len(obj.SubMeshPaths) != 0 {
		t.Fatalf("expected no sub-mesh paths for the nature-category order, got %v", obj.SubMeshPaths)
	}
}

// buildSyntheticParticleObject writes a minimal, synthetic mesh-less
// .bsr-shaped buffer (never real game data): a real name and a real
// material path, with no real .bms mesh path anywhere -- the real shape of
// "*_particle.bsr" objects (e.g. wreck_sship_particle.bsr, found auditing
// this project's own full real object catalog, 2026-08-25), which carry a
// real material plus real .efp particle-effect references instead of any
// mesh at all.
func buildSyntheticParticleObject(t *testing.T, name, materialPath string) []byte {
	t.Helper()

	buf := make([]byte, preambleEnd)
	copy(buf, magic)

	appendLenPrefixed := func(b []byte, s string) []byte {
		lp := make([]byte, 4+len(s))
		binary.LittleEndian.PutUint32(lp, uint32(len(s)))
		copy(lp[4:], s)
		return append(b, lp...)
	}
	buf = appendLenPrefixed(buf, name)
	buf = append(buf, make([]byte, 40)...)
	buf = appendLenPrefixed(buf, materialPath)
	// A real trailing .efp particle-effect reference or two would follow
	// in a real file -- irrelevant to Parse, which doesn't look past the
	// material path when no mesh path exists.
	return buf
}

func TestParseMeshlessParticleObject(t *testing.T) {
	data := buildSyntheticParticleObject(t, "wreck_sship_particle", `prim\mtrl\dun\property\wreck\wreck_float.bmt`)

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if obj.Name != "wreck_sship_particle" {
		t.Fatalf("unexpected name: %q", obj.Name)
	}
	if obj.MeshPath != "" {
		t.Fatalf("expected empty mesh path for a real mesh-less particle object, got %q", obj.MeshPath)
	}
	if obj.MaterialPath != `prim\mtrl\dun\property\wreck\wreck_float.bmt` {
		t.Fatalf("unexpected material path: %q", obj.MaterialPath)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, preambleEnd)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseNoSubMeshes(t *testing.T) {
	data := buildSyntheticObject(t, "Simple01", `prim\mesh\simple01.bms`, `prim\mtrl\simple01.bmt`, nil)

	obj, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(obj.SubMeshPaths) != 0 {
		t.Fatalf("expected no sub-mesh paths, got %v", obj.SubMeshPaths)
	}
}
