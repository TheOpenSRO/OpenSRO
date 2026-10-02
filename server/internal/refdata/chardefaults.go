package refdata

// A new character's default masteries, skills and quests (round 692), and
// the shard's own list of creatable ids.
//
// READ (this package's procedure; EXTERNAL data): the shard DB's
// `_AddNewChar` takes the new character's Country (`_GetObjCountry
// @RefCharID`) and inserts
//
//   - every `_RefCharDefault_SkillMastery` row whose Race is that Country or 3,
//     into `_CharSkillMastery` at Level 0;
//   - every `_RefCharDefault_Skill` row whose Race is that Country or 3, into
//     `_CharSkill` with Enable 1;
//   - every quest whose CodeName is a `_RefCharDefault_Quest` row with Race
//     that Country or 3, RequiredLevel 1 and Service 1, into `_CharQuest` with
//     Status 1, AchievementCount 0 (the row's quest id is `_RefQuest`'s, looked
//     up by CodeName -- the table's own ID column is not used).
//
// Race 0 is China and 1 Europe (INFERRED: `_GetObjCountry`'s body was not
// exported; the ids agree -- Race 0's masteries are China's 257-276 and Race
// 1's Europe's 513-518, MEASURED in skillmasterydata.txt -- and Country is
// characterdata column 14, 0 China / 1 Europe, as the catalogue reads it).
//
// The tables are the shard DB's (EXTERNAL, a private shard's): nothing is
// shipped. The operator copies the export's CSVs into a directory and points
// cmd/server's -chardefaults-dir at it (deploy/README.md, "Character
// defaults"). docs/protocol/charselect.md section 6 records what was read.

import (
	"bufio"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// RaceAny is the Race value every Country matches (READ, `_AddNewChar`'s
// `Race = @country or Race = 3`).
const RaceAny = 3

// The export's file names: the table names, as the shard DB export writes
// them (`/opt/sro-files/db/csv/charsel/` on the render box).
const (
	CharDefaultMasteryFile = "_RefCharDefault_SkillMastery.csv"
	CharDefaultSkillFile   = "_RefCharDefault_Skill.csv"
	CharDefaultQuestFile   = "_RefCharDefault_Quest.csv"
	RefCharGenFile         = "_RefCharGen.csv"
)

// DefaultQuest is one `_RefCharDefault_Quest` row.
type DefaultQuest struct {
	Service       int
	ID            int64 // the table's own row id, not a quest id (READ: the procedure joins on CodeName)
	Race          int
	CodeName      string
	RequiredLevel int
}

type raceID struct {
	race int
	id   int64
}

// CharDefaults is the three `_RefCharDefault_*` tables.
type CharDefaults struct {
	masteries []raceID
	skills    []raceID
	quests    []DefaultQuest
	warnings  []string
}

// validRace reports whether a Race value is one `_AddNewChar` can match: a
// Country (0 China, 1 Europe) or RaceAny. Any other value never matches a
// character (READ: the procedure's `Race = @country or Race = 3`), so such a
// row is dead data, kept but reported.
func validRace(r int) bool { return r == 0 || r == 1 || r == RaceAny }

// NewCharDefaults builds a set from rows (tests and the loader). masteries
// and skills are {Race, ID} pairs. Rows no character can match (a Race other
// than 0, 1 or 3) and duplicates are reported by Warnings.
//
// Duplicates: a second row giving the same character the same mastery or
// skill (same id, matching Race sets overlapping) would break `_CharSkill` /
// `_CharSkillMastery`'s key, and the procedure would roll the create back
// (INFERRED from its error path: an insert error returns -15/-16). srrevamp
// gives the id once instead (OURS) and says so at boot.
func NewCharDefaults(masteries, skills [][2]int64, quests []DefaultQuest) *CharDefaults {
	d := &CharDefaults{quests: append([]DefaultQuest(nil), quests...)}
	for _, m := range masteries {
		d.masteries = append(d.masteries, raceID{int(m[0]), m[1]})
	}
	for _, s := range skills {
		d.skills = append(d.skills, raceID{int(s[0]), s[1]})
	}
	d.warnings = append(d.warnings, checkRaceIDs(CharDefaultMasteryFile, "MasteryID", d.masteries)...)
	d.warnings = append(d.warnings, checkRaceIDs(CharDefaultSkillFile, "SkillID", d.skills)...)
	seen := map[[2]any]bool{}
	for _, q := range d.quests {
		if !validRace(q.Race) {
			d.warnings = append(d.warnings, fmt.Sprintf("%s: %s has Race %d, which no character matches", CharDefaultQuestFile, q.CodeName, q.Race))
		}
		for _, country := range []int{0, 1} {
			if !raceMatches(q.Race, country) {
				continue
			}
			k := [2]any{country, q.CodeName}
			if seen[k] && q.RequiredLevel == 1 && q.Service == 1 {
				d.warnings = append(d.warnings, fmt.Sprintf("%s: %s given twice to Country %d; recorded once (OURS)", CharDefaultQuestFile, q.CodeName, country))
			}
			if q.RequiredLevel == 1 && q.Service == 1 {
				seen[k] = true
			}
		}
	}
	return d
}

func checkRaceIDs(file, col string, rows []raceID) []string {
	var out []string
	seen := map[[2]int64]bool{}
	for _, r := range rows {
		if !validRace(r.race) {
			out = append(out, fmt.Sprintf("%s: %s %d has Race %d, which no character matches", file, col, r.id, r.race))
			continue
		}
		for _, country := range []int64{0, 1} {
			if !raceMatches(r.race, int(country)) {
				continue
			}
			k := [2]int64{country, r.id}
			if seen[k] {
				out = append(out, fmt.Sprintf("%s: %s %d given twice to Country %d; given once (OURS)", file, col, r.id, country))
			}
			seen[k] = true
		}
	}
	return out
}

// Warnings lists the rows NewCharDefaults found odd (the server logs them at
// boot). Empty on the shard's export (MEASURED, round 692's review).
func (d *CharDefaults) Warnings() []string {
	if d == nil {
		return nil
	}
	return append([]string(nil), d.warnings...)
}

func raceMatches(rowRace, country int) bool { return rowRace == country || rowRace == RaceAny }

func pickByRace(rows []raceID, country int) []int64 {
	var out []int64
	seen := map[int64]bool{}
	for _, r := range rows {
		if raceMatches(r.race, country) && !seen[r.id] {
			seen[r.id] = true
			out = append(out, r.id)
		}
	}
	return out
}

// Masteries is what `_AddNewChar` gives a character of country, at level 0:
// every mastery row of that Race or 3, in the table's order.
func (d *CharDefaults) Masteries(country int) []int64 {
	if d == nil {
		return nil
	}
	return pickByRace(d.masteries, country)
}

// Skills is what `_AddNewChar` gives a character of country, enabled: every
// skill row of that Race or 3, in the table's order.
func (d *CharDefaults) Skills(country int) []int64 {
	if d == nil {
		return nil
	}
	return pickByRace(d.skills, country)
}

// Quests is what `_AddNewChar` starts for a character of country: the rows of
// that Race or 3 with RequiredLevel 1 and Service 1 (READ). The others
// (the higher-level rows on the export) are not given at create.
//
// One more filter the procedure applies is not applied here: it inserts the
// `_RefQuest` id of each CodeName, so a CodeName with no `_RefQuest` row
// gives nothing (READ, the `FROM _RefQuest WHERE CodeName in (...)` join).
// `_RefQuest` was not exported, and the archive's questdata.txt (the
// client's copy) lacks some of the export's codes, so whether each code is in
// the shard's `_RefQuest` is OPEN. Every code passing the READ filters is
// returned -- that it would also pass the join is INFERRED.
func (d *CharDefaults) Quests(country int) []DefaultQuest {
	if d == nil {
		return nil
	}
	var out []DefaultQuest
	seen := map[string]bool{}
	for _, q := range d.quests {
		if raceMatches(q.Race, country) && q.RequiredLevel == 1 && q.Service == 1 && !seen[q.CodeName] {
			seen[q.CodeName] = true
			out = append(out, q)
		}
	}
	return out
}

// Counts is the three tables' row counts, for the boot log.
func (d *CharDefaults) Counts() (masteries, skills, quests int) {
	if d == nil {
		return 0, 0, 0
	}
	return len(d.masteries), len(d.skills), len(d.quests)
}

// The export's headers, exactly (READ, the export's first lines).
var (
	charDefaultMasteryHeader = []string{"Race", "MasteryID"}
	charDefaultSkillHeader   = []string{"Race", "SkillID"}
	charDefaultQuestHeader   = []string{"Service", "ID", "Race", "CodeName", "RequiredLevel"}
	refCharGenHeader         = []string{"Service", "RefObjID"}
)

// readExportCSV reads one export file: a header that must equal want, then
// rows of len(want) fields. A UTF-8 byte-order mark and CRLF line ends (the
// export's own) are accepted; blank lines are skipped.
func readExportCSV(r io.Reader, name string, want []string) ([][]string, error) {
	br := bufio.NewReader(r)
	if b, err := br.Peek(3); err == nil && b[0] == 0xef && b[1] == 0xbb && b[2] == 0xbf {
		br.Discard(3)
	}
	cr := csv.NewReader(br)
	cr.FieldsPerRecord = len(want)
	cr.TrimLeadingSpace = true
	head, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("refdata: %s header: %w", name, err)
	}
	for i := range head {
		head[i] = strings.TrimSpace(head[i])
	}
	if strings.Join(head, ",") != strings.Join(want, ",") {
		return nil, fmt.Errorf("refdata: %s header %q, want %q", name, head, want)
	}
	var rows [][]string
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			return rows, nil
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: %s line %d: %w", name, line, err)
		}
		for i := range rec {
			rec[i] = strings.TrimSpace(rec[i])
		}
		rows = append(rows, rec)
	}
}

func exportInt(rec []string, i int, name string, line int) (int64, error) {
	v, err := strconv.ParseInt(rec[i], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("refdata: %s row %d column %d: %w", name, line, i+1, err)
	}
	return v, nil
}

func loadRaceIDs(r io.Reader, name string, header []string) ([][2]int64, error) {
	rows, err := readExportCSV(r, name, header)
	if err != nil {
		return nil, err
	}
	var out [][2]int64
	for i, rec := range rows {
		race, err := exportInt(rec, 0, name, i+2)
		if err != nil {
			return nil, err
		}
		id, err := exportInt(rec, 1, name, i+2)
		if err != nil {
			return nil, err
		}
		out = append(out, [2]int64{race, id})
	}
	return out, nil
}

// LoadCharDefaults reads the three tables from their readers (the export's
// format: header row, comma-separated).
func LoadCharDefaults(masteries, skills, quests io.Reader) (*CharDefaults, error) {
	ms, err := loadRaceIDs(masteries, CharDefaultMasteryFile, charDefaultMasteryHeader)
	if err != nil {
		return nil, err
	}
	ss, err := loadRaceIDs(skills, CharDefaultSkillFile, charDefaultSkillHeader)
	if err != nil {
		return nil, err
	}
	rows, err := readExportCSV(quests, CharDefaultQuestFile, charDefaultQuestHeader)
	if err != nil {
		return nil, err
	}
	var qs []DefaultQuest
	for i, rec := range rows {
		var n [5]int64
		for _, c := range []int{0, 1, 2, 4} {
			if n[c], err = exportInt(rec, c, CharDefaultQuestFile, i+2); err != nil {
				return nil, err
			}
		}
		if rec[3] == "" {
			return nil, fmt.Errorf("refdata: %s row %d: empty CodeName", CharDefaultQuestFile, i+2)
		}
		qs = append(qs, DefaultQuest{Service: int(n[0]), ID: n[1], Race: int(n[2]), CodeName: rec[3], RequiredLevel: int(n[4])})
	}
	return NewCharDefaults(ms, ss, qs), nil
}

// LoadCharDefaultsDir reads the three tables from dir, by their export names.
func LoadCharDefaultsDir(dir string) (*CharDefaults, error) {
	var files [3]*os.File
	for i, name := range []string{CharDefaultMasteryFile, CharDefaultSkillFile, CharDefaultQuestFile} {
		f, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			for _, g := range files[:i] {
				g.Close()
			}
			return nil, fmt.Errorf("refdata: character defaults: %w", err)
		}
		files[i] = f
	}
	defer func() {
		for _, f := range files {
			f.Close()
		}
	}()
	return LoadCharDefaults(files[0], files[1], files[2])
}

// LoadRefCharGen reads the shard's `_RefCharGen` export: the RefObjIDs of its
// Service 1 rows, sorted. Rows of another Service are left out (READ: the
// export holds only Service 1 rows, so nothing has said what the server does
// with the others; leaving them out is OURS).
func LoadRefCharGen(r io.Reader) ([]int64, error) {
	rows, err := readExportCSV(r, RefCharGenFile, refCharGenHeader)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for i, rec := range rows {
		svc, err := exportInt(rec, 0, RefCharGenFile, i+2)
		if err != nil {
			return nil, err
		}
		id, err := exportInt(rec, 1, RefCharGenFile, i+2)
		if err != nil {
			return nil, err
		}
		if svc == 1 {
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids, nil
}

// CompareRefCharGen compares the catalogue's ids (models and items, not the
// ammunition) with the shard's `_RefCharGen` ids: missing are in the shard's
// list but not the catalogue, extra in the catalogue but not the list. Both
// empty means they agree.
func (s *CreatableSet) CompareRefCharGen(ids []int64) (missing, extra []int64) {
	want := map[int64]bool{}
	for _, id := range ids {
		want[id] = true
		if _, ok := s.Get(id); !ok {
			missing = append(missing, id)
		}
	}
	if s != nil {
		for id := range s.byID {
			if !want[id] {
				extra = append(extra, id)
			}
		}
	}
	sort.Slice(missing, func(i, j int) bool { return missing[i] < missing[j] })
	sort.Slice(extra, func(i, j int) bool { return extra[i] < extra[j] })
	return missing, extra
}
