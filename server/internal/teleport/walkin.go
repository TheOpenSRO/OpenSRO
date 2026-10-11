package teleport

// The walk-in teleports (round 773): portals a player walks into rather than
// clicks -- the Donwhang cave's mouth, the Qin-Shi tomb's door, and the
// tomb's own floor-to-floor passages.
//
// READ (docs/protocol/dungeon.md, "Walk-in teleports"): the trigger is a
// region event. Media's eventzonedata.txt (_RefEventZone) names each event
// zone; a TELEPORT row's first string parameter is the teleportdata codename
// the server resolves to a point (ReferenceData::FUN_006a7650, stored into the
// row's fifth int). The area is an event byte on the cells or edges of the
// placed object's navmesh (.bms); Data.pk2's navmesh\objectstring.ifo names
// each zone's centre -- `uid 0 rx rz x y z yaw "NAME"`, MEASURED equal to the
// centre of the mesh's trigger cells as placed (both open-world entrances).
// The game server fires the zone as a mover walks across it
// (FUN_009b4cd0 -> CGObjPC::vslot_309, 0x4ef480): the point must have
// exactly one link, its restrictions are evaluated (FUN_00513a70) with no fee,
// and the character is moved to the link's destination.
//
// OURS, disclosed: the area. OpenSRO's server reads no navmesh, so a zone is
// a circle about objectstring's centre (WalkInRadius) and a height band
// (WalkInHeight), not the mesh's own cells.

import (
	"io"
	"os"
	"path/filepath"
)

// WalkInsFile is the optional fourth CSV of a teleport export
// (cmd/export-refdata -mode teleport with eventzonedata.txt and
// objectstring.ifo given); Load reads it when it is there.
const WalkInsFile = "walkin.csv"

// WalkInCSVColumns is walkin.csv's header.
var WalkInCSVColumns = []string{"Code", "PointID", "Region", "X", "Y", "Z"}

// WalkInRadius is a walk-in zone's horizontal reach about its centre (OURS):
// the three trigger areas measured are squares 28 to 32 units wide (the
// Donwhang cave's mouth 31.7 x 30.1, its inside 28 x 28, the tomb door
// 30 x 29.9), so 15 -- their inscribed circle -- fires nowhere the real
// square would not.
const WalkInRadius = 15.0

// WalkInHeight is how far above or below the centre a mover may be and still
// be in the zone (OURS): the measured trigger cells are flat, and a dungeon's
// floors stack well over this apart.
const WalkInHeight = 40.0

// WalkIn is one walk-in zone: the teleportdata point it fires and where it
// is. Region is the region id (a dungeon's with bit 15, as the table's u16);
// X, Y, Z the centre, local to the region in the field, dungeon space in a
// dungeon.
type WalkIn struct {
	Code    string
	PointID int
	Region  int
	X, Y, Z float64
}

// loadWalkIns reads dir's walkin.csv into t; a missing file is no walk-ins.
func (t *Table) loadWalkIns(dir string) error {
	f, err := os.Open(filepath.Join(dir, WalkInsFile))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	return t.ReadWalkIns(f)
}

// ReadWalkIns parses a walkin.csv into t, replacing what it had. A row whose
// point is not in t is refused: the files come from one export.
func (t *Table) ReadWalkIns(r io.Reader) error {
	rows, err := readCSV(r, WalkInCSVColumns, WalkInsFile)
	if err != nil {
		return err
	}
	out := make([]WalkIn, 0, len(rows))
	for i, rec := range rows {
		n, err := ints(rec, WalkInCSVColumns, 1, 2)
		if err != nil {
			return errorf("teleport: %s line %d: %w", WalkInsFile, i+2, err)
		}
		var xyz [3]float64
		for k := 0; k < 3; k++ {
			v, err := parseFloat(rec[3+k])
			if err != nil {
				return errorf("teleport: %s line %d: %s %q is not a number", WalkInsFile, i+2, WalkInCSVColumns[3+k], rec[3+k])
			}
			xyz[k] = v
		}
		if _, ok := t.PointByID(n[0]); !ok {
			return errorf("teleport: %s line %d: point %d is not in %s", WalkInsFile, i+2, n[0], PointsFile)
		}
		out = append(out, WalkIn{Code: rec[0], PointID: n[0], Region: int(uint16(n[1])), X: xyz[0], Y: xyz[1], Z: xyz[2]})
	}
	t.WalkIns = out
	return nil
}
