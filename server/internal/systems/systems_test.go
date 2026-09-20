package systems

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
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

// The tracker may not spell a function `FUN_<addr>` once this project has named
// the address. A probe reading "the five switch cases in `GObjPC::FUN_004fcef0`
// are not mapped" tells a cold reader the function is anonymous; it had been
// named `GObjPC::CheckCanSummonCOS` in recovered_names.tsv for a round and a
// half. Three rows carried superseded spellings when this test was written.
func TestProbesSpellFunctionsByTheirRecoveredNames(t *testing.T) {
	root, rows := load(t)
	names, err := RecoveredNames(filepath.Join(root, "docs", "protocol", "recovered_names.tsv"))
	if err != nil {
		t.Fatalf("loading recovered names: %v", err)
	}
	fun := regexp.MustCompile(`FUN_([0-9a-fA-F]{6,8})`)
	for _, r := range rows {
		for _, m := range fun.FindAllStringSubmatch(r.NextProbe, -1) {
			addr, err := strconv.ParseUint(m[1], 16, 64)
			if err != nil {
				continue
			}
			if name, ok := names[addr]; ok {
				t.Errorf("SYSTEMS.md:%d %q spells %s, but recovered_names.tsv names it %q",
					r.Line, r.Name, m[0], name)
			}
		}
	}
}

// unreadClaim matches a probe saying something is NOT KNOWN. It deliberately
// excludes "unwired", "unbuilt" and "unmeasured": those say the value is known
// and not yet used, which is a different and entirely honest state. Alchemy's
// "no handler runs `alchemy.Rate` yet" must not trip this.
var unreadClaim = regexp.MustCompile(`(?i)\b(unread|not mapped|unnamed|not recovered)\b`)

var backtickToken = regexp.MustCompile("`([^`]+)`")

// A row may not call something unread that its own spec document marks
// recovered.
//
// This is the failure TestEverySpecDocumentExists names in its comment -- "it
// named probes for work already done" -- and which nothing actually checked:
// the older tests confirm a spec EXISTS, never that the probe beside it is
// still open. The Pets and COS row asserted the COS switch cases and the hunger
// gauge were unread while pets.md carried both as struck-through "Recovered"
// bullets, from rounds 289 and 300.
func TestProbesDoNotContradictTheirSpec(t *testing.T) {
	root, rows := load(t)
	roundHeading := regexp.MustCompile(`(?i)round\s+\d+`)
	for _, r := range rows {
		if r.Spec == "" {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(root, r.Spec))
		if err != nil {
			continue // TestEverySpecDocumentExists owns that failure
		}
		// Lines the spec itself presents as settled: anything under a heading
		// that cites a round, plus any struck-through or "Recovered" bullet.
		lines := strings.Split(string(raw), "\n")
		settled := make(map[int]bool)
		underRound := false
		for n, l := range lines {
			if strings.HasPrefix(l, "#") {
				underRound = roundHeading.MatchString(l)
			}
			if underRound || strings.Contains(l, "**Recovered") || strings.Contains(l, "~~") {
				settled[n] = true
			}
		}
		for _, m := range unreadClaim.FindAllStringIndex(r.NextProbe, -1) {
			if negatedClaim(r.NextProbe, m[0]) {
				continue
			}
			lo, hi := clauseAround(r.NextProbe, m[0], m[1])
			for _, tok := range backtickToken.FindAllStringSubmatch(r.NextProbe[lo:hi], -1) {
				if len(tok[1]) < 5 {
					continue
				}
				for n := range settled {
					if strings.Contains(lines[n], tok[1]) {
						t.Errorf("SYSTEMS.md:%d %q calls %q unread, but %s:%d records it as recovered:\n    %s",
							r.Line, r.Name, tok[1], r.Spec, n+1, strings.TrimSpace(lines[n]))
						break
					}
				}
			}
		}
	}
}

// clauseAround returns the sentence or clause holding [lo, hi), so a claim is
// read against the tokens it is actually about.
//
// A fixed character window is not good enough, and this test's first run proved
// it: a probe that reads "...restoring `item[0x2a0] * 100` a feed). Pet growth
// is read too (round 291). Unread: the reference row..." had a recovered token
// 110 characters before the word "Unread", and the window flagged the row for
// contradicting itself when it had done no such thing. Clause boundaries are
// ". " and "; " -- not a bare period, which would split `1..5` and `alchemy.Rate`.
func clauseAround(s string, lo, hi int) (int, int) {
	start := 0
	for _, sep := range []string{". ", "; "} {
		if i := strings.LastIndex(s[:lo], sep); i >= 0 && i+len(sep) > start {
			start = i + len(sep)
		}
	}
	end := len(s)
	for _, sep := range []string{". ", "; "} {
		if i := strings.Index(s[hi:], sep); i >= 0 && hi+i < end {
			end = hi + i
		}
	}
	return start, end
}

// negatedClaim reports whether the word at i is the project announcing that
// something is NO LONGER unread, which is the opposite of a stale probe.
//
// The Skills and masteries row is the reason: it reads "`'efr'` is NOT a buff
// code and is no longer unread: it is the skill's TARGET PATTERN (round 265)".
// That sentence is the tracker working exactly as intended, and a checker that
// flagged it would train the next reader to silence the checker.
func negatedClaim(s string, i int) bool {
	before := strings.ToLower(s[:i])
	for _, neg := range []string{"no longer ", "not ", "never "} {
		if strings.HasSuffix(before, neg) {
			return true
		}
	}
	return false
}
