// Package nest is the monster world's placement and respawn (round 660):
// every field monster npcpos places, hatched from a nest the way the engine's
// hive pass hatches one, with the nest's respawn window, radius, cap and
// champion chance and the aggression, sight and leash of its tactics row.
//
// The rules are READ from SR_GameServer.exe (each cited where it is written:
// the hatch pass AIHive_HatchPass 0x55ea90, the hive-capped pass 0x55ec10,
// Nest_Hatch 0x5607b0, NestSlot_RollHatchDelay 0x560380, the hatch spot
// GObjPC::FUN_00531240, the world's class clamp 0x5eb9a0; see
// docs/protocol/monster_ai.md). The NUMBERS the rules run on -- the
// _RefNest, _RefTactics and _RefHive rows -- are server-database tables the
// client's archives do not carry. The ones this package loads come from a
// private server's database backup the user supplied (the "Eternity" shard,
// round 658): EXTERNAL, never READ, and never committed. The operator exports
// them to CSV (deploy/README.md) and points -nest-db-dir at them; without them
// every npcpos row is a stand-in nest of one monster with the OURS respawn and
// behaviour defaults.
//
// Three files make the package: db.go loads the rows, join.go matches the
// npcpos rows to them, hatch.go and scheduler.go are the READ rules and the
// runtime that runs them.
package nest

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The three files -nest-db-dir holds, under the names the round-658 export
// writes (deploy/README.md, "The shard DB's AI tables"): each table's own
// name, with a header row of the database's own column names.
const (
	TacticsFile = "Tab_RefTactics.csv"
	NestFile    = "tab_refnest.csv"
	HiveFile    = "tab_refhive.csv"
)

// TacticsRow is one _RefTactics row: the columns the AI reads, by the database's
// own names (EXTERNAL values; the column positions and meanings are READ off
// RefTactics_ExtractData 0x6aaab0 and their readers -- docs/protocol/
// monster_ai.md, "The _RefTactics row, read off its parser").
type TacticsRow struct {
	ID    int64 // col 1 dwTacticsID
	ObjID int64 // col 2 dwObjID, the species
	// SightRange is col 6 nSightRange (+0x14), the detection distance.
	SightRange int
	// AggressType/AggressData are cols 7/8 (+0x18/+0x1c): 0 aggressive, 1
	// passive, 2 aggressive at AggressData percent (ai.Aggressive).
	AggressType uint8
	AggressData int
	// ChangeTarget is col 9 btChangeTarget (+0x20), the retarget rule.
	ChangeTarget uint8
	// TraceBoundary/TraceData are cols 35/36 (+0x79/+0x7c): the chase switch
	// and the give-up distance.
	TraceBoundary uint8
	TraceData     int
	// HomingType/HomingData are cols 37/38 (+0x80/+0x84): the roam-radius
	// rule and the radius of a monster with no nest.
	HomingType uint8
	HomingData int
	// AggressTypeOnHoming is col 39 (+0x88). No reader found (round 238);
	// carried as data.
	AggressTypeOnHoming uint8
	// FleeType is col 40 (+0x89), the reach rule.
	FleeType uint8
	// ChampionTacticsID is col 41 dwChampionTacticsID (+0x8c): non-zero lets
	// Nest_Hatch roll a champion or giant, which then runs under this row.
	ChampionTacticsID int64
	// Flags is col 42 AdditionOptionFlag (+0x90).
	Flags uint32
}

// NestRow is one _RefNest row (EXTERNAL values; the columns READ off
// RefNest_ExtractData 0x6ab230, monster_ai.md "The _RefNest row").
type NestRow struct {
	ID        int64 // col 1 dwNestID
	HiveID    int64 // col 2 dwHiveID
	TacticsID int64 // col 3 dwTacticsID
	// Region is col 4 nRegionDBID as the engine's u16 (the SQL smallint is
	// signed, so a dungeon region >= 0x8000 exports negative).
	Region int
	// X, Y, Z are cols 5-7, local to Region. HasY is false for the rows whose
	// fLocalPosY is NULL (145 in the shard); nothing here reads Y.
	X, Y, Z float64
	HasY    bool
	// Dir is col 8 wInitialDir as the engine's u16.
	Dir uint16
	// Radius is col 9 nRadius (+0x20), the roam radius Attach hands the AI.
	Radius int
	// GenerateRadius is col 10 nGenerateRadius (+0x24), how far from the nest
	// a hatch lands (HatchOffset, GObjPC::FUN_00531240).
	GenerateRadius int
	// ChampionPct is col 11 nChampionGenPercentage (+0x28).
	ChampionPct int
	// DelayMin/DelayMax are cols 12/13 (+0x2c/+0x30), seconds.
	DelayMin, DelayMax int
	// MaxCount is col 14 dwMaxTotalCount (+0x34), the alive cap.
	MaxCount int
	// Flag is col 15 btFlag (+0x38, no reader found), Respawn col 16 (+0x39:
	// non-zero hatches for ever), Type col 17 (+0x3a: must be 0 for the
	// scheduler to hatch the nest at all).
	Flag, Respawn, Type uint8
}

// HiveRow is one _RefHive row (EXTERNAL values; the columns READ off
// RefHive_ExtractData 0x6aa960 and AIHive's code, monster_ai.md).
type HiveRow struct {
	ID int64 // col 1 dwHiveID
	// KeepType is col 2 btKeepMonsterCountType: 1 turns the population
	// scaling on (not modelled; nest.go's note).
	KeepType uint8
	// OverwriteMax is col 3 dwOverwriteMaxTotalCount: non-zero puts the hive
	// on the hive-capped pass (AIHive::Init sets hive+0x30, 0x55e73d), which
	// hatches until this many of the hive's monsters are alive.
	OverwriteMax int
	// CountPerPC is col 4 fMonsterCountPerPC, Rate col 5, MaxRate col 6.
	CountPerPC    float64
	Rate, MaxRate int
	Flag          uint8 // col 7, no reader found
	WorldID       int   // col 8 GameWorldID
	HatchKind     int   // col 9 HatchObjType
}

// DB is the three tables, loaded.
type DB struct {
	Tactics map[int64]*TacticsRow
	Nests   []NestRow
	Hives   map[int64]*HiveRow
	// byObj is every tactics row of a species, in id order.
	byObj map[int64][]*TacticsRow
	// championRow marks the rows some row names as its champion row.
	championRow map[int64]bool
	// AISkills is Tab_RefAISkill by tactics id, and Skills _RefSkill's ids,
	// codes and summon blocks -- the two optional files of round 661 (nil
	// when the directory does not hold them; summon.go).
	AISkills map[int64][]AISkillRow
	Skills   map[int64]*SkillRow
}

// LoadDir reads the three files from dir. A file that is missing or does not
// parse is an error: a configured directory that does not load is fatal at
// boot, the -npcpos-csv rule.
func LoadDir(dir string) (*DB, error) {
	open := func(name string) (*os.File, error) {
		return openDBFile(dir, name)
	}
	f, err := open(TacticsFile)
	if err != nil {
		return nil, err
	}
	tactics, err := ReadTactics(f)
	f.Close()
	if err != nil {
		return nil, fmt.Errorf("%s: %w", TacticsFile, err)
	}
	f, err = open(NestFile)
	if err != nil {
		return nil, err
	}
	nests, err := ReadNests(f)
	f.Close()
	if err != nil {
		return nil, fmt.Errorf("%s: %w", NestFile, err)
	}
	f, err = open(HiveFile)
	if err != nil {
		return nil, err
	}
	hives, err := ReadHives(f)
	f.Close()
	if err != nil {
		return nil, fmt.Errorf("%s: %w", HiveFile, err)
	}
	db := NewDB(tactics, nests, hives)
	if err := loadOptional(db, dir); err != nil {
		return nil, err
	}
	return db, nil
}

// openFile is os.Open, a variable so a test can refuse a file the way a
// nonroot server is refused one (the tests run as root, which is never
// refused).
var openFile = os.Open

// openDBFile opens one of the directory's CSVs. A file the server may not
// read gets an error that says what to do (round 666): the release image runs
// as distroless nonroot (server/Dockerfile), and a CSV copied under `umask
// 077` keeps mode 0600 through scp, so the container cannot read it and the
// boot crash-loops on a bare "permission denied".
func openDBFile(dir, name string) (*os.File, error) {
	path := filepath.Join(dir, name)
	f, err := openFile(path)
	if errors.Is(err, fs.ErrPermission) {
		return nil, fmt.Errorf("%s: permission denied: chmod 644 the nest DB's CSVs and chmod 755 their directory "+
			"(the server runs as a nonroot user; deploy/README.md, \"The three files -nest-db-dir reads\"): %w", path, err)
	}
	return f, err
}

// NewDB indexes the three tables.
func NewDB(tactics map[int64]*TacticsRow, nests []NestRow, hives map[int64]*HiveRow) *DB {
	db := &DB{Tactics: tactics, Nests: nests, Hives: hives, byObj: map[int64][]*TacticsRow{}, championRow: map[int64]bool{}}
	if db.Tactics == nil {
		db.Tactics = map[int64]*TacticsRow{}
	}
	if db.Hives == nil {
		db.Hives = map[int64]*HiveRow{}
	}
	for _, t := range db.Tactics {
		db.byObj[t.ObjID] = append(db.byObj[t.ObjID], t)
		if t.ChampionTacticsID != 0 {
			db.championRow[t.ChampionTacticsID] = true
		}
	}
	for _, list := range db.byObj {
		sortTactics(list)
	}
	return db
}

func sortTactics(list []*TacticsRow) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].ID < list[j-1].ID; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

// table is a CSV with a header of column names.
type table struct {
	col  map[string]int
	rows [][]string
}

// readTable reads a CSV and checks it carries every name in want.
func readTable(r io.Reader, want []string) (*table, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	cr.LazyQuotes = true
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("reading header: %w", err)
	}
	t := &table{col: map[string]int{}}
	for i, h := range header {
		t.col[strings.TrimPrefix(strings.TrimSpace(h), "\ufeff")] = i
	}
	for _, w := range want {
		if _, ok := t.col[w]; !ok {
			return nil, fmt.Errorf("no column %q in header %q", w, header)
		}
	}
	for {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		t.rows = append(t.rows, rec)
	}
	return t, nil
}

// cell is one row's parser, remembering the first error.
type cell struct {
	t   *table
	rec []string
	row int
	err error
}

func (c *cell) str(name string) string {
	i := c.t.col[name]
	if i >= len(c.rec) {
		if c.err == nil {
			c.err = fmt.Errorf("row %d: short, no %s", c.row, name)
		}
		return ""
	}
	return strings.TrimSpace(c.rec[i])
}

func (c *cell) int(name string) int64 {
	s := c.str(name)
	if s == "" {
		return 0
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		f, ferr := strconv.ParseFloat(s, 64)
		if ferr != nil {
			if c.err == nil {
				c.err = fmt.Errorf("row %d: %s %q: %w", c.row, name, s, err)
			}
			return 0
		}
		v = int64(f)
	}
	return v
}

func (c *cell) float(name string) (float64, bool) {
	s := c.str(name)
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		if c.err == nil {
			c.err = fmt.Errorf("row %d: %s %q: %w", c.row, name, s, err)
		}
		return 0, false
	}
	return v, true
}

// TacticsColumns is every _RefTactics column this package reads.
var TacticsColumns = []string{"dwTacticsID", "dwObjID", "nSightRange", "btAggressType", "AggressData",
	"btChangeTarget", "btTraceBoundary", "TraceData", "btHomingType", "HomingData",
	"btAggressTypeOnHoming", "btFleeType", "dwChampionTacticsID", "AdditionOptionFlag"}

// ReadTactics parses a Tab_RefTactics CSV.
func ReadTactics(r io.Reader) (map[int64]*TacticsRow, error) {
	t, err := readTable(r, TacticsColumns)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]*TacticsRow, len(t.rows))
	for i, rec := range t.rows {
		c := &cell{t: t, rec: rec, row: i + 2}
		row := &TacticsRow{
			ID: c.int("dwTacticsID"), ObjID: c.int("dwObjID"),
			SightRange:  int(c.int("nSightRange")),
			AggressType: uint8(c.int("btAggressType")), AggressData: int(c.int("AggressData")),
			ChangeTarget:  uint8(c.int("btChangeTarget")),
			TraceBoundary: uint8(c.int("btTraceBoundary")), TraceData: int(c.int("TraceData")),
			HomingType: uint8(c.int("btHomingType")), HomingData: int(c.int("HomingData")),
			AggressTypeOnHoming: uint8(c.int("btAggressTypeOnHoming")),
			FleeType:            uint8(c.int("btFleeType")),
			ChampionTacticsID:   c.int("dwChampionTacticsID"),
			Flags:               uint32(c.int("AdditionOptionFlag")),
		}
		if c.err != nil {
			return nil, c.err
		}
		if _, dup := out[row.ID]; dup {
			// FUN_006e38f0 refuses a duplicate TacticsID (FUN_00501ac0).
			return nil, fmt.Errorf("row %d: duplicate dwTacticsID %d", i+2, row.ID)
		}
		out[row.ID] = row
	}
	return out, nil
}

// NestColumns is every _RefNest column this package reads.
var NestColumns = []string{"dwNestID", "dwHiveID", "dwTacticsID", "nRegionDBID", "fLocalPosX", "fLocalPosY",
	"fLocalPosZ", "wInitialDir", "nRadius", "nGenerateRadius", "nChampionGenPercentage", "dwDelayTimeMin",
	"dwDelayTimeMax", "dwMaxTotalCount", "btFlag", "btRespawn", "btType"}

// ReadNests parses a tab_refnest CSV.
func ReadNests(r io.Reader) ([]NestRow, error) {
	t, err := readTable(r, NestColumns)
	if err != nil {
		return nil, err
	}
	out := make([]NestRow, 0, len(t.rows))
	for i, rec := range t.rows {
		c := &cell{t: t, rec: rec, row: i + 2}
		n := NestRow{
			ID: c.int("dwNestID"), HiveID: c.int("dwHiveID"), TacticsID: c.int("dwTacticsID"),
			Region: int(uint16(c.int("nRegionDBID"))),
			Dir:    uint16(c.int("wInitialDir")),
			Radius: int(c.int("nRadius")), GenerateRadius: int(c.int("nGenerateRadius")),
			ChampionPct: int(c.int("nChampionGenPercentage")),
			DelayMin:    int(c.int("dwDelayTimeMin")), DelayMax: int(c.int("dwDelayTimeMax")),
			MaxCount: int(c.int("dwMaxTotalCount")),
			Flag:     uint8(c.int("btFlag")), Respawn: uint8(c.int("btRespawn")), Type: uint8(c.int("btType")),
		}
		n.X, _ = c.float("fLocalPosX")
		n.Y, n.HasY = c.float("fLocalPosY")
		n.Z, _ = c.float("fLocalPosZ")
		if c.err != nil {
			return nil, c.err
		}
		out = append(out, n)
	}
	return out, nil
}

// HiveColumns is every _RefHive column this package reads.
var HiveColumns = []string{"dwHiveID", "btKeepMonsterCountType", "dwOverwriteMaxTotalCount", "fMonsterCountPerPC",
	"dwSpawnSpeedIncreaseRate", "dwMaxIncreaseRate", "btFlag", "GameWorldID", "HatchObjType"}

// ReadHives parses a tab_refhive CSV.
func ReadHives(r io.Reader) (map[int64]*HiveRow, error) {
	t, err := readTable(r, HiveColumns)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]*HiveRow, len(t.rows))
	for i, rec := range t.rows {
		c := &cell{t: t, rec: rec, row: i + 2}
		h := &HiveRow{
			ID: c.int("dwHiveID"), KeepType: uint8(c.int("btKeepMonsterCountType")),
			OverwriteMax: int(c.int("dwOverwriteMaxTotalCount")),
			Rate:         int(c.int("dwSpawnSpeedIncreaseRate")), MaxRate: int(c.int("dwMaxIncreaseRate")),
			Flag: uint8(c.int("btFlag")), WorldID: int(c.int("GameWorldID")), HatchKind: int(c.int("HatchObjType")),
		}
		h.CountPerPC, _ = c.float("fMonsterCountPerPC")
		if c.err != nil {
			return nil, c.err
		}
		out[h.ID] = h
	}
	return out, nil
}

// OwnTactics is the tactics row a species runs under at a spot whose DB nest
// was repointed to another species (Join's Swapped): the species' own row.
// With several, the lowest-id row that is no other row's champion row, else
// the lowest-id row -- OURS: which of a species' rows the original nests used
// is not recoverable once the nest was repointed. nil when the species has no
// row at all (the stand-in behaviour then applies).
func (db *DB) OwnTactics(obj int64) *TacticsRow {
	if db == nil {
		return nil
	}
	list := db.byObj[obj]
	for _, t := range list {
		if !db.championRow[t.ID] {
			return t
		}
	}
	if len(list) > 0 {
		return list[0]
	}
	return nil
}
