// Package efp reads .efp (JMXVEFF) particle-effect definition files, the
// format of Particles.pk2. It is a self-describing tree: nodes carrying named
// controllers and commands, each followed by a value whose layout depends on
// its registered type.
//
// Two readers live here:
//   - Decode (tree.go, round 619) reads the real typed tree, following the
//     client's own loader field by field (addresses in
//     docs/protocol/EFP_FORMAT.md). Over the retail archive it consumes
//     4,096 of 4,170 files to the exact byte.
//   - Parse is the older flat walk: it recovers (name, raw bytes) pairs by
//     scanning for the next identifier-shaped string. It needs no schema and
//     is kept for callers that only want names; since round 619 it shares
//     Decode's header handling.
//
// This package never writes .efp files; it only parses ones a caller
// already has (typically extracted from Particles.pk2 via
// server/internal/pk2). No game data is stored in the repo.
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
	// Version is the 4-byte tag after the magic: "0010", "0011", "0012"
	// or "0013" (see headerSize for the bytes each adds).
	Version string
	Name    string
	// Count is the uint32 read right after Name: the root node's
	// controller count (READ, FUN_00cc3a40; round 619).
	Count   uint32
	Entries []Entry
}

// Parse parses a .efp file's raw bytes into the flat (name, raw value bytes)
// walk. It is kept for callers that only want the names; Decode reads the
// real typed tree.
//
// The header is the client's own (FUN_00cb8d70, round 619): after the
// 12-byte magic, versions "0012" and up carry a float32, "0013" and up three
// uint32 more (headerSize). Then comes the root node's uint32 id — the
// "unconfirmed u32" of the 0011/0013 layouts described before round 619 —
// and its name. The name may be any length-prefixed string without control
// characters (retail has "11111", names with spaces or a leading '-', and
// EUC-KR Korean); only the flat walk's entry names keep the strict
// identifier rule.
//
// Both continue identically from there: the uint32 controller count, then a
// flat sequence of Entry records until the boundary-finding scan can't locate
// another valid name (the real file's small trailer, or truncation).
func Parse(data []byte) (*Effect, error) {
	if len(data) < magicLen+1+versionLen {
		return nil, errors.New("efp: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("efp: bad magic %q, want %q", data[0:magicLen], magic)
	}

	e := &Effect{Version: string(data[magicLen+1 : magicLen+1+versionLen])}

	hs, err := headerSize(e.Version)
	if err != nil {
		return nil, err
	}
	off := magicLen + 1 + versionLen + hs + 4 // version header, then the root node's id

	name, off, err := readEffectName(data, off)
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

// readEffectName reads the root node's name: any uint32-length-prefixed run
// of 1-255 bytes without control characters. Bytes above 0x7f are allowed:
// system\system_levelup.efp and its three copies name their root in EUC-KR.
func readEffectName(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before name length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n <= 0 || n > 255 || off+n > len(data) {
		return "", off, fmt.Errorf("name length %d out of range", n)
	}
	for _, c := range data[off : off+n] {
		if c < 0x20 || c == 0x7f {
			return "", off, fmt.Errorf("implausible name byte %q", c)
		}
	}
	return string(data[off : off+n]), off + n, nil
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
