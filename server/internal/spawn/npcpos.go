// Package spawn reads the game's own monster placements.
//
// The client's npcpos.txt (server_dep\silkroad\textdata) is the placement
// table: one row per spawn, `objectId regionId localX localY localZ`, 12,367
// rows in a retail archive of which 12,110 are MOB_* species. The region id
// packs this project's region axes as (x << 8) | y (Jangan's 97/168 is 25000),
// and the positions are local to that region -- worldmap.ToZoneWorld turns
// them into a zone's world coordinates. cmd/export-refdata -mode npcpos writes
// the CSV; cmd/server's -npcpos-csv loads it, and every roster species with
// rows in it stands where the game puts it instead of at an own-design anchor
// (until 2026-09-19 only Mangyang did, from four embedded rows).
package spawn

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// NpcPosCSVColumns is the header cmd/export-refdata -mode npcpos writes.
var NpcPosCSVColumns = []string{"ObjectID", "RegionID", "LocalX", "LocalY", "LocalZ"}

// Placement is one npcpos row, in the table's own terms.
type Placement struct {
	ObjectID       int64
	RegionID       int
	LocalX, LocalZ float64
	LocalY         float64
}

// Table is every placement, keyed by the species' characterdata id.
type Table map[int64][]Placement

// LoadCSV reads an npcpos CSV. Missing file -> an empty table and no error is
// NOT what it does: a path that was configured and cannot be read is an error,
// so a typo cannot silently put every species back on its anchor.
func LoadCSV(path string) (Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Read(f)
}

// Read parses npcpos CSV text: a header row (checked), then rows of
// ObjectID,RegionID,LocalX,LocalY,LocalZ.
func Read(r io.Reader) (Table, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("spawn: reading header: %w", err)
	}
	if len(header) < 5 || strings.TrimSpace(header[0]) != NpcPosCSVColumns[0] {
		return nil, fmt.Errorf("spawn: not an npcpos CSV (header %q)", header)
	}
	t := Table{}
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("spawn: line %d: %w", line, err)
		}
		if len(rec) < 5 {
			return nil, fmt.Errorf("spawn: line %d: %d fields, want 5", line, len(rec))
		}
		id, err := strconv.ParseInt(strings.TrimSpace(rec[0]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("spawn: line %d: object id %q", line, rec[0])
		}
		region, err := strconv.Atoi(strings.TrimSpace(rec[1]))
		if err != nil {
			return nil, fmt.Errorf("spawn: line %d: region id %q", line, rec[1])
		}
		x, err1 := strconv.ParseFloat(strings.TrimSpace(rec[2]), 64)
		y, err2 := strconv.ParseFloat(strings.TrimSpace(rec[3]), 64)
		z, err3 := strconv.ParseFloat(strings.TrimSpace(rec[4]), 64)
		if err1 != nil || err2 != nil || err3 != nil {
			return nil, fmt.Errorf("spawn: line %d: position %q %q %q", line, rec[2], rec[3], rec[4])
		}
		t[id] = append(t[id], Placement{ObjectID: id, RegionID: region, LocalX: x, LocalY: y, LocalZ: z})
	}
	return t, nil
}

// Rows returns a species' placements (nil when it has none).
func (t Table) Rows(objectID int64) []Placement { return t[objectID] }
