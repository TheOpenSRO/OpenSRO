// Package mapo parses .o (JMXVMAPO) files — the per-region object-placement
// list inside Map.pk2, alongside a matching .m heightmap/terrain file (see
// docs/protocol/MAPM_FORMAT.md, which remains unsolved). This is very
// likely where a .bsr object actually gets positioned and rotated in the
// game world, since .bsr itself carries no such data.
//
// No decompiled loader was found for this format (checked both
// sro_client.exe and EternityLib.dll, fully Ghidra-analyzed, including an
// RTTI class name search — see docs/protocol/MAPO_FORMAT.md), so this is
// confirmed entirely empirically: a brute-force byte scan of a real
// 105-object sample for "plausible small type ID, followed by 3
// non-garbage floats" recovered 95 real, sensibly-clustered object
// placements (4 distinct type IDs, world positions matching the scale of
// real .bms/.bsk data) and revealed the true record layout — a fixed
// 16-byte header (type ID + position) most records don't have more after,
// but some have a variable-length trailing block (0 to ~40 raw bytes, seen
// only as zero padding plus a small trailing value in every real record
// checked) before the next one starts. There's no length field for that
// trailing block, so this parser locates the next record the same way it
// was discovered: by scanning forward for the next byte offset that looks
// like a plausible record start. Verified against 2 real files (one
// 105-object populated region consumed to the exact byte, one
// all-zero/no-objects region correctly returning zero objects).
//
// This package never writes .o files; it only parses ones a caller already
// has (typically extracted from Map.pk2 via server/internal/pk2).
package mapo

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	magic          = "JMXVMAPO"
	magicLen       = 8
	versionLen     = 4
	minHeaderLen   = 0x14 // magic(8) + version(4) + 2 unconfirmed u32 fields (8) -- most files
	maxHeaderScan  = 64   // bound on how far the header-length scan looks for the first record
	posFieldLen    = 16   // type ID (4) + position (3x float32)
	fixedRecordLen = 28   // posFieldLen + 12 more raw bytes, unconfirmed, present on every record
	maxTrailerScan = 128  // bound on how far the resync scan looks for the next record
)

// Object is one placed object: its catalog type ID and world position.
// Fixed12 is the 12 raw bytes every record has right after the position —
// unconfirmed meaning (not exposed as parsed fields, same policy as
// .bsk's transform bytes). Extra is 0 or more further raw trailing bytes
// that appear before the next object's record (or EOF) — real files show
// these as zero padding plus a small trailing value (1, 3, or 5 observed),
// but the exact meaning isn't confirmed either. See
// docs/protocol/MAPO_FORMAT.md.
type Object struct {
	TypeID   uint32
	Position [3]float32
	// Rotation is the object's real Y-axis (yaw) rotation in radians
	// -- Fixed12[2:6] as a little-endian float32. Confirmed two ways
	// (2026-08-24): (1) decompiled the object-construction function
	// reached through this class's real vtable (FUN_009f2c20 in a real
	// client build) and found it loads a single float from this same
	// stack slot twice in a row, immediately before two back-to-back FPU
	// calls (cos-then-sin, same input both times) whose results are
	// packed into a (cos,0,sin)-shaped direction vector alongside a
	// separate (0,1,0) triple -- the standard yaw-angle-to-forward-vector
	// pattern. (2) Checked empirically against a real, densely-populated
	// Jangan-area region: every single one of 273 real objects' values at
	// this offset, interpreted as float32, falls in the real [0, 2*pi]
	// range (100%, not just "mostly") -- not something a coincidental
	// misread of unrelated bytes would produce. Several real values also
	// round to whole real degrees (e.g. 6.1261 rad = 351.0 deg) when
	// converted, consistent with a level-editor angle snap. Fixed12[0:2]
	// remains an unconfirmed 2-byte flag (observed only 0x0000/0xffff);
	// Fixed12[6:12]'s meaning is still unconfirmed (byte 6 looks like a
	// small per-object counter, byte 7 like a block/sub-region locator --
	// see docs/protocol/MAPO_FORMAT.md).
	Rotation float32
	Fixed12  []byte
	Extra    []byte
}

// Region is a parsed .o file — one map region's object placement list.
type Region struct {
	// Version is the 4-byte tag after the magic, e.g. "1000" (an
	// effectively-empty region, no objects) or "1001" (populated).
	Version string
	Objects []Object
}

// Parse parses a .o file's raw bytes.
//
// The header between the version tag and the first object record isn't a
// fixed size: it's usually 20 bytes (magic + version + 2 unconfirmed u32
// fields), but real files were also seen with an 18-byte header — 2 bytes
// narrower, cause unconfirmed. Rather than trust either fixed length, this
// scans forward (bounded) from right after the version tag for the first
// byte offset that looks like a plausible record, the same
// verify-plausibility approach the rest of this format needed.
func Parse(data []byte) (*Region, error) {
	if len(data) < minHeaderLen {
		return nil, errors.New("mapo: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("mapo: bad magic %q, want %q", data[0:magicLen], magic)
	}

	r := &Region{Version: string(data[magicLen : magicLen+versionLen])}

	off := findFirstRecord(data, magicLen+versionLen)
	for off != -1 && looksLikeRecord(data, off) {
		typeID := binary.LittleEndian.Uint32(data[off:])
		pos := [3]float32{
			readFloat32(data, off+4),
			readFloat32(data, off+8),
			readFloat32(data, off+12),
		}

		trailerStart := off + fixedRecordLen
		next := trailerStart
		scanned := 0
		for next < len(data) && !looksLikeRecord(data, next) && scanned < maxTrailerScan {
			next++
			scanned++
		}

		fixed12 := data[off+posFieldLen : trailerStart]
		r.Objects = append(r.Objects, Object{
			TypeID:   typeID,
			Position: pos,
			Rotation: readFloat32(fixed12, 2),
			Fixed12:  fixed12,
			Extra:    data[trailerStart:next],
		})
		off = next
	}

	return r, nil
}

// findFirstRecord scans forward from off (bounded by maxHeaderScan) for the
// first byte offset that looks like a plausible record start. Returns -1
// if none is found — the normal, expected outcome for an
// effectively-empty region (version "1000", or occasionally "1001" with no
// real objects — the version tag alone isn't a reliable populated/empty
// signal, see docs/protocol/MAPO_FORMAT.md).
func findFirstRecord(data []byte, off int) int {
	limit := off + maxHeaderScan
	if limit > len(data) {
		limit = len(data)
	}
	for scan := off; scan < limit; scan++ {
		if looksLikeRecord(data, scan) {
			return scan
		}
	}
	return -1
}

// looksLikeRecord reports whether off is a plausible object-record start: a
// small-ish type ID followed by 3 position floats that aren't NaN/Inf, and
// aren't a suspicious near-zero value that only shows up from misaligned
// binary data (every real position component checked was either exactly
// 0.0 or had a magnitude well above float32 subnormal-noise range).
func looksLikeRecord(data []byte, off int) bool {
	if off+fixedRecordLen > len(data) {
		return false
	}
	typeID := binary.LittleEndian.Uint32(data[off:])
	if typeID == 0 || typeID >= 10000 {
		return false
	}
	for i := 0; i < 3; i++ {
		if !saneFloat(readFloat32(data, off+4+4*i)) {
			return false
		}
	}
	return true
}

func saneFloat(v float32) bool {
	if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
		return false
	}
	if v == 0 {
		return true
	}
	abs := math.Abs(float64(v))
	return abs > 1e-3 && abs < 20000
}

func readFloat32(data []byte, off int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(data[off:]))
}
