// Package safezone is which regions of the world are towns: the regions a
// monster cannot be in (round 674).
//
// THE RULE, READ from SR_GameServer.exe (docs/protocol/monster_ai.md, "Towns:
// a monster that walks into one is removed"):
//
//   - A region's kind is its _RefRegion row's IsBattleField byte. The row
//     parser (0x6a2e40) reads wRegionID into the record's +0, skips the X and
//     Z bytes, reads ContinentName and AreaName, then stores the next byte --
//     the table's sixth column -- at +2. A field region (CRgnTerrain) keeps
//     its row at +0x10 (CMainProcess::FUN_0053b6f0 / FUN_0053b540 read the id
//     back through it), and every town test in the binary reads
//     *(region+0x10)+2.
//   - CGObjMob's SetCurRegion (vtable slot 235, 0x4c1270) is
//     `this+0x128 = region; if (region == 0 || region.row[+2] == 0)
//     SetLifeState(3, 0xff, 0)`. Life state 3 is removal: the main loop
//     (CMainProcess::FUN_00413b30) hands every non-player object in state 3
//     to FUN_00417090, which deletes it, and SetLifeState (0x4a9c80)
//     broadcasts only the 1<->2 changes -- so no death, no reward, no drop.
//   - Slot 235's one call site (0x485ad4) is in the region change of
//     FUN_004858e0, which runs whenever an object's position moves it into
//     another region, or into its first: its one caller FUN_00485740 is
//     reached from the object's MoveTo (vtable slot 231; CGObjMob's is
//     0x48b660), which CGObj::EnterWorld also calls ("at MoveTo()"). The
//     region-entry veto before it (slot 220) is a bare `return 1` for
//     CGObjMob (0x9856e0), so a monster always enters -- and is removed.
//   - Nothing else keeps a monster out: CGObjMob's attack check (slot 394,
//     0x529110), the AI's target validity (0x540de0) and its acquisition
//     selector (0x5464e0) test no region. A monster still standing in a
//     field region can therefore pick and hit a player inside the town's
//     edge; it cannot follow her in.
//
// The same byte is the PC's PvP gate (CGObjPC slot 394, 0x5293a0: 0x3018
// ITS_NOT_A_BATTLE_FIELD when either side's region is 0), the skill gate's
// row 13 (0x58e186), and the thief's cart refusal at a town's edge (CGObjPC
// slot 220, 0x4eb220, 0x0c01 ROBBER_CANT_ENTER_TOWN_WITH_CART). Those are not
// built here.
//
// The server does NOT use regioninfo.txt's #TOWN sections for this: it parses
// them (RegionManagerBody::FUN_0098be30), but the region manager's town query
// (CRegionManagerBody slot 23, 0x98d040) has no caller in the game server.
// That file is the client's (docs/protocol/REGIONINFO_FORMAT.md).
//
// DATA: the table is _RefRegion. The client's Media.pk2 carries a copy,
// server_dep\silkroad\textdata\refregion.txt (UTF-16, 21 tab-separated
// columns), which cmd/export-refdata -mode regions turns into the CSV this
// package reads; cmd/server loads it with -regions-csv. The repo holds no
// row of it (docs/LEGAL.md).
package safezone

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// CSVColumns is the header of the CSV cmd/export-refdata -mode regions writes
// and Read reads: refregion.txt's columns 0, 3, 4 and 5.
var CSVColumns = []string{"RegionID", "ContinentName", "AreaName", "IsBattleField"}

// Region is one _RefRegion row as the rule needs it.
type Region struct {
	// ID is wRegionID: x in the high byte, y in the low (worldmap.RegionID);
	// a dungeon's id is negative in the table (bit 15 set, as a signed short).
	ID int
	// Continent and Area are the row's ContinentName and AreaName, kept for
	// the log line only.
	Continent, Area string
	// Battlefield is IsBattleField != 0. A region whose byte is 0 is a town:
	// a monster that enters it is removed (the package note).
	Battlefield bool
}

// Safe reports whether r is a region a monster is removed in: its
// IsBattleField byte is 0 (CGObjMob::SetCurRegion's `== '\0'`).
func (r Region) Safe() bool { return !r.Battlefield }

// Table is the regions by id.
type Table struct {
	byID map[int]Region
	safe int
}

// Len is the number of regions the table holds.
func (t *Table) Len() int {
	if t == nil {
		return 0
	}
	return len(t.byID)
}

// SafeCount is how many of them are towns.
func (t *Table) SafeCount() int {
	if t == nil {
		return 0
	}
	return t.safe
}

// Region is the row for region id, if the table has one.
func (t *Table) Region(id int) (Region, bool) {
	if t == nil {
		return Region{}, false
	}
	r, ok := t.byID[id]
	return r, ok
}

// SafeAt reports whether region id is a town, with its row. A region the
// table does not list is NOT safe: OURS -- retail's rule also removes a
// monster with no region at all (`region == 0`), but such a monster has no
// navigation mesh to stand on there, while here a region missing from an
// operator's CSV would remove every monster that walked into it.
func (t *Table) SafeAt(id int) (Region, bool) {
	r, ok := t.Region(id)
	if !ok || !r.Safe() {
		return Region{}, false
	}
	return r, true
}

// New builds a table from rows; the later of two rows for one id wins.
func New(rows []Region) *Table {
	t := &Table{byID: make(map[int]Region, len(rows))}
	for _, r := range rows {
		t.byID[r.ID] = r
	}
	for _, r := range t.byID {
		if r.Safe() {
			t.safe++
		}
	}
	return t
}

// Read reads the CSV CSVColumns heads. A row whose id or flag is not a
// number is an error that names it: a mis-split table would otherwise leave
// a town out without a word.
func Read(r io.Reader) (*Table, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	header, err := cr.Read()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("safezone: empty file, want the header %s", strings.Join(CSVColumns, ","))
		}
		return nil, fmt.Errorf("safezone: reading the header: %w", err)
	}
	if len(header) < len(CSVColumns) {
		return nil, fmt.Errorf("safezone: header %q, want %s", strings.Join(header, ","), strings.Join(CSVColumns, ","))
	}
	for i, want := range CSVColumns {
		if strings.TrimSpace(strings.TrimPrefix(header[i], "\ufeff")) != want {
			return nil, fmt.Errorf("safezone: header column %d is %q, want %q", i, header[i], want)
		}
	}
	var rows []Region
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("safezone: row %d: %w", line, err)
		}
		if len(rec) < len(CSVColumns) {
			return nil, fmt.Errorf("safezone: row %d has %d fields, want %d", line, len(rec), len(CSVColumns))
		}
		id, err := strconv.Atoi(strings.TrimSpace(rec[0]))
		if err != nil {
			return nil, fmt.Errorf("safezone: row %d: RegionID %q is not a number", line, rec[0])
		}
		flag, err := strconv.Atoi(strings.TrimSpace(rec[3]))
		if err != nil {
			return nil, fmt.Errorf("safezone: row %d: IsBattleField %q is not a number", line, rec[3])
		}
		rows = append(rows, Region{ID: id, Continent: strings.TrimSpace(rec[1]), Area: strings.TrimSpace(rec[2]), Battlefield: flag != 0})
	}
	if len(rows) == 0 {
		return nil, errors.New("safezone: the file has a header and no region")
	}
	return New(rows), nil
}

// Load reads the CSV at path.
func Load(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Read(f)
}
