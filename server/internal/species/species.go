// Package species is the monster species table: every characterdata
// (_RefObjChar) row of TypeID (1,2,1,x), exported by cmd/export-refdata
// -mode monsters and loaded by cmd/server's -monsters-csv (round 654).
//
// It has two halves that share one set of column numbers, so the mapping is
// written down once and tested once:
//
//   - the EXPORT half (Exporter, ParseLevelGold, ParseObjectNames) turns the
//     client's own tab-split tables into CSV records;
//   - the LOAD half (Read, LoadCSV, Row.Attacks) reads that CSV back.
//
// No game data ships with this package or its tests: the operator exports the
// table from their own Media.pk2, and the tests build synthetic rows.
//
// Every characterdata column number here is 0-INDEXED (field 0 is the
// leading service column, field 1 the id) -- the project's convention, which
// the round-536 verifier (client/tools/verify_monster_specs.py) and
// docs/protocol/refobj_binary_format.md use too. Each column is labelled with
// where its meaning comes from:
//
//	READ      recovered from a binary (a deserialiser, an assert, a use site)
//	MEASURED  settled against real rows (a census, a control that matches)
//	OPEN      carried as data, meaning not established -- nothing reads it as
//	          anything more than the number it is
package species

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Column indices into a tab-split characterdata row (0-indexed).
const (
	// ColID is the row id (_RefObjCommon ID) -- the key npcpos.txt places
	// monsters by. READ: the common prefix every _RefObj table shares
	// (refobj_binary_format.md).
	ColID = 1
	// ColCodeName is the row's code name (MOB_CH_MANGNYANG), unique per row.
	// READ, same prefix.
	ColCodeName = 2
	// ColOrgCodeName is OrgObjCodeName: the deserialiser's third string read
	// is the row's column 4 (fields 3-7 are five string reads, and the row's
	// columns 2..6 are CodeName/ObjName/OrgObjCodeName/NameStrID/DescStrID --
	// docs/protocol/durability.md's table, refobj_binary_format.md). READ as a
	// position; what the client DOES with it (draw the Org row's model for a
	// row whose own model is "xxx") is NOT read -- round 655 reads it. Here it
	// is recorded as a field and nothing more.
	ColOrgCodeName = 4
	// ColNameKey is NameStrID, the SN_ key textdata_object resolves to the
	// display name (MOB_CH_MANGNYANG -> SN_MOB_CH_MANGNYANG -> "Mangyang").
	// READ position; the resolution MEASURED on the 11-species ladder (the
	// 2026-09-13 regrounding audit).
	ColNameKey = 5
	// ColTypeID1..4 are the four TypeID bytes. A monster is (1,2,1,x): the
	// shape the round-653 plan's census used and the item table's own TypeID
	// run (cmd/export-refdata fTypeID1 = 9) sits at the same columns. READ
	// position (the _RefObjCommon prefix), MEASURED on the monster rows.
	ColTypeID1 = 9
	ColTypeID2 = 10
	ColTypeID3 = 11
	ColTypeID4 = 12
	// ColRarity is the _RefObjCommon Rarity: 0 normal, 1 champion, 3/8
	// unique, 4 giant, 5 titan, 6 elite, 7 rank 7 -- the client's target
	// window picks its gem from it (FUN_0069b4c0) and the server scales HP by
	// it (combat.RarityHPPercent, CGObjMob::PublishStats). READ.
	ColRarity = 15
	// ColWalkSpeed / ColRunSpeed are Speed1/Speed2 in world units per second
	// (ParamKeeper params 23/24, docs/protocol/param_registry.md). READ,
	// MEASURED on the roster (round 536's verifier: 22 fields, 0 mismatched).
	ColWalkSpeed = 46
	ColRunSpeed  = 47
	// ColBCRadius is the collision radius (the common record's word at +0xee,
	// IGObj slot 344). READ (round 247, monster_ai.md).
	ColBCRadius = 50
	// ColModel is the .bsr the row draws ("mob\\china\\mangnyang.bsr"), or
	// "xxx" for a row with none of its own. MEASURED: the fields 53-57 of the
	// deserialiser are five string reads and the row's are the .bsr/.bsr/.ddj
	// asset paths plus two "xxx" (cmd/export-refdata's fRepairCost note).
	ColModel = 52
	// ColLevel is the monster level. READ (CRefObjChar+0x198, the byte
	// before the m_dwMaxHP > 0 assert's dword) and MEASURED (the ladder).
	ColLevel = 57
	// ColMaxHP is MaxHP. READ: RefObjChar::ExtractData writes it to
	// CRefObjChar+0x19c, the field the binary asserts m_dwMaxHP > 0 on.
	ColMaxHP = 59
	// ColParams is the first of the eight combat columns 71..78 that
	// GObjMob_PublishStats pushes into ParamKeeper params 5..12, in order
	// (READ). What each param MEANS is only partly read:
	//
	//	71 param 5   the flat physical absorption (Formula_MitigatePhysicalDamage
	//	             fetches param 5 as the flat term) -- READ; monsterSpec.Defense
	//	72 param 6   its magical counterpart -- INFERRED from the pair
	//	73 param 7   the physical percentage reduction (the same formula divides
	//	             by 1 + param 7 / 100) -- READ; equals the level (col 57)
	//	             on 7,088 of this table's 7,604 species, 93.2 % (MEASURED,
	//	             round 654's review; the 516 others are mostly rarity 3/8,
	//	             whose col 57 reads 110). Round 380's 99.45 % was over a
	//	             different set, the 7,495 MOB_-prefixed rows.
	//	74 param 8   its magical counterpart -- INFERRED
	//	75 param 9   tag 'era' -- READ tag; "evasion" is a READING of the tag
	//	76 param 10  tag 'bri' -- the block chance (combat.Monster.Block)
	//	77 param 11  tag 'hra' -- READ tag; "hit rate" is a reading
	//	78 param 12  tag 'cri' -- the critical chance (combat.Monster.Critical)
	ColParams = 71
	// ColSkills is the first of the ten attack-skill ids, cols 83..92:
	// AI::CTactics::BindSkillsAndRanges (0x53f951..0x53f98a) registers the
	// ten dwords at RefObjChar+0x260, +0x260 being col 83 by the +0x230 =
	// col 71 anchor. READ.
	ColSkills = 83
	// NumSkills is how many skill columns there are.
	NumSkills = 10
	// NumParams is how many combat columns there are (71..78).
	NumParams = 8
	// ColExpToGive is col 79, the kill's base EXP (round 712). READ:
	// RefObjChar::ExtractData writes it to CRefObjChar+0x250 (the anchored
	// offset map, col 78 at +0x24c, col 82 at +0x25c); the kill formulas
	// Formula_ExpRewardForContributor 0x410110 and FUN_004106b0 read it
	// through the victim's slot 332 (CGObjMob vtable 0xaeddac +0x530 =
	// 0x4a68b0, `mov ecx,[ecx+0x34]; mov eax,[ecx]; jmp [eax+0x34]`) -> the
	// instance's slot 13, 0x449340 `mov eax,[ecx+0x18]; mov eax,[eax+0x250]`.
	// The package's DB export names the column ExpToGive (between CHR and
	// CreepType). For an ordinary monster it equals leveldata col 5 at its
	// own level (95.3 % of MOB rows, MEASURED 2026-09-14); uniques carry
	// their own, larger value.
	ColExpToGive = 79
)

// minFields is the shortest characterdata row the exporter maps: every column
// above must exist. Retail rows are 105 fields, or 104 -- the tail column
// missing -- for 16,080 rows (7,329 of them monsters) across 34 part files
// (MEASURED, round 654's review); every column read here sits well before it.
const minFields = ColSkills + NumSkills

// CSVColumns is the header cmd/export-refdata -mode monsters writes and Read
// checks. The order is the CSV's; the meanings are the constants above. A
// later round APPENDS columns (never inserts): Read requires the first
// RequiredCSVColumns by name and ignores any it does not know past them, so an
// older server reads a newer CSV. A column appended here must be optional in
// parseRecord -- read only when the row has it -- so a newer server still
// reads an older CSV.
var CSVColumns = []string{
	"ID", "CodeName", "OrgCodeName", "OrgID", "NameKey", "Name", "TypeID4", "Rarity",
	"Level", "MaxHP", "WalkSpeed", "RunSpeed", "BCRadius",
	"Col71", "Col72", "Col73", "Col74", "Col75", "Col76", "Col77", "Col78",
	"Skill1", "Skill2", "Skill3", "Skill4", "Skill5", "Skill6", "Skill7", "Skill8", "Skill9", "Skill10",
	"Model", "ModelFromOrg", "GoldMin", "GoldMax",
	// Round 712, appended (optional on read): col 79.
	"ExpToGive",
}

// RequiredCSVColumns is the prefix every monsters CSV must carry: the 35
// columns round 654 wrote.
const RequiredCSVColumns = 35

// CSV column positions, for the reader and the tests.
const (
	cID = iota
	cCodeName
	cOrgCodeName
	cOrgID
	cNameKey
	cName
	cTypeID4
	cRarity
	cLevel
	cMaxHP
	cWalkSpeed
	cRunSpeed
	cBCRadius
	cParams // 8 columns
)

const (
	cSkills       = cParams + NumParams // 10 columns
	cModel        = cSkills + NumSkills
	cModelFromOrg = cModel + 1
	cGoldMin      = cModel + 2
	cGoldMax      = cModel + 3
	cExpToGive    = cModel + 4
	numCSVColumns = cModel + 5
)

// IsMonster reports whether a tab-split characterdata row is a monster:
// TypeID (1,2,1,x). Player bodies are (1,1,...), NPCs (1,2,2,...).
func IsMonster(cols []string) bool {
	if len(cols) <= ColTypeID4 {
		return false
	}
	return field(cols, ColTypeID1) == "1" && field(cols, ColTypeID2) == "2" && field(cols, ColTypeID3) == "1"
}

// field is a trimmed column, "" past the end.
func field(cols []string, i int) string {
	if i >= len(cols) {
		return ""
	}
	return strings.TrimSpace(cols[i])
}

// num is a trimmed numeric column, "0" when it is empty or past the end.
func num(cols []string, i int) string {
	if s := field(cols, i); s != "" {
		return s
	}
	return "0"
}

// noString is the tables' filler for "no string here".
const noString = "xxx"

// ownModel is a row's own model path, "" for none.
func ownModel(cols []string) string {
	m := field(cols, ColModel)
	if m == noString {
		return ""
	}
	return m
}

// Exporter collects characterdata rows across the table's parts and turns
// the monsters among them into CSV records. The parts OVERLAP the way
// itemdata's do (MEASURED on a retail archive: 33,948 rows, 17,868 ids), so a
// row seen again replaces the earlier one -- LAST occurrence wins, the rule
// the items and skills exports follow, which is why the parts are fed in the
// index file's order (deploy/README.md). Every row is kept, monster or not,
// because an Org code name may name any row.
type Exporter struct {
	byID   map[string][]string
	order  []string
	byCode map[string]string // code name -> id of the row that last carried it

	// Rows, Dupes and Conflicts count what Add saw: rows with a numeric id,
	// ids seen again, and repeats whose fields differ.
	Rows, Dupes, Conflicts int
}

// NewExporter returns an empty Exporter.
func NewExporter() *Exporter {
	return &Exporter{byID: map[string][]string{}, byCode: map[string]string{}}
}

// Add takes one tab-split characterdata row. A row whose id is not a number
// (a header, a comment that slipped through) is ignored and reported false.
func (e *Exporter) Add(cols []string) bool {
	id := field(cols, ColID)
	if _, err := strconv.ParseInt(id, 10, 64); err != nil {
		return false
	}
	e.Rows++
	if prev, seen := e.byID[id]; seen {
		e.Dupes++
		if !sameFields(prev, cols) {
			e.Conflicts++
		}
		if old := field(prev, ColCodeName); e.byCode[old] == id {
			delete(e.byCode, old)
		}
	} else {
		e.order = append(e.order, id)
	}
	e.byID[id] = cols
	e.byCode[field(cols, ColCodeName)] = id
	return true
}

// sameFields compares two rows field by field, a field past a row's end
// reading as empty: the parts repeat rows at 104 and 105 fields, the 105th
// empty (MEASURED: all 16,080 repeats of a retail archive differ in width, 2
// in a value), and a width alone is not a conflict.
func sameFields(a, b []string) bool {
	n := len(a)
	if len(b) > n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if field(a, i) != field(b, i) {
			return false
		}
	}
	return true
}

// ExportStats is what Records produced, for the exporter's report.
type ExportStats struct {
	Monsters     int         // records written
	Short        int         // monster rows too short to map (none in retail)
	OwnModel     int         // with a model of their own
	OrgModel     int         // model "xxx", taken from the Org row
	NoModel      int         // neither
	Named        int         // whose name key resolved in textdata_object
	Gold         int         // whose level has a levelgold row
	ByRarity     map[int]int // records per col-15 rarity
	ByTypeID4    map[int]int // records per TypeID4
	WithSkill    int         // with a non-zero col 83
	WithOrgRow   int         // whose col 4 names a row in the table
	OrgUnmatched int         // whose col 4 is not "xxx" but names no row
}

// Records returns one CSV record per monster row, in first-seen id order,
// with the Org columns resolved against every row the Exporter holds. gold
// (levelgold.txt by level) and names (textdata_object.txt, SN_ key -> the
// English the client draws) may be nil: their columns are then 0 and "".
func (e *Exporter) Records(gold LevelGold, names ObjectNames) ([][]string, ExportStats) {
	st := ExportStats{ByRarity: map[int]int{}, ByTypeID4: map[int]int{}}
	var out [][]string
	for _, id := range e.order {
		cols := e.byID[id]
		if !IsMonster(cols) {
			continue
		}
		if len(cols) < minFields {
			st.Short++
			continue
		}
		rec := make([]string, numCSVColumns)
		rec[cID] = id
		rec[cCodeName] = field(cols, ColCodeName)
		org := field(cols, ColOrgCodeName)
		if org == noString {
			org = ""
		}
		rec[cOrgCodeName] = org
		rec[cOrgID] = "0"
		var orgRow []string
		if org != "" {
			if oid, ok := e.byCode[org]; ok {
				orgRow = e.byID[oid]
				rec[cOrgID] = oid
				st.WithOrgRow++
			} else {
				st.OrgUnmatched++
			}
		}
		key := field(cols, ColNameKey)
		if key == noString {
			key = ""
		}
		rec[cNameKey] = key
		if n, ok := names[key]; ok && key != "" {
			rec[cName] = n
			st.Named++
		}
		rec[cTypeID4] = num(cols, ColTypeID4)
		rec[cRarity] = num(cols, ColRarity)
		rec[cLevel] = num(cols, ColLevel)
		rec[cMaxHP] = num(cols, ColMaxHP)
		rec[cWalkSpeed] = num(cols, ColWalkSpeed)
		rec[cRunSpeed] = num(cols, ColRunSpeed)
		rec[cBCRadius] = num(cols, ColBCRadius)
		for i := 0; i < NumParams; i++ {
			rec[cParams+i] = num(cols, ColParams+i)
		}
		for i := 0; i < NumSkills; i++ {
			rec[cSkills+i] = num(cols, ColSkills+i)
		}
		rec[cModelFromOrg] = "0"
		if m := ownModel(cols); m != "" {
			rec[cModel] = m
			st.OwnModel++
		} else if orgRow != nil && ownModel(orgRow) != "" {
			rec[cModel] = ownModel(orgRow)
			rec[cModelFromOrg] = "1"
			st.OrgModel++
		} else {
			st.NoModel++
		}
		rec[cExpToGive] = num(cols, ColExpToGive)
		rec[cGoldMin], rec[cGoldMax] = "0", "0"
		if lvl, err := strconv.Atoi(rec[cLevel]); err == nil {
			if g, ok := gold[lvl]; ok {
				rec[cGoldMin] = strconv.FormatInt(g[0], 10)
				rec[cGoldMax] = strconv.FormatInt(g[1], 10)
				st.Gold++
			}
		}
		if r, err := strconv.Atoi(rec[cRarity]); err == nil {
			st.ByRarity[r]++
		}
		if t, err := strconv.Atoi(rec[cTypeID4]); err == nil {
			st.ByTypeID4[t]++
		}
		if rec[cSkills] != "0" {
			st.WithSkill++
		}
		out = append(out, rec)
	}
	st.Monsters = len(out)
	return out, st
}

// LevelGold is levelgold.txt: level -> {min, max}. The file is (level, min,
// max), a byte then two dwords per row (docs/RE_COMPLETION.md, the type-32
// tokenizer). The rows are READ; that the server's kill gold rolls from this
// table is INFERRED, exactly as combat.RollGold says -- the same join the
// hand-typed roster made.
type LevelGold map[int][2]int64

// ParseLevelGold reads levelgold.txt's tab-split rows. A row that is not
// three numbers is skipped.
func ParseLevelGold(rows [][]string) LevelGold {
	out := LevelGold{}
	for _, cols := range rows {
		if len(cols) < 3 {
			continue
		}
		lvl, e1 := strconv.Atoi(strings.TrimSpace(cols[0]))
		lo, e2 := strconv.ParseInt(strings.TrimSpace(cols[1]), 10, 64)
		hi, e3 := strconv.ParseInt(strings.TrimSpace(cols[2]), 10, 64)
		if e1 != nil || e2 != nil || e3 != nil {
			continue
		}
		out[lvl] = [2]int64{lo, hi}
	}
	return out
}

// ObjectNames is textdata_object.txt resolved to the text the client draws
// for each SN_ key.
type ObjectNames map[string]string

// The object-name table's columns: 0 the service flag (the client loads a
// row only when it reads 1 -- TextStringManager 0x8cac30, READ), 1 the token,
// 8 the conventional English column. See client/scripts/ui/ui_text_table.gd,
// whose rule this ports.
const (
	nameColService   = 0
	nameColToken     = 1
	nameColEnglish   = 8
	nameColFirstLang = 3
)

// ParseObjectNames is the client's UiTextTable.parse over textdata_object's
// tab-split rows, ported: service-1 rows only; the FIRST row of a key wins
// (the loader's hash map keeps the existing entry, READ, round 634's review);
// the English is column 8 when it holds Latin text, else the first Latin
// field after it, else the first from column 3; with no Latin anywhere, the
// field at column 8 as it stands (what the client draws -- often "0").
func ParseObjectNames(rows [][]string) ObjectNames {
	out := ObjectNames{}
	for _, cols := range rows {
		if len(cols) <= nameColToken {
			continue
		}
		if n, err := strconv.Atoi(strings.TrimSpace(cols[nameColService])); err != nil || n != 1 {
			continue
		}
		token := strings.TrimSpace(cols[nameColToken])
		if token == "" {
			continue
		}
		if _, seen := out[token]; seen {
			continue
		}
		val := pickLanguage(cols, nameColEnglish)
		if val == "" && nameColEnglish < len(cols) {
			val = strings.TrimSpace(cols[nameColEnglish])
		}
		out[token] = val
	}
	return out
}

func usableLatin(s string) bool {
	s = strings.TrimSpace(s)
	if s == "" || s == "0" {
		return false
	}
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			return true
		}
	}
	return false
}

func pickLanguage(cols []string, preferred int) string {
	if preferred < len(cols) && usableLatin(cols[preferred]) {
		return strings.TrimSpace(cols[preferred])
	}
	for i := preferred + 1; i < len(cols); i++ {
		if usableLatin(cols[i]) {
			return strings.TrimSpace(cols[i])
		}
	}
	for i := nameColFirstLang; i < len(cols); i++ {
		if usableLatin(cols[i]) {
			return strings.TrimSpace(cols[i])
		}
	}
	return ""
}

// Row is one species as the CSV states it.
type Row struct {
	ID          int64
	CodeName    string
	OrgCodeName string // col 4, "" for "xxx"; see ColOrgCodeName
	OrgID       int64  // the id of the row OrgCodeName names; 0 when none
	NameKey     string // col 5
	// Name is textdata_object's resolution of NameKey as the client draws it
	// ("" when the export had no textdata_object). DisplayName picks what a
	// server line shows.
	Name      string
	TypeID4   int // col 12: 1 field monsters, 2/3 the job-trade thieves and hunters, 4 structures and quest rows (MEASURED census); what the server does with it is OPEN
	Rarity    int
	Level     int
	MaxHP     int
	WalkSpeed float64
	RunSpeed  float64
	BCRadius  int
	// Params is cols 71..78 (see ColParams for what each is).
	Params [NumParams]int
	// Skills is cols 83..92 as the row states them, zeros included.
	Skills [NumSkills]int64
	// Model is the row's own .bsr, or -- when it has none ("xxx") and its
	// Org row does -- the Org's, with ModelFromOrg set. The server draws
	// nothing and only records it; whether the retail client draws the Org's
	// model for such a row is OPEN (round 655).
	Model        string
	ModelFromOrg bool
	// GoldMin/GoldMax are levelgold.txt at Level (0 when the export had none).
	GoldMin, GoldMax int64
	// ExpToGive is col 79, the kill's base EXP (ColExpToGive);
	// HasExpToGive is false for a CSV exported before round 712.
	ExpToGive    int64
	HasExpToGive bool
}

// Defense is col 71, the flat physical absorption (param 5, READ).
func (r Row) Defense() int { return r.Params[0] }

// Block is col 76, tag 'bri' (param 10).
func (r Row) Block() int { return r.Params[5] }

// Critical is col 78, tag 'cri' (param 12).
func (r Row) Critical() int { return r.Params[7] }

// DisplayName is what a server line calls the species: the client's English
// name when the export resolved one it would draw as text, else the code name.
// OURS: the fallback to the code name is our choice (the client would draw
// "0" or nothing), so a GM line never names a monster "0".
func (r Row) DisplayName() string {
	if usableLatin(r.Name) {
		return r.Name
	}
	return r.CodeName
}

// Table is the loaded species table.
type Table struct {
	Rows   []Row
	byID   map[int64]int
	byCode map[string]int
}

// ByID returns the species with characterdata id id.
func (t *Table) ByID(id int64) (Row, bool) {
	if t == nil {
		return Row{}, false
	}
	i, ok := t.byID[id]
	if !ok {
		return Row{}, false
	}
	return t.Rows[i], true
}

// ByCode returns the species with code name code (case-insensitive).
func (t *Table) ByCode(code string) (Row, bool) {
	if t == nil {
		return Row{}, false
	}
	i, ok := t.byCode[strings.ToUpper(strings.TrimSpace(code))]
	if !ok {
		return Row{}, false
	}
	return t.Rows[i], true
}

// Len is how many species the table holds.
func (t *Table) Len() int {
	if t == nil {
		return 0
	}
	return len(t.Rows)
}

// LoadCSV reads a monsters CSV. A configured path that cannot be read is an
// error, never an empty table (the npcpos rule, spawn.LoadCSV).
func LoadCSV(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Read(f)
}

// Read parses a monsters CSV: CSVColumns as the header (checked by name, so
// a CSV from another mode or a shifted export fails here and not as wrong
// numbers), then one row per species.
func Read(r io.Reader) (*Table, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("species: reading header: %w", err)
	}
	if len(header) < RequiredCSVColumns {
		return nil, fmt.Errorf("species: not a monsters CSV: %d header fields, want at least %d", len(header), RequiredCSVColumns)
	}
	for i, h := range header {
		if i >= len(CSVColumns) {
			break // a column a later round added: not read here
		}
		if strings.TrimSpace(h) != CSVColumns[i] {
			return nil, fmt.Errorf("species: not a monsters CSV: header field %d is %q, want %q", i, h, CSVColumns[i])
		}
	}
	t := &Table{byID: map[int64]int{}, byCode: map[string]int{}}
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("species: line %d: %w", line, err)
		}
		if len(rec) != len(header) {
			return nil, fmt.Errorf("species: line %d: %d fields, the header has %d", line, len(rec), len(header))
		}
		row, err := parseRecord(rec)
		if err != nil {
			return nil, fmt.Errorf("species: line %d: %w", line, err)
		}
		if _, dup := t.byID[row.ID]; dup {
			return nil, fmt.Errorf("species: line %d: id %d twice", line, row.ID)
		}
		t.byID[row.ID] = len(t.Rows)
		t.byCode[strings.ToUpper(row.CodeName)] = len(t.Rows)
		t.Rows = append(t.Rows, row)
	}
	return t, nil
}

func parseRecord(rec []string) (Row, error) {
	if len(rec) < RequiredCSVColumns {
		return Row{}, fmt.Errorf("%d fields, want at least %d", len(rec), RequiredCSVColumns)
	}
	var firstErr error
	i64 := func(c int) int64 {
		v, err := strconv.ParseInt(strings.TrimSpace(rec[c]), 10, 64)
		if err != nil && firstErr == nil {
			firstErr = fmt.Errorf("column %s: %q is not an integer", CSVColumns[c], rec[c])
		}
		return v
	}
	i := func(c int) int { return int(i64(c)) }
	f64 := func(c int) float64 {
		v, err := strconv.ParseFloat(strings.TrimSpace(rec[c]), 64)
		if err != nil && firstErr == nil {
			firstErr = fmt.Errorf("column %s: %q is not a number", CSVColumns[c], rec[c])
		}
		return v
	}
	r := Row{
		ID:           i64(cID),
		CodeName:     strings.TrimSpace(rec[cCodeName]),
		OrgCodeName:  strings.TrimSpace(rec[cOrgCodeName]),
		OrgID:        i64(cOrgID),
		NameKey:      strings.TrimSpace(rec[cNameKey]),
		Name:         strings.TrimSpace(rec[cName]),
		TypeID4:      i(cTypeID4),
		Rarity:       i(cRarity),
		Level:        i(cLevel),
		MaxHP:        i(cMaxHP),
		WalkSpeed:    f64(cWalkSpeed),
		RunSpeed:     f64(cRunSpeed),
		BCRadius:     i(cBCRadius),
		Model:        strings.TrimSpace(rec[cModel]),
		ModelFromOrg: i(cModelFromOrg) != 0,
		GoldMin:      i64(cGoldMin),
		GoldMax:      i64(cGoldMax),
	}
	for k := 0; k < NumParams; k++ {
		r.Params[k] = i(cParams + k)
	}
	for k := 0; k < NumSkills; k++ {
		r.Skills[k] = i64(cSkills + k)
	}
	if len(rec) > cExpToGive {
		r.ExpToGive, r.HasExpToGive = i64(cExpToGive), true
	}
	if firstErr != nil {
		return Row{}, firstErr
	}
	if r.ID <= 0 || r.CodeName == "" {
		return Row{}, fmt.Errorf("id %d / code name %q: a species needs both", r.ID, r.CodeName)
	}
	return r, nil
}

// SkillRow is what a species' attack needs of one skilldata row: ReuseDelay
// (col 14), Range (col 21), the 'att' param's min/max, and AI_AttackChance
// (col 66, CRefSkill+0x164 -- the weight AI::CAISkill_Basic::PickSkill draws
// by, READ, monster_ai.md). ChanceKnown is false when the skill export
// predates round 654's column: 0 is then not a real "never drawn".
type SkillRow struct {
	ReuseMs, Range int
	AttMin, AttMax int
	Chance         int
	ChanceKnown    bool
	// Status is the row's status runs (refdata.Skill.StatusParams, round 659).
	Status string
}

// SkillLookup resolves a skilldata id; ok is false for an id the table does
// not hold.
type SkillLookup func(id int64) (SkillRow, bool)

// RefdataLookup adapts a reference-skill getter (the in-memory store fed by
// -skills-csv, or PostgreSQL filled by import-refdata -- both implement it)
// to a SkillLookup.
func RefdataLookup(get func(id int64) (*refdata.Skill, error)) SkillLookup {
	return func(id int64) (SkillRow, bool) {
		sk, err := get(id)
		if err != nil || sk == nil {
			return SkillRow{}, false
		}
		return SkillRow{
			ReuseMs: sk.ReuseDelayMs, Range: sk.Range,
			AttMin: sk.DamageMin, AttMax: sk.DamageMax,
			Chance: sk.AIAttackChance, ChanceKnown: sk.AIAttackChance >= 0,
			Status: sk.StatusParams,
		}, true
	}
}

// Attacks is a species' attack list as the monster AI uses it.
type Attacks struct {
	// Primary is the col-83 skill (combat.Species.AttackReuseMs/Range/Min/Max
	// carry its numbers); HasPrimary is false when col 83 is 0 or does not
	// resolve.
	Primary    combat.MonsterSkill
	HasPrimary bool
	// Skills is every col 83..92 id that resolves, in column order -- the
	// engine registers each one that does (BindSkillsAndRanges).
	Skills []combat.MonsterSkill
	// WholeList is true when every non-zero id resolved and every resolved
	// row's AI_AttackChance is known: only then is Skills the list the
	// engine would draw from.
	WholeList bool
	// Unresolved lists the non-zero ids the lookup did not hold.
	Unresolved []int64
}

// Attacks resolves the row's skill columns through lookup.
func (r Row) Attacks(lookup SkillLookup) Attacks {
	a := Attacks{WholeList: true}
	for k, id := range r.Skills {
		if id == 0 {
			continue
		}
		sr, ok := SkillRow{}, false
		if lookup != nil {
			sr, ok = lookup(id)
		}
		if !ok {
			a.Unresolved = append(a.Unresolved, id)
			a.WholeList = false
			continue
		}
		if !sr.ChanceKnown {
			a.WholeList = false
		}
		ms := combat.MonsterSkill{ID: id, ReuseMs: sr.ReuseMs, Range: sr.Range, AttMin: sr.AttMin, AttMax: sr.AttMax, Chance: sr.Chance, Status: sr.Status}
		if k == 0 {
			a.Primary, a.HasPrimary = ms, true
		}
		a.Skills = append(a.Skills, ms)
	}
	return a
}
