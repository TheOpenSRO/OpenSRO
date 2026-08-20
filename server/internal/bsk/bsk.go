// Package bsk parses .bsk (JMXVBSK) skeleton files: the bone-hierarchy
// data .ban (bone animation) itself lacks. Confirmed empirically
// (byte-level, black-box, cross-checked against 8 real files spanning two
// very different skeleton styles) — see docs/protocol/BSK_FORMAT.md for the
// full derivation. No decompiler output is stored in this repo regardless —
// only the resulting facts about the container format.
//
// This package never writes .bsk files; it only parses ones a caller
// already has (typically extracted from a pk2 archive, or in this case
// found as loose files in a private-server data package rather than a pk2
// — see docs/PROGRESS.md).
package bsk

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	magic            = "JMXVBSK 0101"
	magicLen         = 12
	rootTransformLen = 92 // root, and any bone using the parent-less "Type A" record shape
	boneTransformLen = 88 // the ordinary "Type B" record shape (explicit parent name field)
	maxNameLen       = 60
)

// Bone is one bone's parent reference and raw transform data. The 88 (or
// 92, for bones using the parent-less record shape) transform bytes decode
// to two unit quaternions (the second being the exact conjugate of the
// first) and two 3-float position vectors — confirmed via magnitude checks
// on real data — but which is "local" vs. "world", and what the 4 extra
// bytes on 92-byte bones mean, aren't confirmed, so the bytes are kept raw
// rather than mislabeled. See docs/protocol/BSK_FORMAT.md.
type Bone struct {
	Name string
	// ParentName is empty only for bones using the parent-less, 92-byte
	// record shape (see Transform) — every other bone has an explicit
	// parent name in its own record, which is the only reliable source of
	// truth for the tree structure. (A bone's name can be *announced* far
	// earlier in the file than its real record appears, and the announcing
	// position does not reliably indicate the real parent — see
	// docs/protocol/BSK_FORMAT.md.)
	ParentName string
	// Transform is 88 raw bytes (ordinary bones, explicit ParentName) or
	// 92 (bones with no ParentName) — check len(Transform) to tell them
	// apart, or whether ParentName == "".
	Transform []byte
}

// Skeleton is a parsed .bsk file.
type Skeleton struct {
	RootName string
	Bones    []Bone
}

// Parse parses a .bsk file's raw bytes.
//
// The bone list isn't a simple linear scan: every bone name in the file is
// first *announced* (a bare length-prefixed name with nothing recognizable
// immediately after it) and later *resolved* — the same name reappears,
// this time followed by its real record. An announcement's resolution can
// be immediately next (the common case for a bone with no further nested
// announcements), or thousands of bytes later, after many other bones'
// announcements and resolutions have interleaved — real files were checked
// with both. There's no distinct "alias table" as earlier analysis in this
// project assumed; what looked like one is just every real file's opening
// run of announcements before the first resolution, the same mechanism
// applied everywhere else in the file.
//
// A resolution can take one of two shapes, and — confirmed on real Biped
// files — **both can appear within the same file**, decided per-bone, not
// per-file:
//   - Type A: no parent name, straight into a 92-byte transform.
//   - Type B: a parent name, then an 88-byte transform.
//
// There's no tag saying which shape applies; the reader tries Type A first
// and accepts it only if what immediately follows looks like a valid next
// token (or the file's constant 8-byte trailer) — otherwise it falls back
// to Type B. Verified against 8 real files (2 distinct skeleton styles,
// 38-265 bones each): every one parses to completion with zero leftover
// announcements and lands exactly on the trailer.
func Parse(data []byte) (*Skeleton, error) {
	if len(data) < magicLen+5 {
		return nil, errors.New("bsk: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("bsk: bad magic %q, want %q", data[0:magicLen], magic)
	}

	// A u32 of unconfirmed meaning sits at 0x0c; the root bone's own
	// name starts at 0x11 (one byte further than a plain 4-byte field
	// would predict — unconfirmed why).
	rootName, off, err := readLenPrefixedString(data, magicLen+5)
	if err != nil {
		return nil, fmt.Errorf("bsk: reading root name: %w", err)
	}
	if off+rootTransformLen > len(data) {
		return nil, errors.New("bsk: truncated before root transform")
	}
	off += rootTransformLen

	s := &Skeleton{RootName: rootName}
	pending := make(map[string]bool)

	for off < len(data) {
		name, next, err := readLenPrefixedStringFlex(data, off)
		if err != nil {
			break // the constant zero trailer, or truncation
		}

		if pending[name] {
			delete(pending, name)
			b, newOff, err := resolveBone(data, name, next)
			if err != nil {
				return nil, fmt.Errorf("bsk: resolving bone %q: %w", name, err)
			}
			s.Bones = append(s.Bones, *b)
			off = newOff
			continue
		}

		// Not a pending announcement being resolved -- check whether this
		// is the common case of a bone resolving immediately (its name is
		// repeated right away, with no other announcements interleaved).
		name2, next2, err2 := readLenPrefixedStringFlex(data, next)
		if err2 == nil && name2 == name {
			b, newOff, err := resolveBone(data, name, next2)
			if err != nil {
				return nil, fmt.Errorf("bsk: resolving bone %q: %w", name, err)
			}
			s.Bones = append(s.Bones, *b)
			off = newOff
			continue
		}

		pending[name] = true
		off = next
	}

	if len(pending) > 0 {
		names := make([]string, 0, len(pending))
		for n := range pending {
			names = append(names, n)
		}
		return nil, fmt.Errorf("bsk: %d bone name(s) announced but never resolved: %v", len(pending), names)
	}
	if len(s.Bones) == 0 {
		return nil, errors.New("bsk: no bones parsed")
	}

	return s, nil
}

// resolveBone reads a bone's record starting right after its resolving
// name occurrence, trying the parent-less "Type A" shape first and falling
// back to the with-parent "Type B" shape — see Parse's doc comment.
func resolveBone(data []byte, name string, off int) (*Bone, int, error) {
	if end := off + rootTransformLen; end <= len(data) && looksSynced(data, end) {
		return &Bone{Name: name, Transform: data[off:end]}, end, nil
	}

	parent, parentEnd, err := readLenPrefixedStringFlex(data, off)
	if err != nil {
		return nil, 0, fmt.Errorf("neither record shape matched (Type A didn't sync, Type B has no parent name: %w)", err)
	}
	end := parentEnd + boneTransformLen
	if end > len(data) {
		return nil, 0, errors.New("truncated transform")
	}
	return &Bone{Name: name, ParentName: parent, Transform: data[parentEnd:end]}, end, nil
}

// looksSynced reports whether off is a plausible boundary between two
// records: either the file's constant 8-byte trailer starts there, or a
// valid length-prefixed name can be read from there.
func looksSynced(data []byte, off int) bool {
	if off+8 == len(data) {
		return true
	}
	_, _, err := readLenPrefixedStringFlex(data, off)
	return err == nil
}

func readLenPrefixedString(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before string length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n <= 0 || n > maxNameLen || off+n > len(data) {
		return "", off, fmt.Errorf("string length %d out of range", n)
	}
	s := data[off : off+n]
	for _, c := range s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '(' || c == ')' || c == '[' || c == ']' || c == '_' || c == '-' || c == ' '
		if !ok {
			return "", off, fmt.Errorf("implausible name byte %q", c)
		}
	}
	return string(s), off + n, nil
}

// readLenPrefixedStringFlex tries off directly, then off+1 — real files
// were seen with both a 0-byte and a 1-byte gap before a name depending on
// what precedes it. See docs/protocol/BSK_FORMAT.md.
func readLenPrefixedStringFlex(data []byte, off int) (string, int, error) {
	if name, next, err := readLenPrefixedString(data, off); err == nil {
		return name, next, nil
	}
	return readLenPrefixedString(data, off+1)
}
