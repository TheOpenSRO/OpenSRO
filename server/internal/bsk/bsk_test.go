package bsk

import (
	"encoding/binary"
	"testing"
)

// buildSyntheticSkeleton writes a minimal, synthetic .bsk-shaped buffer
// (never real game data) matching the layout confirmed against 8 real
// files (each fully consumed except a constant 8-byte zero trailer): see
// docs/protocol/BSK_FORMAT.md.
func buildSyntheticSkeleton(t *testing.T) []byte {
	t.Helper()

	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = appendU32(buf, 0) // unconfirmed u32 at 0x0c
	buf = append(buf, 0)    // the extra byte before the root name
	buf = appendLenPrefixed(buf, "[root]")
	buf = append(buf, make([]byte, rootTransformLen)...)

	// BoneA: announced early (like a real file's opening run of
	// announcements) but not resolved until much later, using the
	// parent-less "Type A" shape (92-byte transform, no parent name).
	buf = appendLenPrefixed(buf, "BoneA")

	// BoneB: resolves immediately (name repeated right away) -- the
	// ordinary "Type B" shape (parent name + 88-byte transform).
	// Parented to BoneA, even though BoneA isn't resolved yet -- the
	// parent field is just a name string, independent of resolution
	// order.
	buf = appendLenPrefixed(buf, "BoneB")
	buf = appendLenPrefixed(buf, "BoneB")
	buf = appendLenPrefixed(buf, "BoneA")
	buf = append(buf, make([]byte, boneTransformLen)...)

	// BoneC: announced, then its own announcement is what resolves BoneA
	// (BoneA reappears here, resolved via Type A) before BoneC itself
	// resolves later still -- exercises interleaved announce/resolve
	// pairs, confirmed on real Biped-style files.
	buf = appendLenPrefixed(buf, "BoneC")
	buf = appendLenPrefixed(buf, "BoneA")
	buf = append(buf, make([]byte, rootTransformLen)...) // resolves BoneA (Type A)

	// BoneC finally resolves (Type B, parented to BoneB).
	buf = appendLenPrefixed(buf, "BoneC")
	buf = appendLenPrefixed(buf, "BoneB")
	buf = append(buf, make([]byte, boneTransformLen)...)

	buf = append(buf, make([]byte, 8)...) // trailer, observed constant zero
	return buf
}

func appendU32(b []byte, v uint32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], v)
	return append(b, tmp[:]...)
}

func appendLenPrefixed(b []byte, s string) []byte {
	b = appendU32(b, uint32(len(s)))
	return append(b, []byte(s)...)
}

func TestParse(t *testing.T) {
	data := buildSyntheticSkeleton(t)

	s, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if s.RootName != "[root]" {
		t.Fatalf("unexpected root name: %q", s.RootName)
	}
	if len(s.Bones) != 3 {
		t.Fatalf("expected 3 bones, got %d: %+v", len(s.Bones), s.Bones)
	}

	byName := make(map[string]Bone, len(s.Bones))
	for _, b := range s.Bones {
		byName[b.Name] = b
	}

	boneB, ok := byName["BoneB"]
	if !ok || boneB.ParentName != "BoneA" {
		t.Fatalf("unexpected BoneB: %+v", boneB)
	}
	if len(boneB.Transform) != boneTransformLen {
		t.Fatalf("unexpected BoneB transform length: %d", len(boneB.Transform))
	}

	boneA, ok := byName["BoneA"]
	if !ok || boneA.ParentName != "" {
		t.Fatalf("unexpected BoneA: %+v", boneA)
	}
	if len(boneA.Transform) != rootTransformLen {
		t.Fatalf("unexpected BoneA transform length: %d", len(boneA.Transform))
	}

	boneC, ok := byName["BoneC"]
	if !ok || boneC.ParentName != "BoneB" {
		t.Fatalf("unexpected BoneC: %+v", boneC)
	}
	if len(boneC.Transform) != boneTransformLen {
		t.Fatalf("unexpected BoneC transform length: %d", len(boneC.Transform))
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse(make([]byte, magicLen+10)); err == nil {
		t.Fatal("expected error parsing buffer with bad magic, got nil")
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	data := buildSyntheticSkeleton(t)
	if _, err := Parse(data[:magicLen+10]); err == nil {
		t.Fatal("expected error parsing truncated buffer, got nil")
	}
}

func TestParseRejectsUnresolvedAnnouncement(t *testing.T) {
	var buf []byte
	buf = append(buf, []byte(magic)...)
	buf = appendU32(buf, 0)
	buf = append(buf, 0)
	buf = appendLenPrefixed(buf, "[root]")
	buf = append(buf, make([]byte, rootTransformLen)...)
	buf = appendLenPrefixed(buf, "Orphan") // announced, never resolved
	buf = append(buf, make([]byte, 8)...)  // trailer

	if _, err := Parse(buf); err == nil {
		t.Fatal("expected error for an announcement with no matching resolution, got nil")
	}
}
