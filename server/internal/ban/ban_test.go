package ban

import (
	"encoding/binary"
	"math"
	"testing"
)

// buildSyntheticAnimation writes a minimal, synthetic .ban-shaped buffer
// (never real game data) matching the layout confirmed against two real
// files (each of which parsed to exactly its own byte length, zero bytes
// left over): see docs/protocol/BAN_FORMAT.md.
func buildSyntheticAnimation(t *testing.T, name string, bones []Bone) []byte {
	t.Helper()

	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = appendU32(buf, 0) // unconfirmed, observed 0
	buf = appendU32(buf, 0) // unconfirmed, observed 0
	buf = appendLenPrefixed(buf, name)
	buf = appendU32(buf, 666) // Unknown1
	buf = appendU32(buf, 30)  // Unknown2
	buf = appendU32(buf, 1)   // Unknown3

	// Offset table: 3 entries of unconfirmed content.
	buf = appendU32(buf, 3)
	buf = appendU32(buf, 0)
	buf = appendU32(buf, 0)
	buf = appendU32(buf, 0)

	buf = appendU32(buf, uint32(len(bones)))
	for _, b := range bones {
		buf = appendLenPrefixed(buf, b.Name)
		buf = appendU32(buf, uint32(len(b.Keyframes)))
		for _, kf := range b.Keyframes {
			for _, f := range kf.Rotation {
				buf = appendF32(buf, f)
			}
			for _, f := range kf.Position {
				buf = appendF32(buf, f)
			}
		}
	}
	return buf
}

func appendU32(b []byte, v uint32) []byte {
	var buf [4]byte
	binary.LittleEndian.PutUint32(buf[:], v)
	return append(b, buf[:]...)
}

func appendF32(b []byte, v float32) []byte {
	return appendU32(b, math.Float32bits(v))
}

func appendLenPrefixed(b []byte, s string) []byte {
	b = appendU32(b, uint32(len(s)))
	return append(b, []byte(s)...)
}

func TestParseSingleBone(t *testing.T) {
	data := buildSyntheticAnimation(t, "test_spin", []Bone{
		{
			Name: "Bone01",
			Keyframes: []Keyframe{
				{Rotation: [4]float32{0, 0, 0, 1}, Position: [3]float32{0, 0, 0}},
				{Rotation: [4]float32{0.7071068, 0, 0, 0.7071068}, Position: [3]float32{1, 2, 3}},
			},
		},
	})

	a, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if a.Name != "test_spin" {
		t.Fatalf("unexpected name: %q", a.Name)
	}
	if a.Unknown1 != 666 || a.Unknown2 != 30 || a.Unknown3 != 1 {
		t.Fatalf("unexpected header fields: %+v", a)
	}
	if len(a.Bones) != 1 {
		t.Fatalf("expected 1 bone, got %d", len(a.Bones))
	}
	b := a.Bones[0]
	if b.Name != "Bone01" || len(b.Keyframes) != 2 {
		t.Fatalf("unexpected bone: %+v", b)
	}
	if b.Keyframes[1].Position != [3]float32{1, 2, 3} {
		t.Fatalf("unexpected keyframe 1 position: %v", b.Keyframes[1].Position)
	}
}

func TestParseMultiBone(t *testing.T) {
	data := buildSyntheticAnimation(t, "test_walk", []Bone{
		{Name: "Root", Keyframes: []Keyframe{{Rotation: [4]float32{0, 0, 0, 1}}}},
		{Name: "Spine", Keyframes: []Keyframe{{Rotation: [4]float32{0, 0, 0, 1}}, {Rotation: [4]float32{0, 0, 0, 1}}}},
	})

	a, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(a.Bones) != 2 {
		t.Fatalf("expected 2 bones, got %d", len(a.Bones))
	}
	if a.Bones[1].Name != "Spine" || len(a.Bones[1].Keyframes) != 2 {
		t.Fatalf("unexpected second bone: %+v", a.Bones[1])
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, magicLen+4)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsTruncatedKeyframes(t *testing.T) {
	data := buildSyntheticAnimation(t, "broken", []Bone{
		{Name: "Bone01", Keyframes: []Keyframe{{Rotation: [4]float32{0, 0, 0, 1}}, {Rotation: [4]float32{0, 0, 0, 1}}}},
	})
	if _, err := Parse(data[:len(data)-10]); err == nil {
		t.Fatal("expected error parsing truncated buffer, got nil")
	}
}
