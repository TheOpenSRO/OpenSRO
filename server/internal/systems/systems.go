// Package systems parses docs/SYSTEMS.md, the project's completion tracker, so
// a test can hold it to the repository it describes.
//
// WHY THIS EXISTS. This project has had two forward-looking summaries and both
// rotted. `docs/RE_COMPLETION.md`'s work queue listed three of seven items as
// open after they had shipped -- one of them told a reader OpenSRO "still runs
// base + bonus - defence" months after the real formula went in.
// `docs/GROUNDING_AUDIT.md` told readers the server binary was "a third-party
// emulator bundle, not authoritative", which discounted the artifact most of
// this project's recovered values come from. Both were corrected on 2026-09-17,
// and both had been wrong for weeks, because nothing re-read them.
//
// The detailed entries in those files never rotted -- they are append-only, and
// a new entry corrects an old one in place. It is the SUMMARIES that decay,
// because they make claims about the present. So the rule this package enforces
// is narrow: a summary row may not claim something the repository contradicts.
package systems

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// Status is a system's position on the one bar that matters: is its behaviour
// written down completely enough to implement faithfully.
type Status string

const (
	// Specified means the system clears the bar docs/SYSTEMS.md sets: entry
	// points named, an ordered spec with citations, every value grounded or
	// disclosed with a proven reason.
	Specified Status = "SPECIFIED"
	// Partial means some of it is recovered and the gap is named.
	Partial Status = "PARTIAL"
	// Open means no spec exists yet.
	Open Status = "OPEN"
)

// Row is one system in the tracker.
type Row struct {
	Name    string
	Classes string
	Status  Status
	Spec    string   // repo-relative path, or "" when the row declares none
	Anchors []string // Go identifiers the spec's claims rest on
	// NextProbe is what would close the row, for anything not SPECIFIED. It
	// may say that nothing is known to -- what it may not do is be absent,
	// because a row that has stalled without recording why is how a pivot
	// turns into a loose end.
	NextProbe string
	Line      int
}

// Parse reads the tracker at path. It returns the rows in file order.
//
// The table is markdown, which is a deliberate choice over a data format: the
// file has to stay readable as a document, because a tracker nobody reads is
// how the last two summaries died.
func Parse(path string) ([]Row, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var rows []Row
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "|") {
			continue
		}
		cells := splitRow(line)
		if len(cells) < 6 {
			continue
		}
		st := Status(strings.TrimSpace(cells[2]))
		if st != Specified && st != Partial && st != Open {
			continue // the header and the |---| separator land here
		}
		spec := strings.TrimSpace(cells[3])
		if spec == "—" || spec == "-" {
			spec = ""
		}
		var anchors []string
		for _, a := range strings.Split(cells[4], ",") {
			if a = strings.TrimSpace(a); a != "" {
				anchors = append(anchors, a)
			}
		}
		rows = append(rows, Row{
			Name:      strings.TrimSpace(cells[0]),
			Classes:   strings.TrimSpace(cells[1]),
			Status:    st,
			Spec:      spec,
			Anchors:   anchors,
			NextProbe: strings.TrimSpace(cells[5]),
			Line:      lineNo,
		})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("systems: %s parsed to zero rows -- the table shape changed", path)
	}
	return rows, nil
}

func splitRow(line string) []string {
	line = strings.TrimPrefix(line, "|")
	line = strings.TrimSuffix(line, "|")
	parts := strings.Split(line, "|")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

// Counts summarises the tracker, which is the number worth reporting.
func Counts(rows []Row) (specified, partial, open int) {
	for _, r := range rows {
		switch r.Status {
		case Specified:
			specified++
		case Partial:
			partial++
		case Open:
			open++
		}
	}
	return
}

// RecoveredNames maps an address to the name this project gave the function
// there, read from docs/protocol/recovered_names.tsv.
//
// The tracker needs it for one narrow purpose: prose that still spells a
// function `FUN_<addr>` after the project has named it reads as though the
// function were anonymous. That is not cosmetic. Round 301's error-emitter
// sweep listed `GObjPC::FUN_004a9050` among its unnamed yield while
// `ground_items.md` had already read that function in full, and the wasted pass
// is what round 302 had to go back and reconcile.
//
// THERE ARE TWO NAME SOURCES, and reading only this one understates what the
// project has named (round 305). `client/tools/ghidra/ApplyKnownNames.java`
// carries a second, hardcoded table of 191 names, 152 of which appear nowhere
// else. KnownNamesJava reads it, and AllRecoveredNames merges the two.
func RecoveredNames(path string) (map[uint64]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	names := make(map[uint64]string)
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 3 {
			continue
		}
		addr, err := strconv.ParseUint(strings.TrimSpace(fields[0]), 16, 64)
		if err != nil {
			continue
		}
		if name := strings.TrimSpace(fields[2]); name != "" {
			names[addr] = name
		}
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("systems: %s yielded no names -- the file's shape changed", path)
	}
	return names, nil
}

// knownNameRow matches a row of ApplyKnownNames.java's hardcoded table, which
// is written as {"00952890", "Client_LoadRefDataFile", ...}.
var knownNameRow = regexp.MustCompile(`\{"([0-9a-fA-F]{6,8})",\s*"([^"]+)"`)

// KnownNamesJava reads the second name source, the table compiled into
// client/tools/ghidra/ApplyKnownNames.java.
//
// It exists because a name can be applied to the Ghidra project from either
// file, so a checker that consults only recovered_names.tsv will report a
// function as anonymous when the project has in fact named it. Round 305 found
// 152 names living only here.
func KnownNamesJava(path string) (map[uint64]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	names := make(map[uint64]string)
	for _, m := range knownNameRow.FindAllStringSubmatch(string(raw), -1) {
		addr, err := strconv.ParseUint(m[1], 16, 64)
		if err != nil {
			continue
		}
		names[addr] = m[2]
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("systems: %s yielded no names -- the table's shape changed", path)
	}
	return names, nil
}

// AllRecoveredNames merges both sources. The TSV wins a disagreement: it is the
// file the project maintains per round, and where the two overlap the Java
// table is generally the older, cruder name (`GetSingleton_00d6a950` against
// `GetSingleton_COverlappedJobMgr`). 34 of the 39 overlapping addresses
// disagreed when this was written; see docs/protocol/naming_ceiling.md.
func AllRecoveredNames(tsvPath, javaPath string) (map[uint64]string, error) {
	merged := map[uint64]string{}
	java, err := KnownNamesJava(javaPath)
	if err != nil {
		return nil, err
	}
	for a, n := range java {
		merged[a] = n
	}
	tsv, err := RecoveredNames(tsvPath)
	if err != nil {
		return nil, err
	}
	for a, n := range tsv {
		merged[a] = n
	}
	return merged, nil
}
