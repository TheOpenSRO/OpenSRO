package refdata

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRecoveredNamesFileIsWellFormed guards docs/protocol/recovered_names.tsv,
// the list of names this project has read out of the binaries but not yet
// written back into the Ghidra projects.
//
// It cannot check the addresses from here -- those live on the RE box -- but it
// can catch the mistakes that made the file wrong the first time it was
// written: two rows were labelled `client` for functions that are in the SERVER
// dump. A malformed row would fail silently in the Ghidra applier, which prints
// and moves on.
//
// The address half now has a tool of its own,
// `client/tools/re/verify_recovered_addresses.py`, which runs where the dumps
// are and classifies every row as start / interior / wrong-binary / outside.
// Run 2026-09-20 over all 2,416 rows: 2,415 function starts, no interior
// addresses, no mislabelled binaries, and the single `outside` is the dump gap
// at 0x587260 that AGENTS.md already records.
func TestRecoveredNamesFileIsWellFormed(t *testing.T) {
	path := filepath.Join("..", "..", "..", "docs", "protocol", "recovered_names.tsv")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("recovered_names.tsv not readable from here: %v", err)
	}

	seen := map[string]string{}
	rows := 0
	for i, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 5 {
			t.Errorf("line %d: %d fields, want address/binary/name/origin/evidence", i+1, len(f))
			continue
		}
		rows++
		addr, binary, name, origin, evidence := f[0], f[1], f[2], f[3], f[4]

		if len(addr) != 8 || strings.TrimLeft(addr, "0123456789abcdef") != "" {
			t.Errorf("line %d: %q is not an 8-digit lowercase hex address", i+1, addr)
		}
		if binary != "server" && binary != "client" {
			t.Errorf("line %d: binary %q, want server or client", i+1, binary)
		}
		// The three origins the file's own header documents. `reading` was
		// missing from this check until 2026-09-17 even though 191 of the 302
		// rows use it -- so this test failed on every run for as long as those
		// rows have existed, and was reported as passing because the runs were
		// piped through `head`, which truncated the output.
		switch origin {
		case "engine", "descriptive", "reading":
		default:
			t.Errorf("line %d: origin %q, want engine, descriptive or reading", i+1, origin)
		}
		if strings.TrimSpace(evidence) == "" {
			t.Errorf("line %d (%s): no evidence; a name without one is a guess", i+1, name)
		}
		if name == "" || strings.HasPrefix(name, "FUN_") || strings.Contains(name, "vslot_") {
			t.Errorf("line %d: %q is not a recovered name", i+1, name)
		}
		key := binary + "/" + addr
		if prev, dup := seen[key]; dup {
			t.Errorf("line %d: %s listed twice (%q and %q)", i+1, key, prev, name)
		}
		seen[key] = name
	}
	if rows == 0 {
		t.Fatal("no rows; the file exists to carry names, not to be empty")
	}
	t.Logf("%d recovered names awaiting application to the Ghidra projects", rows)
}
