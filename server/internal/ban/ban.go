// Package ban parses .ban (JMXVBAN) bone-animation files. Confirmed
// empirically (byte-level, black-box) against real extracted files, the
// same way as the pk2/bms/bsr/ddj fixes, and cross-checked against the
// real loader in sro_client.exe (confirming the 28-byte keyframe record
// size and the overall header/bone-list shape). Both real samples checked
// parse to exactly the file's own byte length with zero bytes left over.
// No decompiler output is stored in this repo, only the resulting facts
// about the container format. See docs/protocol/BAN_FORMAT.md.
//
// This package never writes .ban files; it only parses ones a caller
// already has (typically extracted from a pk2 archive via
// server/internal/pk2).
package ban

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	magic         = "JMXVBAN 0102"
	magicLen      = 12
	keyframeSize  = 28 // 4-float quaternion + 3-float position
	maxTableCount = 100000
	maxNameLen    = 4096
)

// Keyframe is one bone's pose at one point in the animation.
type Keyframe struct {
	// Rotation is a unit quaternion (x, y, z, w) — confirmed via real
	// samples: every keyframe's 4 floats have magnitude ~1.0.
	Rotation [4]float32
	Position [3]float32
}

// Bone is one bone's full keyframe track.
type Bone struct {
	Name      string
	Keyframes []Keyframe
}

// Animation is a parsed .ban file.
type Animation struct {
	Name string
	// DurationMS is how long the clip runs; the last key time in every
	// real file checked. AuthoredFPS is 30 in every file checked -- the
	// grid the key times sit on, not a playback rate. Cyclic is 1 for
	// stands, walks and runs, 0 for skills, sitting and dying. See
	// docs/protocol/BAN_FORMAT.md.
	DurationMS, AuthoredFPS, Cyclic uint32
	// KeyTimes says when each keyframe falls, in milliseconds from the
	// start: one entry per keyframe of every bone, ascending from 0.
	KeyTimes []uint32
	Bones    []Bone
}

// Parse parses a .ban file's raw bytes.
func Parse(data []byte) (*Animation, error) {
	if len(data) < magicLen+4 {
		return nil, errors.New("ban: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("ban: bad magic %q, want %q", data[0:magicLen], magic)
	}

	// Two unconfirmed u32 fields (observed 0 in every real file checked)
	// sit between the magic and the animation-name length.
	off := magicLen + 8

	name, off, err := readLenPrefixedString(data, off)
	if err != nil {
		return nil, fmt.Errorf("ban: reading name: %w", err)
	}

	a := &Animation{Name: name}
	if off+12 > len(data) {
		return nil, errors.New("ban: truncated before header fields")
	}
	a.DurationMS = binary.LittleEndian.Uint32(data[off:])
	a.AuthoredFPS = binary.LittleEndian.Uint32(data[off+4:])
	a.Cyclic = binary.LittleEndian.Uint32(data[off+8:])
	off += 12

	// The key time table: when each keyframe falls, in milliseconds.
	if off+4 > len(data) {
		return nil, errors.New("ban: truncated before the key time table")
	}
	tableCount := binary.LittleEndian.Uint32(data[off:])
	off += 4
	if tableCount > maxTableCount {
		return nil, fmt.Errorf("ban: implausible key time count %d", tableCount)
	}
	if off+int(tableCount)*4 > len(data) {
		return nil, errors.New("ban: key time table runs past end of file")
	}
	a.KeyTimes = make([]uint32, tableCount)
	for i := range a.KeyTimes {
		a.KeyTimes[i] = binary.LittleEndian.Uint32(data[off+i*4:])
	}
	off += int(tableCount) * 4

	if off+4 > len(data) {
		return nil, errors.New("ban: truncated before bone count")
	}
	boneCount := binary.LittleEndian.Uint32(data[off:])
	off += 4

	for i := uint32(0); i < boneCount; i++ {
		bone, next, err := parseBone(data, off)
		if err != nil {
			return nil, fmt.Errorf("ban: reading bone %d/%d: %w", i+1, boneCount, err)
		}
		a.Bones = append(a.Bones, *bone)
		off = next
	}

	return a, nil
}

func parseBone(data []byte, off int) (*Bone, int, error) {
	name, off, err := readLenPrefixedString(data, off)
	if err != nil {
		return nil, off, fmt.Errorf("reading bone name: %w", err)
	}
	if off+4 > len(data) {
		return nil, off, errors.New("truncated before keyframe count")
	}
	kfCount := binary.LittleEndian.Uint32(data[off:])
	off += 4

	end := off + int(kfCount)*keyframeSize
	if end > len(data) {
		return nil, off, fmt.Errorf("keyframe array (count=%d) runs past end of file", kfCount)
	}

	b := &Bone{Name: name, Keyframes: make([]Keyframe, kfCount)}
	for i := range b.Keyframes {
		rec := data[off+i*keyframeSize : off+(i+1)*keyframeSize]
		kf := &b.Keyframes[i]
		for c := 0; c < 4; c++ {
			kf.Rotation[c] = readFloat32(rec, c*4)
		}
		for c := 0; c < 3; c++ {
			kf.Position[c] = readFloat32(rec, 16+c*4)
		}
	}

	return b, end, nil
}

func readLenPrefixedString(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before string length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n < 0 || n > maxNameLen || off+n > len(data) {
		return "", off, fmt.Errorf("string length %d out of range", n)
	}
	return string(data[off : off+n]), off + n, nil
}

func readFloat32(b []byte, off int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(b[off:]))
}
