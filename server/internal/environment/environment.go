// Package environment parses environment.ifo (JMXVENVI) — the real
// per-preset environment/lighting table `.m`'s per-block EnvironmentID
// field indexes (see server/internal/mapm and docs/protocol/
// ENVIRONMENT_FORMAT.md for the full derivation).
//
// Real, confirmed location: Map.pk2's root (alongside object.ifo/
// tile2d.ifo/etc), not Data.pk2 — an earlier pass wrongly declared this
// file "entirely absent" after only checking Data.pk2; see
// docs/protocol/TILE2D_FORMAT.md's 2026-08-23 correction for the same
// wrong-archive mistake found (and fixed) for real ground textures.
//
// Verified byte-for-byte against a real 76,000-byte sample: all 74 real
// records parse with the structure below, landing exactly on a real
// trailing "Root(Environment)" section (a separate, real, Korean-language
// editor organizational tree — not parsed here, see TrailerOffset).
//
// This package never writes environment.ifo files; it only parses ones a
// caller already has (typically extracted from Map.pk2 via
// server/internal/pk2).
package environment

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

const (
	magic    = "JMXVENVI1003"
	magicLen = 12
)

// channelGroupFloats is the real per-record channel layout, in real file
// order — confirmed by decompiling the real client's own record reader
// and cross-checking its two vector-append helpers' element-size math (a
// 4-float push vs. a 2-float push) against the real byte sample until a
// byte-exact, zero-leftover parse of the real record data was reached.
// Each entry is the real float count per group for that channel index;
// the channel itself is a real, count-prefixed array of that many-float
// groups (0 or more).
var channelGroupFloats = [16]int{4, 4, 4, 4, 4, 4, 4, 2, 2, 4, 2, 2, 2, 4, 4, 2}

// Record is one real environment/lighting preset.
type Record struct {
	// Key is the real single-byte ID .m's per-block EnvironmentID field
	// references.
	Key byte
	// Name1 is the real primary preset name (e.g. "Env7", "Env8") — reused
	// across many records, not unique per record.
	Name1 string
	// Name2 is a real secondary name field — empty in every record of the
	// one real sample checked; real purpose beyond "a second optional
	// label" isn't confirmed.
	Name2 string
	// Channels holds the real 16 channels, in real file order (see
	// channelGroupFloats). Each channel is a slice of float groups (each
	// group's length is that channel's channelGroupFloats entry). Real
	// values in the one sample checked are mostly 0.0/1.0 (consistent
	// with, but not confirmed to be, real RGB/weight lighting-blend
	// keyframes across something like time-of-day) — no per-channel
	// semantic meaning is confirmed, so this package does not assign one.
	Channels [16][][]float32
}

// ParsedFile is a fully-parsed environment.ifo.
type ParsedFile struct {
	// RecordCount is the real record count from the header.
	RecordCount uint32
	// Records holds the real records, in real file order.
	Records []Record
	// TrailerOffset is the byte offset where record data ends and the
	// real, unparsed "Root(Environment)" trailer begins — see this
	// package's top comment.
	TrailerOffset int
}

// Parse parses environment.ifo's real record data. It does not parse the
// real trailing "Root(Environment)" organizational tree (ParsedFile.
// TrailerOffset marks where it starts, for a caller that wants the raw
// bytes).
func Parse(data []byte) (*ParsedFile, error) {
	if len(data) < magicLen+4+2 {
		return nil, errors.New("environment: file too small to contain a header")
	}
	if string(data[:magicLen]) != magic {
		return nil, fmt.Errorf("environment: bad magic %q, want %q", data[:magicLen], magic)
	}

	off := magicLen
	recordCount := binary.LittleEndian.Uint32(data[off:])
	off += 4
	off += 2 // real fixed field, always 0 in the one real sample checked; purpose unconfirmed

	f := &ParsedFile{RecordCount: recordCount}

	for i := uint32(0); i < recordCount; i++ {
		if off+2 > len(data) {
			return nil, fmt.Errorf("environment: truncated before record %d's key", i)
		}
		key := data[off]
		pad := data[off+1]
		off += 2
		if pad != 0 {
			return nil, fmt.Errorf("environment: record %d has a non-zero pad byte (%d) — this package's real structural assumption may not hold for this file", i, pad)
		}

		name1, newOff, err := readString(data, off)
		if err != nil {
			return nil, fmt.Errorf("environment: record %d name1: %w", i, err)
		}
		off = newOff

		name2, newOff, err := readString(data, off)
		if err != nil {
			return nil, fmt.Errorf("environment: record %d name2: %w", i, err)
		}
		off = newOff

		if off+4 > len(data) {
			return nil, fmt.Errorf("environment: truncated before record %d's reserved field", i)
		}
		off += 4 // real fixed field, always 0 in the one real sample checked; purpose unconfirmed

		rec := Record{Key: key, Name1: name1, Name2: name2}

		for ci, groupFloats := range channelGroupFloats {
			if off+4 > len(data) {
				return nil, fmt.Errorf("environment: truncated before record %d's channel %d count", i, ci)
			}
			count := binary.LittleEndian.Uint32(data[off:])
			off += 4
			groupLen := groupFloats * 4
			groups := make([][]float32, 0, count)
			for g := uint32(0); g < count; g++ {
				if off+groupLen > len(data) {
					return nil, fmt.Errorf("environment: truncated inside record %d's channel %d data", i, ci)
				}
				group := make([]float32, groupFloats)
				for k := 0; k < groupFloats; k++ {
					group[k] = decodeFloat32(data[off+k*4:])
				}
				off += groupLen
				groups = append(groups, group)
			}
			rec.Channels[ci] = groups
		}

		f.Records = append(f.Records, rec)
	}

	f.TrailerOffset = off
	return f, nil
}

// readString reads a real length-prefixed string (uint32 length + that
// many raw bytes) at off. Returns the string and the offset right after
// it.
func readString(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", 0, errors.New("truncated before a string length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if off+n > len(data) {
		return "", 0, fmt.Errorf("string length %d exceeds remaining data", n)
	}
	return string(data[off : off+n]), off + n, nil
}

func decodeFloat32(b []byte) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(b))
}
