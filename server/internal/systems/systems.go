// Package systems parses docs/SYSTEMS.md, the project's completion tracker, so
// a test can hold it to the repository it describes.
//
// WHY THIS EXISTS. This project has had two forward-looking summaries and both
// rotted. `docs/RE_COMPLETION.md`'s work queue listed three of seven items as
// open after they had shipped -- one of them told a reader srrevamp "still runs
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
