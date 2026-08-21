package objidx

import (
	"fmt"
	"testing"
)

// buildSyntheticTable writes a minimal, real-shaped .ifo text table
// (never real game data) matching the confirmed format: magic line,
// count line, then that many "%05d 0x%08x \"<path>\"" records.
func buildSyntheticTable(entries []Entry) []byte {
	out := magic + "\n" + fmt.Sprintf("%d\n", len(entries))
	for _, e := range entries {
		out += fmt.Sprintf("%05d 0x%08x \"%s\"\n", e.TypeID, e.Flags, e.Path)
	}
	return []byte(out)
}

func TestParseSequentialTable(t *testing.T) {
	data := buildSyntheticTable([]Entry{
		{TypeID: 0, Flags: 1, Path: `res\bldg\test\tree01.bsr`},
		{TypeID: 1, Flags: 0, Path: `res\bldg\test\rock01.bsr`},
		{TypeID: 2, Flags: 0, Path: `res\nature\test\grass01.bsr`},
	})

	table, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(table.Entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(table.Entries))
	}

	e, ok := table.Lookup(1)
	if !ok {
		t.Fatal("Lookup(1) failed")
	}
	if e.Path != `res\bldg\test\rock01.bsr` {
		t.Fatalf("Lookup(1).Path = %q, want rock01.bsr path", e.Path)
	}
	if e.Flags != 0 {
		t.Fatalf("Lookup(1).Flags = %d, want 0", e.Flags)
	}

	e0, ok := table.Lookup(0)
	if !ok || e0.Flags != 1 {
		t.Fatalf("Lookup(0) = %+v, ok=%v; want Flags=1", e0, ok)
	}
}

func TestLookupOutOfRange(t *testing.T) {
	data := buildSyntheticTable([]Entry{
		{TypeID: 0, Flags: 0, Path: `res\bldg\test\tree01.bsr`},
	})
	table, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if _, ok := table.Lookup(5); ok {
		t.Fatal("expected Lookup(5) to fail on a 1-entry table")
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	if _, err := Parse([]byte("NOT_REAL_MAGIC\n0\n")); err == nil {
		t.Fatal("expected error for bad magic, got nil")
	}
}

func TestParseRejectsMismatchedCount(t *testing.T) {
	data := magic + "\n5\n00000 0x00000000 \"res\\a.bsr\"\n"
	if _, err := Parse([]byte(data)); err == nil {
		t.Fatal("expected error when declared count exceeds real body lines, got nil")
	}
}

func TestParseRejectsMalformedRecord(t *testing.T) {
	data := magic + "\n1\nnot a real record line\n"
	if _, err := Parse([]byte(data)); err == nil {
		t.Fatal("expected error for a malformed record line, got nil")
	}
}
