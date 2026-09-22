package systems

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// This project keeps the same fact in more than one derived table, and the
// copies rot. The work queue rotted, GROUNDING_AUDIT rotted, and on 2026-09-22
// docs/protocol/server_handlers.tsv was found carrying `FUN_<addr>` for eleven
// dispatch handlers that recovered_names.tsv had named rounds earlier. Round 470
// then measured two naming levers against that inflated list and reported 69
// unnamed handlers when the real count was 58.
//
// Nothing caught it because every existing check asks whether a file is
// well-formed, not whether it AGREES with the file it was derived from. This one
// asks that.
//
// It is a pure doc-vs-doc comparison, so it needs no dump and runs in CI. Note
// that it reads the docs at RUNTIME, which Go's test cache does not see -- run
// `go test -count=1` or a stale PASS is possible.

var placeholderName = regexp.MustCompile(`FUN_[0-9a-f]{8}$`)

// recoveredNames maps address -> name from docs/protocol/recovered_names.tsv,
// keeping only server rows.
func recoveredNames(t *testing.T, root string) map[string]string {
	t.Helper()
	f, err := os.Open(filepath.Join(root, "docs", "protocol", "recovered_names.tsv"))
	if err != nil {
		t.Fatalf("opening recovered_names.tsv: %v", err)
	}
	defer f.Close()

	out := map[string]string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<22)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) < 3 || cols[1] != "server" {
			continue
		}
		out[strings.ToLower(cols[0])] = cols[2]
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("reading recovered_names.tsv: %v", err)
	}
	if len(out) < 100 {
		t.Fatalf("recovered_names.tsv yielded only %d server rows -- the probe is broken, not the data", len(out))
	}
	return out
}

// derivedTable is a docs/protocol table carrying a server address alongside the
// name that address had when the table was generated.
type derivedTable struct {
	file    string
	addrCol int
	nameCol int
	minRows int
	// remedy says what a stale row means for this file. described_but_unnamed
	// is a WORKLIST of functions the dump still calls FUN_, so a named one does
	// not belong in it at all; the others just carry a display name.
	remedy string
}

var derivedTables = []derivedTable{
	{"server_handlers.tsv", 1, 2, 100, "refresh the table's name column"},
	{"handler_payloads.tsv", 1, 2, 100, "refresh the table's name column"},
	{"described_but_unnamed.tsv", 1, 2, 300, "DROP the row -- this file lists functions the dump still calls FUN_, so a named one is finished work still on a worklist"},
}

// No derived table may still read FUN_<addr> when recovered_names.tsv has a name
// for that same address.
func TestDerivedTableNamesAreNotStale(t *testing.T) {
	root := repoRoot(t)
	names := recoveredNames(t, root)

	for _, tbl := range derivedTables {
		t.Run(tbl.file, func(t *testing.T) {
			f, err := os.Open(filepath.Join(root, "docs", "protocol", tbl.file))
			if err != nil {
				t.Fatalf("opening %s: %v", tbl.file, err)
			}
			defer f.Close()

			var checked int
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 0, 1<<20), 1<<22)
			for sc.Scan() {
				line := sc.Text()
				if strings.HasPrefix(line, "#") || strings.HasPrefix(line, "index") {
					continue
				}
				cols := strings.Split(line, "\t")
				if len(cols) <= tbl.nameCol || len(cols) <= tbl.addrCol {
					continue
				}
				addr := strings.ToLower(strings.TrimSpace(cols[tbl.addrCol]))
				listed := strings.TrimSpace(cols[tbl.nameCol])
				if len(addr) != 8 {
					continue
				}
				checked++
				if !placeholderName.MatchString(listed) {
					continue
				}
				if real, ok := names[addr]; ok && !placeholderName.MatchString(real) {
					t.Errorf("%s lists %s for %s, but recovered_names.tsv names it %s -- %s",
						tbl.file, listed, addr, real, tbl.remedy)
				}
			}
			if err := sc.Err(); err != nil {
				t.Fatalf("reading %s: %v", tbl.file, err)
			}
			if checked < tbl.minRows {
				t.Fatalf("only %d rows parsed from %s -- the probe is broken, not the data", checked, tbl.file)
			}
		})
	}
}
