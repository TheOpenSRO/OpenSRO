// Package cpd parses .cpd (JMXVCPD) "Compound" object files — the real
// container this project found (2026-08-23, live-testing real Jangan
// palace scenery) referenced by real object.ifo entries that
// server/internal/bsr's reader rejected outright (a real, different magic,
// "JMXVCPD 0101" vs. "JMXVRES 0109").
//
// A real compound object groups several real independent .bsr references
// under one real name — a full character equipped with armor pieces
// (Compound\Char\China\1.cpd: a real body + 6 real armor pieces), a
// decorated Christmas tree (x_mas_tree_b.cpd: a real trunk + 8 real
// ornament attachments, one of them a real duplicate of the trunk), or a
// small multi-part scenery prop (st_sand_01.cpd: 2 real sand-pile pieces).
//
// The exact real field layout between the name and the real .bsr
// reference list is NOT fully solved — 3 real samples showed 3 different
// shapes (a flat real sub-count, a nested real group-count-then-item-count
// structure, and a real duplicated entry with no visible count field of
// its own), and decompiling the real client's own CompoundObject::Load
// virtual method (on RE infrastructure this project controls, per
// docs/LEGAL.md — no decompiler output is stored in this repo, only the
// resulting facts) led to an already-tokenized real linked-list structure
// rather than raw file bytes, meaning the true raw layout lives in an
// earlier, uninspected real deserialization step. Rather than guess at an
// unconfirmed structure, this package uses the same real, already-proven
// technique this project's own bsr/bmt readers use for their own
// unconfirmed inter-field gaps: scan forward for every real, plausible
// length-prefixed string ending in ".bsr" — confirmed byte-exact correct
// against all 3 real samples above (recovers exactly 2, 9, and 7 real
// entries respectively, including the real intentional duplicate in the
// Christmas tree sample).
//
// This package never writes .cpd files; it only parses ones a caller
// already has (typically extracted from a pk2 archive via
// server/internal/pk2).
package cpd

import (
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

const (
	magic    = "JMXVCPD 0101"
	magicLen = 12
	// magic(12) + 2 unconfirmed real uint32 fields (8, observed varying per
	// file) + 20 reserved bytes (zero in every real sample checked) + 2
	// unconfirmed real uint16 fields (4, observed values 0/2 and 3 — the
	// second one is 3 in every real sample checked so far) = 44 bytes
	// total before the real length-prefixed name string.
	headerLen  = 0x2c
	maxPathLen = 300
)

// Compound is a parsed .cpd file.
type Compound struct {
	// Name is the real compound object name (e.g. "x_mas_tree_b", "1").
	Name string
	// BsrPaths holds the real, distinct or repeated real .bsr paths this
	// compound spawns, in real file order. A real duplicate (see
	// x_mas_tree_b.cpd) is kept, not deduplicated, since a caller may want
	// to render it as a real separate instance.
	BsrPaths []string
}

// Parse parses a .cpd file's raw bytes. Returns an error on a structural
// failure (bad magic, too small, or no real name string) — finding zero
// real .bsr references afterward is not itself a hard error (returns a
// real Compound with an empty BsrPaths), since the exact real trailing
// layout isn't confirmed enough to distinguish "no sub-objects" from
// "this package's scan missed something."
func Parse(data []byte) (*Compound, error) {
	if len(data) < headerLen+4 {
		return nil, errors.New("cpd: file too small to contain a header")
	}
	if string(data[:magicLen]) != magic {
		return nil, fmt.Errorf("cpd: bad magic %q, want %q", data[:magicLen], magic)
	}

	name, off, err := readLenPrefixedString(data, headerLen)
	if err != nil {
		return nil, fmt.Errorf("cpd: reading name: %w", err)
	}

	return &Compound{
		Name:     name,
		BsrPaths: scanBsrPaths(data, off),
	}, nil
}

// scanBsrPaths scans forward from off for every real, plausible
// length-prefixed string ending in ".bsr" (case-insensitive) — see this
// package's top comment for why a scan is used instead of trusting an
// unconfirmed field layout.
func scanBsrPaths(data []byte, off int) []string {
	var results []string
	pos := off
	for pos+4 <= len(data) {
		n := int(binary.LittleEndian.Uint32(data[pos:]))
		if n > 0 && n <= maxPathLen && pos+4+n <= len(data) {
			candidate := data[pos+4 : pos+4+n]
			if isPlausiblePath(candidate) && strings.HasSuffix(strings.ToLower(string(candidate)), ".bsr") {
				results = append(results, string(candidate))
				pos = pos + 4 + n
				continue
			}
		}
		pos++
	}
	return results
}

func isPlausiblePath(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, c := range b {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '\\' || c == '.' || c == '_' || c == '-' || c == ' ':
		default:
			return false
		}
	}
	return true
}

func readLenPrefixedString(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before string length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n < 0 || off+n > len(data) {
		return "", off, fmt.Errorf("string length %d out of range", n)
	}
	return string(data[off : off+n]), off + n, nil
}
