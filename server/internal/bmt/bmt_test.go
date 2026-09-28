package bmt

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"math"
	"testing"
)

// buildSyntheticMaterial writes a minimal, synthetic decompressed
// .bmt-shaped buffer (never real game data) matching the layout confirmed
// against real files: see docs/protocol/BMT_FORMAT.md. Then zlib-compresses
// it and prepends the 4-byte decompressed-size header, matching the real
// on-disk format.
func buildSyntheticMaterialBytes(layers []Layer) []byte {
	var dec []byte
	dec = append(dec, []byte(magic)...)
	dec = appendU32(dec, uint32(len(layers)))
	for _, l := range layers {
		dec = appendLenPrefixed(dec, l.Name)
		dec = appendVec4(dec, l.Ambient)
		dec = appendVec4(dec, l.Diffuse)
		dec = appendVec4(dec, l.Specular)
		dec = appendVec4(dec, l.Emissive)
		dec = appendF32(dec, l.Power)
		dec = appendU32(dec, l.Unknown)
		dec = appendLenPrefixed(dec, l.TexturePath)
		// A few bytes of trailer, matching the non-4-byte-aligned gap
		// observed between layers in real files.
		dec = append(dec, 0x20, 0x08, 0x00)
	}
	return dec
}

func buildSyntheticMaterial(t *testing.T, layers []Layer) []byte {
	t.Helper()

	dec := buildSyntheticMaterialBytes(layers)

	var zbuf bytes.Buffer
	zw := zlib.NewWriter(&zbuf)
	if _, err := zw.Write(dec); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}

	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, uint32(len(dec)))
	out = append(out, zbuf.Bytes()...)
	return out
}

func appendU32(b []byte, v uint32) []byte {
	var buf [4]byte
	binary.LittleEndian.PutUint32(buf[:], v)
	return append(b, buf[:]...)
}

func appendF32(b []byte, v float32) []byte {
	return appendU32(b, math.Float32bits(v))
}

func appendVec4(b []byte, v [4]float32) []byte {
	for _, f := range v {
		b = appendF32(b, f)
	}
	return b
}

func appendLenPrefixed(b []byte, s string) []byte {
	b = appendU32(b, uint32(len(s)))
	return append(b, []byte(s)...)
}

func TestParseSingleLayer(t *testing.T) {
	data := buildSyntheticMaterial(t, []Layer{
		{
			Name:        "test_material",
			Ambient:     [4]float32{0.5, 0.5, 0.5, 1},
			Diffuse:     [4]float32{0.5, 0.5, 0.5, 1},
			Specular:    [4]float32{0.9, 0.9, 0.9, 1},
			Emissive:    [4]float32{0, 0, 0, 1},
			Power:       0,
			Unknown:     833,
			TexturePath: "test_material.ddj",
		},
	})

	m, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(m.Layers) != 1 {
		t.Fatalf("expected 1 layer, got %d", len(m.Layers))
	}
	l := m.Layers[0]
	if l.Name != "test_material" || l.TexturePath != "test_material.ddj" {
		t.Fatalf("unexpected layer: %+v", l)
	}
	if l.Diffuse != [4]float32{0.5, 0.5, 0.5, 1} {
		t.Fatalf("unexpected diffuse: %v", l.Diffuse)
	}
}

func TestParseMultiLayer(t *testing.T) {
	data := buildSyntheticMaterial(t, []Layer{
		{Name: "base", TexturePath: "base.ddj", Diffuse: [4]float32{1, 1, 1, 1}},
		{Name: "decal", TexturePath: "decal.ddj", Diffuse: [4]float32{1, 1, 1, 1}},
	})

	m, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(m.Layers) != 2 {
		t.Fatalf("expected 2 layers, got %d", len(m.Layers))
	}
	if m.Layers[1].Name != "decal" || m.Layers[1].TexturePath != "decal.ddj" {
		t.Fatalf("unexpected second layer: %+v", m.Layers[1])
	}
}

func TestParseLayerWithoutTexture(t *testing.T) {
	data := buildSyntheticMaterial(t, []Layer{
		{Name: "tint_only", Diffuse: [4]float32{1, 0, 0, 1}},
	})

	m, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(m.Layers) != 1 || m.Layers[0].TexturePath != "" {
		t.Fatalf("expected 1 layer with no texture, got %+v", m.Layers)
	}
}

// TestParseUncompressedVariant covers the real, uncompressed on-disk
// variant found in a live client Data tree (Prim/Mtrl/Char/China/man/*.bmt)
// -- confirmed across 3 real files (chinaman_warrior.bmt, chinaman_bogy.bmt,
// chinaman_monk.bmt), as opposed to the zlib-wrapped variant found in a
// patch-staging tree, which every other test in this file covers.
func TestParseUncompressedVariant(t *testing.T) {
	data := buildSyntheticMaterialBytes([]Layer{
		{Name: "chinaman_body", TexturePath: "chinaman_warrior_body.ddj", Diffuse: [4]float32{1, 1, 1, 1}},
		{Name: "chinaman_hair", TexturePath: "chinaman_warrior_hair.ddj", Diffuse: [4]float32{1, 1, 1, 1}},
	})

	m, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(m.Layers) != 2 {
		t.Fatalf("expected 2 layers, got %d", len(m.Layers))
	}
	if m.Layers[0].Name != "chinaman_body" || m.Layers[0].TexturePath != "chinaman_warrior_body.ddj" {
		t.Fatalf("unexpected first layer: %+v", m.Layers[0])
	}
	if m.Layers[1].Name != "chinaman_hair" || m.Layers[1].TexturePath != "chinaman_warrior_hair.ddj" {
		t.Fatalf("unexpected second layer: %+v", m.Layers[1])
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	var zbuf bytes.Buffer
	zw := zlib.NewWriter(&zbuf)
	zw.Write([]byte("NOT A REAL BMT HEADER!!"))
	zw.Close()

	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, 23)
	out = append(out, zbuf.Bytes()...)

	if _, err := Parse(out); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsNonZlibData(t *testing.T) {
	if _, err := Parse([]byte{0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF}); err == nil {
		t.Fatal("expected error parsing non-zlib data, got nil")
	}
}

// TestParseLayerTrailer is round 625's: a layer ends with seven bytes after
// its texture path — a uint32 and three bytes, READ from CPrimMtrl
// FUN_00bf91b0 — and the next layer's name starts right after them. The
// trailer here is a uint32 of 3 and the bytes "xyz", itself a plausible
// length-prefixed name, which the forward scan used before this round stops
// on: it read a second layer called "xyz" with a garbage flag word.
func TestParseLayerTrailer(t *testing.T) {
	var dec []byte
	dec = append(dec, []byte(magic)...)
	dec = appendU32(dec, 2)
	for _, l := range []Layer{{Name: "tre_leaf", Unknown: 0x341, TexturePath: "tre_leaf.ddj"}, {Name: "tre_bark", Unknown: 0x140, TexturePath: "tre_bark.ddj"}} {
		dec = appendLenPrefixed(dec, l.Name)
		for i := 0; i < 4; i++ {
			dec = appendVec4(dec, [4]float32{1, 1, 1, 1})
		}
		dec = appendF32(dec, 0)
		dec = appendU32(dec, l.Unknown)
		dec = appendLenPrefixed(dec, l.TexturePath)
		dec = appendU32(dec, 3)
		dec = append(dec, 'x', 'y', 'z')
	}
	m, err := Parse(dec)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Layers) != 2 {
		t.Fatalf("layers = %d, want 2", len(m.Layers))
	}
	if got := m.Layers[1]; got.Name != "tre_bark" || got.Unknown != 0x140 || got.TexturePath != "tre_bark.ddj" {
		t.Errorf("second layer = %q 0x%x %q, want tre_bark 0x140 tre_bark.ddj", got.Name, got.Unknown, got.TexturePath)
	}
	if got := m.Layers[0]; got.TextureWord != 3 || string(got.TextureBytes[:]) != "xyz" {
		t.Errorf("trailer = %d %q, want 3 \"xyz\"", got.TextureWord, got.TextureBytes[:])
	}
}
