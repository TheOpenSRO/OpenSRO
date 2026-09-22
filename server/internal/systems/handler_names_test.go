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

// A handler row may not still read FUN_<addr> when recovered_names.tsv has a
// name for that same address.
func TestHandlerTableNamesAreNotStale(t *testing.T) {
	root := repoRoot(t)
	names := recoveredNames(t, root)

	f, err := os.Open(filepath.Join(root, "docs", "protocol", "server_handlers.tsv"))
	if err != nil {
		t.Fatalf("opening server_handlers.tsv: %v", err)
	}
	defer f.Close()

	var checked int
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		cols := strings.Split(sc.Text(), "\t")
		if len(cols) < 3 || cols[0] == "index" {
			continue
		}
		addr, listed := strings.ToLower(cols[1]), cols[2]
		if len(addr) != 8 {
			continue
		}
		checked++
		if !placeholderName.MatchString(listed) {
			continue
		}
		if real, ok := names[addr]; ok && !placeholderName.MatchString(real) {
			t.Errorf("server_handlers.tsv index %s lists %s for %s, but recovered_names.tsv names it %s -- refresh the table's name column",
				cols[0], listed, addr, real)
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("reading server_handlers.tsv: %v", err)
	}
	if checked < 100 {
		t.Fatalf("only %d handler rows parsed -- the probe is broken, not the data", checked)
	}
}
