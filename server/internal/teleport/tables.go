// Package teleport holds the game's teleport network -- the gates, the links
// between them and the gate buildings -- and the rules for using a link
// (rules.go).
//
// The tables are the client's own Media.pk2 text files
// (server_dep\silkroad\textdata\teleportdata.txt, teleportlink.txt and
// teleportbuilding.txt), which cmd/export-refdata -mode teleport turns into
// three CSVs in one directory; cmd/server's -teleport-dir loads that
// directory. No game data ships with the repo: the operator exports the CSVs
// from their own archive, exactly as for -npcpos-csv. The column map, the
// counts in a retail archive (222 points, 292 links, 77 buildings) and how
// each column was established are in docs/protocol/teleport_network.md,
// "The columns srrevamp reads (round 575)".
package teleport

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The three files cmd/export-refdata -mode teleport writes into its output
// directory, and Load reads from it.
const (
	PointsFile    = "teleportdata.csv"
	LinksFile     = "teleportlink.csv"
	BuildingsFile = "teleportbuilding.csv"
)

// PointCSVColumns is teleportdata.csv's header.
var PointCSVColumns = []string{"ID", "Code", "ObjectID", "ZoneName", "Region", "X", "Y", "Z", "Radius", "Interaction7", "Interaction9"}

// LinkCSVColumns is teleportlink.csv's header: the source and destination
// point, the fee, then the five restriction triples as the table holds them.
var LinkCSVColumns = []string{"From", "To", "Fee",
	"Rule1Type", "Rule1Data1", "Rule1Data2",
	"Rule2Type", "Rule2Data1", "Rule2Data2",
	"Rule3Type", "Rule3Data1", "Rule3Data2",
	"Rule4Type", "Rule4Data1", "Rule4Data2",
	"Rule5Type", "Rule5Data1", "Rule5Data2"}

// BuildingCSVColumns is teleportbuilding.csv's header.
var BuildingCSVColumns = []string{"ID", "Code", "NameStrID", "Region", "X", "Y", "Z", "Fortress"}

// Point is one teleportdata row: a place a link starts or ends at.
type Point struct {
	ID   int
	Code string // GATE_CH, GATE_NPC_CH_FERRY, ...
	// ObjectID is the ref object the row is associated with -- the object
	// RefTeleport_ExtractData (0x6a7be0) looks up and registers the two
	// interaction ids on (teleport_network.md, round 454). For a gate it is a
	// teleportbuilding row (GATE_CH -> 2094 STORE_CH_GATE); for a ferry it is
	// an NPC (GATE_NPC_CH_FERRY -> 2011 NPC_CH_FERRY, a characterdata row); 0
	// in 118 retail rows.
	ObjectID int
	// ZoneName is the place's name string id (SN_ZONE_22001 is Jangan).
	ZoneName string
	// Region is the region id, (x << 8) | y as worldmap.RegionXY unpacks it;
	// the 98 dungeon rows carry a negative (high-bit) id.
	Region int
	// X, Y, Z are local to Region, and Radius is the point's radius -- the
	// server parser's five words (`wwwww`, refdata_tables.md, 0x6a7be0).
	X, Y, Z int
	Radius  int
	// Interaction7 and Interaction9 are the two flags RefTeleport_ExtractData
	// turns into NPC interaction ids 7 and 9 on the associated object (round
	// 454). Which services 7 and 9 are is NOT read, so they are named by id.
	Interaction7, Interaction9 bool
}

// Rule is one restriction triple of a link: a type and two data words, walked
// in order by the server's evaluator FUN_00513a70 (rules.go).
type Rule struct {
	Type, D1, D2 int
}

// Link is one teleportlink row: a directed edge between two points.
type Link struct {
	From, To int
	// Fee is the gold the link costs: the runtime link's second word, which
	// GObjPC::HandleTeleportUse (0x513590) compares against the character's
	// gold (teleport_network.md, "The fee, read at its use-site"). A 32-bit
	// unsigned word there (`mov esi,[edi+0x4]`, 0x5136d7), so Read rejects a
	// negative or wider value.
	Fee int64
	// Rules are the restriction triples whose type is not 0, in table order.
	// A type-0 slot is an empty slot: 1,125 of the retail table's 1,460 are 0
	// with blank or zero data words (3 blank, all on link 1 -> 5, and 1,122
	// zero; counted read-only over the render box's /var/tmp/tables, round
	// 575), and the evaluator has no arm for type 0.
	Rules []Rule
}

// Building is one teleportbuilding row: the gate's own object.
type Building struct {
	ID        int
	Code      string // STORE_CH_GATE, ...
	NameStrID string // SN_NPC_CH_GATE, ...
	// Region, X, Y, Z are the _RefObjCommon prefix's RegionID and OffsetX/Y/Z
	// (refobj_binary_format.md, "Fields 43-51 of the common prefix").
	Region  int
	X, Y, Z int
	// Fortress is the row's FORTRESS_* code ("" where the table has its "xxx"
	// placeholder, 72 of 77 retail rows). Read from the values -- the five town
	// gates carry their town's fortress -- not from a use-site.
	Fortress string
}

// Table is the whole network, rows kept in file order.
type Table struct {
	Points    []Point
	Links     []Link
	Buildings []Building

	pointByID      map[int]int
	pointByObject  map[int]int
	buildingByCode map[string]int
	linksFrom      map[int][]int
	linkByPair     map[[2]int]int
}

// Load reads the three CSVs from dir. A configured directory that cannot be
// read is an error, not an empty network -- the npcpos loader's rule.
func Load(dir string) (*Table, error) {
	var files [3]*os.File
	for i, name := range []string{PointsFile, LinksFile, BuildingsFile} {
		f, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			for _, g := range files[:i] {
				g.Close()
			}
			return nil, err
		}
		files[i] = f
	}
	defer func() {
		for _, f := range files {
			f.Close()
		}
	}()
	return Read(files[0], files[1], files[2])
}

// Read parses the three CSV texts and joins them. It refuses a missing or
// wrong header, a short row, a non-numeric field, a duplicate point, building
// or link, and a link whose end is not a point: every link in a retail
// archive joins (292 of 292), so one that does not means the three files do
// not come from one export.
func Read(points, links, buildings io.Reader) (*Table, error) {
	t := &Table{
		pointByID:      map[int]int{},
		pointByObject:  map[int]int{},
		buildingByCode: map[string]int{},
		linksFrom:      map[int][]int{},
		linkByPair:     map[[2]int]int{},
	}
	buildingByID := map[int]bool{}

	rows, err := readCSV(buildings, BuildingCSVColumns, BuildingsFile)
	if err != nil {
		return nil, err
	}
	for i, rec := range rows {
		b, err := parseBuilding(rec)
		if err != nil {
			return nil, fmt.Errorf("teleport: %s line %d: %w", BuildingsFile, i+2, err)
		}
		if buildingByID[b.ID] {
			return nil, fmt.Errorf("teleport: %s line %d: duplicate building id %d", BuildingsFile, i+2, b.ID)
		}
		if _, dup := t.buildingByCode[b.Code]; dup {
			return nil, fmt.Errorf("teleport: %s line %d: duplicate building code %q", BuildingsFile, i+2, b.Code)
		}
		buildingByID[b.ID] = true
		t.buildingByCode[b.Code] = len(t.Buildings)
		t.Buildings = append(t.Buildings, b)
	}

	rows, err = readCSV(points, PointCSVColumns, PointsFile)
	if err != nil {
		return nil, err
	}
	for i, rec := range rows {
		p, err := parsePoint(rec)
		if err != nil {
			return nil, fmt.Errorf("teleport: %s line %d: %w", PointsFile, i+2, err)
		}
		if _, dup := t.pointByID[p.ID]; dup {
			return nil, fmt.Errorf("teleport: %s line %d: duplicate point id %d", PointsFile, i+2, p.ID)
		}
		t.pointByID[p.ID] = len(t.Points)
		// The first point wins for an object; a retail archive has no object
		// named by two points.
		if _, seen := t.pointByObject[p.ObjectID]; !seen && p.ObjectID != 0 {
			t.pointByObject[p.ObjectID] = len(t.Points)
		}
		t.Points = append(t.Points, p)
	}

	rows, err = readCSV(links, LinkCSVColumns, LinksFile)
	if err != nil {
		return nil, err
	}
	for i, rec := range rows {
		l, err := parseLink(rec)
		if err != nil {
			return nil, fmt.Errorf("teleport: %s line %d: %w", LinksFile, i+2, err)
		}
		for _, end := range []int{l.From, l.To} {
			if _, ok := t.pointByID[end]; !ok {
				return nil, fmt.Errorf("teleport: %s line %d: link %d -> %d names point %d, which %s does not have",
					LinksFile, i+2, l.From, l.To, end, PointsFile)
			}
		}
		pair := [2]int{l.From, l.To}
		if _, dup := t.linkByPair[pair]; dup {
			return nil, fmt.Errorf("teleport: %s line %d: duplicate link %d -> %d", LinksFile, i+2, l.From, l.To)
		}
		t.linkByPair[pair] = len(t.Links)
		t.linksFrom[l.From] = append(t.linksFrom[l.From], len(t.Links))
		t.Links = append(t.Links, l)
	}
	return t, nil
}

// PointByID returns the point with that teleportdata id.
func (t *Table) PointByID(id int) (Point, bool) {
	i, ok := t.pointByID[id]
	if !ok {
		return Point{}, false
	}
	return t.Points[i], true
}

// PointByBuildingCode returns the point whose associated object is the
// building with that code: STORE_CH_GATE (2094) -> GATE_CH.
func (t *Table) PointByBuildingCode(code string) (Point, bool) {
	b, ok := t.buildingByCode[strings.TrimSpace(code)]
	if !ok {
		return Point{}, false
	}
	i, ok := t.pointByObject[t.Buildings[b].ID]
	if !ok {
		return Point{}, false
	}
	return t.Points[i], true
}

// LinksFrom returns the links leaving a point, in file order -- the order the
// client's teleport list numbers them in (UI_TELEPORT::FUN_006fd3e0 walks its
// link records by index, teleport_network.md).
func (t *Table) LinksFrom(id int) []Link {
	idx := t.linksFrom[id]
	out := make([]Link, 0, len(idx))
	for _, i := range idx {
		out = append(out, t.Links[i])
	}
	return out
}

// LinkBetween returns the link from one point to another.
func (t *Table) LinkBetween(from, to int) (Link, bool) {
	i, ok := t.linkByPair[[2]int{from, to}]
	if !ok {
		return Link{}, false
	}
	return t.Links[i], true
}

// readCSV reads one table's CSV and checks its header against want, name by
// name, so a file of the wrong table (or none) cannot load as this one.
func readCSV(r io.Reader, want []string, name string) ([][]string, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("teleport: %s: reading header: %w", name, err)
	}
	if len(header) != len(want) {
		return nil, fmt.Errorf("teleport: %s: not a %s CSV (header %q)", name, name, header)
	}
	for i := range want {
		if strings.TrimSpace(header[i]) != want[i] {
			return nil, fmt.Errorf("teleport: %s: not a %s CSV (header %q)", name, name, header)
		}
	}
	var rows [][]string
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if err == io.EOF {
			return rows, nil
		}
		if err != nil {
			return nil, fmt.Errorf("teleport: %s line %d: %w", name, line, err)
		}
		if len(rec) != len(want) {
			return nil, fmt.Errorf("teleport: %s line %d: %d fields, want %d", name, line, len(rec), len(want))
		}
		for i := range rec {
			rec[i] = strings.TrimSpace(rec[i])
		}
		rows = append(rows, rec)
	}
}

// ints parses each field as a decimal integer, naming the column that failed.
func ints(rec []string, header []string, cols ...int) ([]int, error) {
	out := make([]int, len(cols))
	for k, c := range cols {
		v, err := strconv.Atoi(rec[c])
		if err != nil {
			return nil, fmt.Errorf("%s %q is not an integer", header[c], rec[c])
		}
		out[k] = v
	}
	return out, nil
}

func parsePoint(rec []string) (Point, error) {
	n, err := ints(rec, PointCSVColumns, 0, 2, 4, 5, 6, 7, 8)
	if err != nil {
		return Point{}, err
	}
	flags, err := ints(rec, PointCSVColumns, 9, 10)
	if err != nil {
		return Point{}, err
	}
	return Point{
		ID: n[0], Code: rec[1], ObjectID: n[1], ZoneName: rec[3],
		Region: n[2], X: n[3], Y: n[4], Z: n[5], Radius: n[6],
		Interaction7: flags[0] != 0, Interaction9: flags[1] != 0,
	}, nil
}

func parseLink(rec []string) (Link, error) {
	n, err := ints(rec, LinkCSVColumns, 0, 1)
	if err != nil {
		return Link{}, err
	}
	fee, err := strconv.ParseUint(rec[2], 10, 32)
	if err != nil {
		return Link{}, fmt.Errorf("Fee %q is not a 32-bit unsigned word", rec[2])
	}
	l := Link{From: n[0], To: n[1], Fee: int64(fee)}
	for k := 0; k < 5; k++ {
		c := 3 + 3*k
		typ, err := ints(rec, LinkCSVColumns, c)
		if err != nil {
			return Link{}, err
		}
		if typ[0] == 0 {
			continue
		}
		data, err := ints(rec, LinkCSVColumns, c+1, c+2)
		if err != nil {
			return Link{}, err
		}
		l.Rules = append(l.Rules, Rule{Type: typ[0], D1: data[0], D2: data[1]})
	}
	return l, nil
}

func parseBuilding(rec []string) (Building, error) {
	n, err := ints(rec, BuildingCSVColumns, 0, 3, 4, 5, 6)
	if err != nil {
		return Building{}, err
	}
	fortress := rec[7]
	if fortress == "xxx" {
		fortress = ""
	}
	return Building{
		ID: n[0], Code: rec[1], NameStrID: rec[2],
		Region: n[1], X: n[2], Y: n[3], Z: n[4], Fortress: fortress,
	}, nil
}
