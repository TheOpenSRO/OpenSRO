// Package efp parses .efp (JMXVEFF) particle-effect definition files —
// found in Particles.pk2's battle/ and other folders. Unlike every other
// format in this project, this isn't a fixed-layout record structure: it's
// a self-describing, nested, tagged property system (named string keys
// like "NormalTimeLife", "StaticEmit", "LinkMode", "Program", ... each
// followed by parameter data whose length isn't declared anywhere) —
// closer to a small serialization/reflection system than a flat struct.
// See docs/protocol/EFP_FORMAT.md for the full derivation, including why
// this reader only recovers a *flat* sequence of (name, raw value bytes)
// pairs rather than the true nested tree.
//
// No decompiled loader was fully traced for this format (a real loader
// function was located in sro_client.exe but is too obfuscated by
// stack/register reuse to read field types off directly — see
// EFP_FORMAT.md). Confirmed empirically instead, the same brute-force
// byte-analysis approach used for .bsk/.mapo/.mapm: scanning 30 real files
// for every valid length-prefixed identifier-shaped string, then measuring
// how far a value-boundary-agnostic "read a name, then scan forward for
// the next one" walk gets — which turned out to be 94-100% of every real
// file checked, with no schema table needed at all.
//
// This package never writes .efp files; it only parses ones a caller
// already has (typically extracted from Particles.pk2 via
// server/internal/pk2).
package efp

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	magic       = "JMXVEFF"
	magicLen    = 7
	versionLen  = 4
	maxNameLen  = 40
	maxScanSkip = 100000 // bound on how far the "find the next name" scan looks
)

// Entry is one flat (name, raw value bytes) pair recovered from the file.
// Value's true structure isn't decoded — for a "leaf" property it's likely
// a handful of ints/floats, for a "container" property it's likely the
// serialized bytes of further nested Entry-shaped data that this reader
// doesn't currently re-parse recursively (the boundary-finding technique
// that locates Value's end works the same way regardless of nesting depth,
// so the *bytes* are captured correctly either way — only the tree
// structure is flattened away). See docs/protocol/EFP_FORMAT.md.
type Entry struct {
	Name  string
	Value []byte
}

// Effect is a parsed .efp file.
type Effect struct {
	// Version is the 4-byte tag after the magic, e.g. "0011" or "0013" —
	// both confirmed real, with different fixed header shapes before the
	// effect name (see Parse).
	Version string
	Name    string
	// Count is a uint32 read right after Name, plausibly a top-level
	// section count — not cross-checked against len(Entries) (Entries is
	// a flat walk of every nesting level, not just top-level sections, so
	// they aren't expected to match).
	Count   uint32
	Entries []Entry
}

// Parse parses a .efp file's raw bytes.
//
// The header differs by version:
//   - "0011": magic(7) + " "(1) + version(4) + a uint32 (unconfirmed) +
//     the effect name.
//   - "0013": magic(7) + " "(1) + version(4) + a float32 (unconfirmed) +
//     12 reserved bytes (observed all-zero) + a uint32 (unconfirmed) +
//     the effect name.
//
// Both continue identically from there: a uint32 count, then a flat
// sequence of Entry records until the boundary-finding scan can't locate
// another valid name (the real file's small trailer, or truncation).
func Parse(data []byte) (*Effect, error) {
	if len(data) < magicLen+1+versionLen {
		return nil, errors.New("efp: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("efp: bad magic %q, want %q", data[0:magicLen], magic)
	}

	e := &Effect{Version: string(data[magicLen+1 : magicLen+1+versionLen])}

	off := magicLen + 1 + versionLen
	switch e.Version {
	case "0011":
		off += 4 // unconfirmed u32
	case "0013":
		off += 4 + 12 + 4 // unconfirmed float32, 12 reserved bytes, unconfirmed u32
	default:
		return nil, fmt.Errorf("efp: unrecognized version %q", e.Version)
	}

	name, off, err := readName(data, off)
	if err != nil {
		return nil, fmt.Errorf("efp: reading effect name: %w", err)
	}
	e.Name = name

	if off+4 > len(data) {
		return nil, errors.New("efp: truncated before top-level count")
	}
	e.Count = binary.LittleEndian.Uint32(data[off:])
	off += 4

	for off < len(data) {
		entryName, valueStart, err := readName(data, off)
		if err != nil {
			break // the file's small trailer, or truncation
		}

		valueEnd := findNextName(data, valueStart)
		if valueEnd == -1 {
			e.Entries = append(e.Entries, Entry{Name: entryName, Value: data[valueStart:]})
			off = len(data)
			break
		}

		e.Entries = append(e.Entries, Entry{Name: entryName, Value: data[valueStart:valueEnd]})
		off = valueEnd
	}

	if len(e.Entries) == 0 {
		return nil, errors.New("efp: no entries parsed")
	}

	return e, nil
}

// findNextName scans forward from off for the next valid name token,
// bounded by maxScanSkip. Returns -1 if none is found before the bound or
// end of data.
func findNextName(data []byte, off int) int {
	limit := len(data)
	if off+maxScanSkip < limit {
		limit = off + maxScanSkip
	}
	for scan := off; scan < limit; scan++ {
		if _, _, err := readName(data, scan); err == nil {
			return scan
		}
	}
	return -1
}

// readName reads a uint32-length-prefixed name at off: 1-40 ASCII
// letters/digits/underscores, starting with a letter (the same rule used
// to discover this format's structure in the first place — a real
// property name is always identifier-shaped, which is what makes
// find-the-next-name boundary detection reliable enough to work without a
// schema table).
func readName(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before name length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n <= 0 || n > maxNameLen || off+n > len(data) {
		return "", off, fmt.Errorf("name length %d out of range", n)
	}
	s := data[off : off+n]
	if !isAlpha(s[0]) {
		return "", off, fmt.Errorf("name %q doesn't start with a letter", s)
	}
	for _, c := range s {
		if !isAlpha(c) && !isDigit(c) && c != '_' {
			return "", off, fmt.Errorf("implausible name byte %q", c)
		}
	}
	return string(s), off + n, nil
}

func isAlpha(c byte) bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }
