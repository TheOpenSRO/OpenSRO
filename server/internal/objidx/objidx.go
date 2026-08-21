// Package objidx parses .ifo (JMXVOBJI) object-index tables -- the real
// answer to a long-standing open question in this project: what a .mapo
// region-file's per-placement type ID actually resolves to. See
// docs/protocol/MAPO_FORMAT.md for the full derivation (found by browsing
// a real Data.pk2 after fixing server/internal/pk2's directory-chain bug,
// then confirmed by cross-checking real .mapo type IDs from a real region
// against this table and getting real, sensible scenery paths back).
//
// Unlike every other JMXV*-prefixed format in this project, .ifo is not a
// binary container: after the magic line, it's a plain ASCII text table,
// one real object type per line.
package objidx

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const magic = "JMXVOBJI1000"

// Entry is one real object type: a real, resolvable .bsr resource path
// (Windows-style backslashes, as stored -- resolve case-insensitively
// against a real archive, same as every other real path in this project),
// plus an unconfirmed per-entry flags word (observed values seen so far:
// 0 and 1; not decompiled, meaning not yet promoted past "raw flags").
type Entry struct {
	TypeID uint32
	Flags  uint32
	Path   string
}

// Table is a parsed .ifo object-index. Entries is indexed by TypeID
// directly (confirmed real: every real file checked has entries in
// strict sequential order starting at 0, so TypeID always equals its own
// slice index) -- Lookup still bounds-checks rather than assuming that
// holds for every possible real file.
type Table struct {
	Entries []Entry
}

// Lookup returns the real entry for typeID (as found in a real .mapo
// placement record), or false if typeID is out of range for this table.
func (t *Table) Lookup(typeID uint32) (Entry, bool) {
	if int(typeID) >= len(t.Entries) {
		return Entry{}, false
	}
	e := t.Entries[typeID]
	if e.TypeID != typeID {
		return Entry{}, false
	}
	return e, true
}

// Parse parses a real .ifo file's raw bytes. Returns an error if the
// magic line, declared count, or any record line doesn't match the real,
// confirmed format: "JMXVOBJI1000\n<count>\n" followed by exactly
// <count> lines shaped "%05d 0x%08x \"<path>\"".
func Parse(data []byte) (*Table, error) {
	text := string(data)
	lines := strings.Split(text, "\n")
	if len(lines) < 2 {
		return nil, errors.New("objidx: file too short to contain a header")
	}
	if lines[0] != magic {
		return nil, fmt.Errorf("objidx: bad magic %q, want %q", lines[0], magic)
	}

	count, err := strconv.Atoi(strings.TrimSpace(lines[1]))
	if err != nil || count < 0 {
		return nil, fmt.Errorf("objidx: bad count line %q", lines[1])
	}
	if len(lines) < 2+count {
		return nil, fmt.Errorf("objidx: declared %d records but file only has %d body lines", count, len(lines)-2)
	}

	t := &Table{Entries: make([]Entry, 0, count)}
	for i := 0; i < count; i++ {
		line := lines[2+i]
		e, err := parseLine(line)
		if err != nil {
			return nil, fmt.Errorf("objidx: record %d: %w", i, err)
		}
		t.Entries = append(t.Entries, e)
	}

	return t, nil
}

func parseLine(line string) (Entry, error) {
	// Real shape: "%05d 0x%08X \"<path>\"" -- three space-separated
	// fields, the third quoted (a real path can't itself contain a
	// literal double-quote in any file checked, so a naive split-on-quote
	// is sufficient rather than needing real escape handling).
	firstSpace := strings.IndexByte(line, ' ')
	if firstSpace < 0 {
		return Entry{}, fmt.Errorf("no space-separated type ID field in %q", line)
	}
	typeID, err := strconv.ParseUint(line[:firstSpace], 10, 32)
	if err != nil {
		return Entry{}, fmt.Errorf("bad type ID in %q: %w", line, err)
	}

	rest := line[firstSpace+1:]
	secondSpace := strings.IndexByte(rest, ' ')
	if secondSpace < 0 {
		return Entry{}, fmt.Errorf("no space-separated flags field in %q", line)
	}
	flagsField := rest[:secondSpace]
	if !strings.HasPrefix(flagsField, "0x") {
		return Entry{}, fmt.Errorf("flags field %q missing 0x prefix", flagsField)
	}
	flags, err := strconv.ParseUint(flagsField[2:], 16, 32)
	if err != nil {
		return Entry{}, fmt.Errorf("bad flags in %q: %w", line, err)
	}

	pathField := strings.TrimSpace(rest[secondSpace+1:])
	if len(pathField) < 2 || pathField[0] != '"' || pathField[len(pathField)-1] != '"' {
		return Entry{}, fmt.Errorf("path field %q not quoted", pathField)
	}
	path := pathField[1 : len(pathField)-1]

	return Entry{TypeID: uint32(typeID), Flags: uint32(flags), Path: path}, nil
}
