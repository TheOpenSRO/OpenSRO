package systems

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot is two levels above the server module.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatalf("resolving the repo root: %v", err)
	}
	return root
}

func load(t *testing.T) (string, []Row) {
	t.Helper()
	root := repoRoot(t)
	rows, err := Parse(filepath.Join(root, "docs", "SYSTEMS.md"))
	if err != nil {
		t.Fatalf("parsing docs/SYSTEMS.md: %v", err)
	}
	return root, rows
}

// A row may not cite a spec document that does not exist. This is the failure
// that killed the work queue: it named probes for work already done, and
// nothing noticed.
func TestEverySpecDocumentExists(t *testing.T) {
	root, rows := load(t)
	for _, r := range rows {
		if r.Spec == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(root, r.Spec)); err != nil {
			t.Errorf("SYSTEMS.md:%d %q cites %s, which does not exist", r.Line, r.Name, r.Spec)
		}
	}
}

// SPECIFIED is a claim, and this is the claim's cost: it needs a document.
func TestSpecifiedRowsHaveASpec(t *testing.T) {
	_, rows := load(t)
	for _, r := range rows {
		if r.Status == Specified && r.Spec == "" {
			t.Errorf("SYSTEMS.md:%d %q is SPECIFIED with no spec document", r.Line, r.Name)
		}
	}
}

// The rot that mattered ran the other way: an item stayed marked open long
// after it was finished. A row claiming OPEN while carrying a spec is that
// failure, caught.
func TestOpenRowsDoNotCarryASpec(t *testing.T) {
	_, rows := load(t)
	for _, r := range rows {
		if r.Status == Open && r.Spec != "" {
			t.Errorf("SYSTEMS.md:%d %q is OPEN but cites %s -- if the spec exists the row has moved",
				r.Line, r.Name, r.Spec)
		}
	}
}

// An anchor is a Go identifier the row's claims rest on. If it disappears in a
// refactor the row is describing code that is gone, so the tracker has to know.
func TestAnchorsStillExistInTheServer(t *testing.T) {
	root, rows := load(t)
	srv := filepath.Join(root, "server")
	if _, err := exec.LookPath("grep"); err != nil {
		t.Skip("grep unavailable")
	}
	for _, r := range rows {
		for _, a := range r.Anchors {
			cmd := exec.Command("grep", "-rqlE", `\b`+a+`\b`, "--include=*.go", srv)
			if err := cmd.Run(); err != nil {
				t.Errorf("SYSTEMS.md:%d %q anchors on %q, which no longer appears in server/",
					r.Line, r.Name, a)
			}
		}
	}
}

// The headline number the loop reports each tick. Not an assertion about what
// it should be -- it fails only if the table stops being parseable, which is
// the one way the count could silently become a lie.
func TestCountsAreReportable(t *testing.T) {
	_, rows := load(t)
	spec, partial, open := Counts(rows)
	if spec+partial+open != len(rows) {
		t.Fatalf("counts %d+%d+%d do not add to %d rows", spec, partial, open, len(rows))
	}
	if len(rows) < 20 {
		t.Errorf("only %d systems in the tracker; the denominator was derived from 1,177 game "+
			"classes and should not shrink without a reason", len(rows))
	}
	t.Logf("systems: %d specified, %d partial, %d open (of %d)", spec, partial, open, len(rows))
}

// Every row needs a status the checker understands; a typo would otherwise drop
// a system out of the count silently.
func TestNoRowIsDroppedByATypo(t *testing.T) {
	root, _ := load(t)
	raw, err := os.ReadFile(filepath.Join(root, "docs", "SYSTEMS.md"))
	if err != nil {
		t.Fatal(err)
	}
	inTable := 0
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "|") || strings.Contains(line, "---") {
			continue
		}
		cells := splitRow(line)
		if len(cells) >= 5 && cells[0] != "System" {
			inTable++
		}
	}
	_, rows := load(t)
	if inTable != len(rows) {
		t.Errorf("the table has %d data rows but only %d parsed -- a status cell is misspelled",
			inTable, len(rows))
	}
}

// The prose headline in the document must agree with the table beneath it.
//
// This test earned its place the moment it was written: the first draft of
// SYSTEMS.md said "11 of 34 specified, 7 partial, 16 open" over a table holding
// 33 rows with 15 open. A summary drifting from its own table, in the file
// whose entire purpose is to stop summaries drifting, inside one edit.
func TestHeadlineMatchesTheTable(t *testing.T) {
	root, rows := load(t)
	raw, err := os.ReadFile(filepath.Join(root, "docs", "SYSTEMS.md"))
	if err != nil {
		t.Fatal(err)
	}
	spec, partial, open := Counts(rows)
	want := fmt.Sprintf("**%d specified, %d partial, %d open, of %d.**",
		spec, partial, open, len(rows))
	if !strings.Contains(string(raw), want) {
		t.Errorf("the headline does not match the table; it should read %q", want)
	}
}

// A row that is not finished must say what would finish it. "—" is a valid
// answer -- it means nothing is known to close it, which is itself information
// and is how Berserk's fill rate is recorded. What is not valid is silence: a
// row that stalled without recording why is how a pivot becomes a loose end.
func TestUnfinishedRowsRecordANextProbe(t *testing.T) {
	_, rows := load(t)
	for _, r := range rows {
		if r.Status == Specified {
			continue
		}
		if strings.TrimSpace(r.NextProbe) == "" {
			t.Errorf("SYSTEMS.md:%d %q is %s with no next probe recorded",
				r.Line, r.Name, r.Status)
		}
	}
}

// A finished row should not be carrying a probe that implies work remains.
func TestSpecifiedRowsDoNotClaimOutstandingWork(t *testing.T) {
	_, rows := load(t)
	for _, r := range rows {
		if r.Status != Specified {
			continue
		}
		if strings.Contains(strings.ToUpper(r.NextProbe), "BLOCKED") {
			t.Errorf("SYSTEMS.md:%d %q is SPECIFIED but its probe says BLOCKED",
				r.Line, r.Name)
		}
	}
}
