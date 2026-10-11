package teleport

// The reverse return scroll's map points (round 778): the client's
// refoptionalteleport.txt, the server's _REFOPTIONALTELEPORT
// (CRefOptionalTeleport, refdata_tables.md). docs/protocol/
// reverse_return_scroll.md has the whole system; this file is the table.
//
// READ (the client's parser, GlobalDataManager::Client_LoadRefDataFile case
// 0x4e, 0x956ba0..0x956d56): column 0 is the service flag (the row is parsed
// only when it is non-zero, FUN_00b9cc80), then the id (record +0), the
// object name and the zone name (two strings, +0x20 the zone's SN_ZONE_ key),
// the region word (+0x3c), x, y, z as floats (+0x40/+0x44/+0x48), the world
// id (+0x4c), the region group (+0x50) and the map-point byte (+0x54). The
// client draws a world-map icon for every row whose map-point byte is 1
// (GlobalDataManager::FUN_00927850, `*(char *)(rec + 0x54) == 1`) and lists,
// for an icon whose group is not -1, the rows of that group whose byte is not
// 1 (CNIFWorldMap::vslot_017 0x6236e2..0x623761) -- the Donwhang cave's
// floor under its entrance's flag.
//
// READ (the server, SR_GameServer): the scroll's map option looks the id up
// (FUN_004a1f00 on the ref manager's +0xa8c map, 0x4a01eb), refuses a record
// with no region (`cmp WORD PTR [edx],0` at 0x4a01f9, code 2), tests the
// user's level with FUN_004a1ed0 against the record's +0x2e / +0x30 (refused
// 0x18fd), and the arrival copies the record's region and its x, y, z words
// as floats and its world word (AJStateChanger::FUN_004076f0: +0x20 -> the
// region, +0x26/+0x28/+0x2a, +0x2c) -- the point exactly, no scatter.
//
// INFERRED: that columns 11 and 12 are those two level words. The client
// does not read them; their values (0 0 on the town rows, 50 999 on the
// Donwhang cave's floor, 90 999 on the Arabian rows) and FUN_004a1ed0's
// shape (a range test that applies only when both are non-zero) are the
// evidence, and the server's table names them LevelMin/LevelMax in the
// usual schema. Columns 13..18 (three param/description pairs, -1 / xxx in
// every retail row) are not read by either binary's path traced here.

import (
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
)

// OptionalFile is the optional fifth CSV of a teleport export
// (cmd/export-refdata -mode teleport, given refoptionalteleport.txt).
const OptionalFile = "optionalteleport.csv"

// OptionalCSVColumns is optionalteleport.csv's header.
var OptionalCSVColumns = []string{"ID", "ZoneName", "Region", "X", "Y", "Z", "WorldID", "Group", "MapPoint", "LevelMin", "LevelMax"}

// NoGroup is the region group of a point that stands alone (-1 in the table).
const NoGroup = -1

// OptionalPoint is one refoptionalteleport row: a place the reverse return
// scroll's map option can send a character.
type OptionalPoint struct {
	ID int
	// ZoneName is the place's name key (SN_ZONE_22004), "xxx" on a flag row
	// that stands for a group (the Donwhang cave's entrance).
	ZoneName string
	// Region is the region id, (x << 8) | y; a negative one (bit 15) is a
	// dungeon's, whose X, Y, Z are dungeon space.
	Region int
	// X, Y, Z are local to Region (the server's record keeps them as words).
	X, Y, Z int
	// WorldID is the game world (1 the open world).
	WorldID int
	// Group ties a map flag to the points listed under it; NoGroup alone.
	Group int
	// MapPoint is the map-point byte: 1 draws an icon on the world map.
	MapPoint bool
	// LevelMin and LevelMax (INFERRED, above): 0 when unbounded.
	LevelMin, LevelMax int
}

// LevelAllows is FUN_004a1ed0 (READ, 0x4a1ed0): with both bounds non-zero, a
// level below the minimum or above the maximum is refused; otherwise any
// level passes.
func (p OptionalPoint) LevelAllows(level int) bool {
	if p.LevelMin == 0 || p.LevelMax == 0 {
		return true
	}
	return level >= p.LevelMin && level <= p.LevelMax
}

// loadOptional reads dir's optionalteleport.csv into t; a missing file is no
// map points (an export from before round 778).
func (t *Table) loadOptional(dir string) error {
	f, err := os.Open(filepath.Join(dir, OptionalFile))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	return t.ReadOptional(f)
}

// ReadOptional parses an optionalteleport.csv into t, replacing what it had.
// A duplicate id or a non-numeric field is refused.
func (t *Table) ReadOptional(r io.Reader) error {
	rows, err := readCSV(r, OptionalCSVColumns, OptionalFile)
	if err != nil {
		return err
	}
	out := make([]OptionalPoint, 0, len(rows))
	byID := make(map[int]int, len(rows))
	for i, rec := range rows {
		p, err := parseOptional(rec)
		if err != nil {
			return fmt.Errorf("teleport: %s line %d: %w", OptionalFile, i+2, err)
		}
		if _, dup := byID[p.ID]; dup {
			return fmt.Errorf("teleport: %s line %d: duplicate id %d", OptionalFile, i+2, p.ID)
		}
		byID[p.ID] = len(out)
		out = append(out, p)
	}
	t.Optional = out
	t.optionalByID = byID
	return nil
}

// OptionalByID returns the map point with that refoptionalteleport id.
func (t *Table) OptionalByID(id int) (OptionalPoint, bool) {
	if t == nil || t.optionalByID == nil {
		return OptionalPoint{}, false
	}
	i, ok := t.optionalByID[id]
	if !ok {
		return OptionalPoint{}, false
	}
	return t.Optional[i], true
}

// number reads a field the client parses as a float (x, y, z) or an integer,
// as the integer the server's word holds (truncated toward zero).
func number(rec []string, c int) (int, error) {
	if v, err := strconv.Atoi(rec[c]); err == nil {
		return v, nil
	}
	f, err := strconv.ParseFloat(rec[c], 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, fmt.Errorf("%s %q is not a number", OptionalCSVColumns[c], rec[c])
	}
	return int(f), nil
}

func parseOptional(rec []string) (OptionalPoint, error) {
	var n [11]int
	for _, c := range []int{0, 2, 3, 4, 5, 6, 7, 8, 9, 10} {
		v, err := number(rec, c)
		if err != nil {
			return OptionalPoint{}, err
		}
		n[c] = v
	}
	return OptionalPoint{
		ID: n[0], ZoneName: rec[1], Region: n[2], X: n[3], Y: n[4], Z: n[5],
		WorldID: n[6], Group: n[7], MapPoint: n[8] == 1, LevelMin: n[9], LevelMax: n[10],
	}, nil
}

// The Qin-Shi tomb's floors under its map flag (round 779, OURS). In the
// archive this project reads, the tomb's entrance is a flag row (id 31,
// "xxx", region 26284, group 2) with no row under it -- ids 32..38 are absent
// (MEASURED), so a click on the flag listed nothing. The user's own client
// (another server's archive, a screenshot) lists "Tomb of Qin-Shi Emperor
// lv.2", "lv.3" and "lv.4" there. TombFloorRows are those three: each the
// game's own zone name key for the floor (textdata_object SN_ZONE_26002..
// 26004), at the teleport point the tomb's own bottom-floor gates send a
// player to on that floor -- GATE_JINSI_06x01-bldg2, -bldg7 and -bldg5 lead
// to exactly these three floors (MEASURED, teleportlink), to
// GATE_JINSI_02x01_09, GATE_JINSI_03x01 and GATE_JINSI_04x05; the first two
// are also where a player walking down from the floor above arrives. The
// ids fill the gap (32..34); map point 0 (listed under the flag, no icon of
// their own); no level range. client/scripts/worldmap/
// optional_teleport_reader.gd adds the same rows.
type TombFloorRow struct {
	ID       int
	ZoneName string
	Region   int    // the dungeon's rid as the table writes it, negative
	Point    string // the teleport point the row stands at
}

// TombFlagRegion and TombFlagGroup identify the tomb's entrance flag.
const (
	TombFlagRegion = 26284
	TombFlagGroup  = 2
)

var TombFloorRows = []TombFloorRow{
	{ID: 32, ZoneName: "SN_ZONE_26002", Region: -32762, Point: "GATE_JINSI_02x01_09"}, // 0x8006, lv.2
	{ID: 33, ZoneName: "SN_ZONE_26003", Region: -32763, Point: "GATE_JINSI_03x01"},    // 0x8005, lv.3
	{ID: 34, ZoneName: "SN_ZONE_26004", Region: -32764, Point: "GATE_JINSI_04x05"},    // 0x8004, lv.4
}

// SupplementTombFloors adds TombFloorRows when the table has the tomb's flag
// and nothing under it; a row whose id the table already has is skipped, as
// is one whose teleport point the network lacks (or has in another region,
// or without a position). Returns how many it added.
func (t *Table) SupplementTombFloors() int {
	if t == nil {
		return 0
	}
	flag := false
	for _, p := range t.Optional {
		if p.Group == TombFlagGroup && p.MapPoint && p.Region == TombFlagRegion {
			flag = true
		} else if p.Group == TombFlagGroup && !p.MapPoint {
			return 0 // the table lists the group itself
		}
	}
	if !flag {
		return 0
	}
	if t.optionalByID == nil {
		t.optionalByID = map[int]int{}
	}
	added := 0
	for _, row := range TombFloorRows {
		if _, taken := t.optionalByID[row.ID]; taken {
			continue
		}
		at, ok := t.pointByCode(row.Point)
		if !ok || at.Region != row.Region || (at.X == 0 && at.Y == 0 && at.Z == 0) {
			continue
		}
		world := at.WorldID
		if world == 0 {
			world = 1 // an export from before WorldID: the open world's
		}
		t.optionalByID[row.ID] = len(t.Optional)
		t.Optional = append(t.Optional, OptionalPoint{
			ID: row.ID, ZoneName: row.ZoneName, Region: row.Region,
			X: at.X, Y: at.Y, Z: at.Z, WorldID: world,
			Group: TombFlagGroup,
		})
		added++
	}
	return added
}

func (t *Table) pointByCode(code string) (Point, bool) {
	for _, p := range t.Points {
		if p.Code == code {
			return p, true
		}
	}
	return Point{}, false
}
