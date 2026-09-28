package skillparam

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// The client walks a skill's Param block too: the buff bar (round 618) reads
// the cbuf/nbuf/bbuf/lnks tags off the client's own skilldata, through
// client/scripts/ui/hud/skill_buff_catalog.gd, whose RUN table is this
// package's Run copied by hand. A run length that drifts on either side
// derails the client's walk from that code on, silently -- so this fails if
// the two tables differ in any code or length.
//
// It reads the .gd at run time, which Go's test cache does not see: run it
// with -count=1 (docs: the doc-probe test-cache note).
func TestClientRunTableMatchesRun(t *testing.T) {
	path := filepath.Join("..", "..", "..", "client", "scripts", "ui", "hud", "skill_buff_catalog.gd")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	text := string(src)
	start := strings.Index(text, "const RUN := {")
	if start < 0 {
		t.Fatalf("%s has no `const RUN := {` block", path)
	}
	end := strings.Index(text[start:], "\n}")
	if end < 0 {
		t.Fatalf("%s: the RUN block never closes", path)
	}
	block := text[start : start+end]
	pair := regexp.MustCompile(`"([a-zA-Z0-9]{1,4})":\s*(\d+)`)
	client := map[Code]int{}
	for _, m := range pair.FindAllStringSubmatch(block, -1) {
		n, _ := strconv.Atoi(m[2])
		if _, dup := client[Code(m[1])]; dup {
			t.Errorf("client RUN lists %q twice", m[1])
		}
		client[Code(m[1])] = n
	}
	if len(client) != len(Run) {
		t.Errorf("client RUN has %d codes, Run has %d", len(client), len(Run))
	}
	for c, n := range Run {
		if got, ok := client[c]; !ok {
			t.Errorf("client RUN lacks %q (run %d)", c, n)
		} else if got != n {
			t.Errorf("client RUN[%q] = %d, Run = %d", c, got, n)
		}
	}
	for c := range client {
		if _, ok := Run[c]; !ok {
			t.Errorf("client RUN has %q, which Run does not", c)
		}
	}
	for _, tag := range []Code{"cbuf", "nbuf", "bbuf"} {
		if Kind[tag] != KindMarker || Run[tag] != 1 {
			t.Errorf("%q is expected to be a run-1 marker (the buff bar reads its presence)", tag)
		}
	}
}
