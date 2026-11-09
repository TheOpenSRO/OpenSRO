package main

import (
	"bytes"
	"testing"
)

// A one-row 0xB47D page in the spec's MatchRow layout: the guardian's entry
// is found by name, another name is not.
func TestMatchEntryOf(t *testing.T) {
	row := cat(le32(7), le32(0x65), []byte{1}, lestr("Join us"), le32(1700000000), []byte{70, 70},
		le32(1907), lestr("Guardian1"), le32(0), []byte{5}, le32(1), le32(1))
	page := cat([]byte{1, 1, 0, 1}, row)
	if got := matchEntryOf(page, "Guardian1"); got != 7 {
		t.Fatalf("entry %d, want 7", got)
	}
	if got := matchEntryOf(page, "Other"); got != 0 {
		t.Fatalf("another guardian matched entry %d", got)
	}
	two := cat([]byte{1, 1, 0, 2}, row, bytes.Replace(row, []byte("Guardian1"), []byte("Guardian2"), 1))
	two[4] = 9
	if got := matchEntryOf(two, "Guardian2"); got != 7 {
		t.Fatalf("second row entry %d, want 7", got)
	}
	if got := matchEntryOf([]byte{1, 0, 0, 0}, "Guardian1"); got != 0 {
		t.Fatalf("empty page gave %d", got)
	}
}
