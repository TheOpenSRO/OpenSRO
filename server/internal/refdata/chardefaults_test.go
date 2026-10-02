package refdata

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Round 692: the shard's `_RefCharDefault_*` and `_RefCharGen` exports, read
// in their own format (EXTERNAL; the rows here are SYNTHETIC -- made-up ids
// and codes in the export's shape, none of the export's rows), and
// `_AddNewChar`'s rule over them (READ): Race = Country or 3, quests only at
// RequiredLevel 1 and Service 1. NEGATIVE: before round 692 none of
// LoadCharDefaults, LoadRefCharGen or CompareRefCharGen exists and this file
// does not compile.

// Synthetic: a BOM and CRLF as the export writes them, a blank line, Race
// 0/1/3, a duplicate, a Race 2 row, and quests failing each filter.
const (
	testMasteries = "\xef\xbb\xbfRace,MasteryID\r\n0,9001\r\n0,9002\r\n1,9101\r\n1,9102\r\n3,9301\r\n\r\n"
	testSkills    = "Race,SkillID\r\n3,8301\r\n0,8001\r\n1,8101\r\n0,8001\r\n2,8201\r\n"
	testQuests    = "Service,ID,Race,CodeName,RequiredLevel\r\n1,1,3,QSYN_ALL_LATER,5\r\n1,2,3,QSYN_ALL_A,1\r\n" +
		"1,3,0,QSYN_CH_ONLY,1\r\n1,4,3,QSYN_ALL_B,1\r\n0,5,1,QSYN_OFF_SERVICE,1\r\n1,6,1,QSYN_EU_ONLY,1\r\n"
)

func loadTestDefaults(t *testing.T) *CharDefaults {
	t.Helper()
	d, err := LoadCharDefaults(strings.NewReader(testMasteries), strings.NewReader(testSkills), strings.NewReader(testQuests))
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestCharDefaultsByRace(t *testing.T) {
	d := loadTestDefaults(t)
	if got, want := d.Masteries(0), []int64{9001, 9002, 9301}; !reflect.DeepEqual(got, want) {
		t.Errorf("China masteries %v, want %v", got, want)
	}
	if got, want := d.Masteries(1), []int64{9101, 9102, 9301}; !reflect.DeepEqual(got, want) {
		t.Errorf("Europe masteries %v, want %v", got, want)
	}
	// A duplicated row is given once (OURS); a Race 2 row to nobody.
	if got, want := d.Skills(0), []int64{8301, 8001}; !reflect.DeepEqual(got, want) {
		t.Errorf("China skills %v, want %v", got, want)
	}
	if got, want := d.Skills(1), []int64{8301, 8101}; !reflect.DeepEqual(got, want) {
		t.Errorf("Europe skills %v, want %v", got, want)
	}
	// Both are reported.
	w := strings.Join(d.Warnings(), "\n")
	if !strings.Contains(w, "SkillID 8201 has Race 2") || !strings.Contains(w, "SkillID 8001 given twice to Country 0") {
		t.Errorf("warnings %q, want the Race 2 row and the duplicate", w)
	}
	if n := len(d.Warnings()); n != 2 {
		t.Errorf("%d warnings, want 2: %q", n, w)
	}
	codes := func(qs []DefaultQuest) []string {
		var out []string
		for _, q := range qs {
			out = append(out, q.CodeName)
		}
		return out
	}
	// RequiredLevel 5 and Service 0 rows are not given at create (READ).
	if got, want := codes(d.Quests(0)), []string{"QSYN_ALL_A", "QSYN_CH_ONLY", "QSYN_ALL_B"}; !reflect.DeepEqual(got, want) {
		t.Errorf("China quests %v, want %v", got, want)
	}
	if got, want := codes(d.Quests(1)), []string{"QSYN_ALL_A", "QSYN_ALL_B", "QSYN_EU_ONLY"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Europe quests %v, want %v", got, want)
	}
	if m, s, q := d.Counts(); m != 5 || s != 5 || q != 6 {
		t.Errorf("counts %d/%d/%d, want 5/5/6", m, s, q)
	}
	var none *CharDefaults
	if none.Masteries(0) != nil || none.Skills(0) != nil || none.Quests(0) != nil {
		t.Error("a nil set gives something")
	}
}

func TestCharDefaultsRefusesAWrongHeader(t *testing.T) {
	_, err := LoadCharDefaults(strings.NewReader("Race,Mastery\r\n0,9001\r\n"), strings.NewReader(testSkills), strings.NewReader(testQuests))
	if err == nil {
		t.Error("a wrong mastery header loaded")
	}
	_, err = LoadCharDefaults(strings.NewReader(testMasteries), strings.NewReader(testSkills), strings.NewReader("Service,ID,Race,CodeName,RequiredLevel\r\n1,x,3,Q,1\r\n"))
	if err == nil {
		t.Error("a non-numeric quest ID loaded")
	}
}

func TestCharDefaultsDir(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{CharDefaultMasteryFile: testMasteries, CharDefaultSkillFile: testSkills} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := LoadCharDefaultsDir(dir); err == nil {
		t.Fatal("a directory without the quest table loaded")
	}
	if err := os.WriteFile(filepath.Join(dir, CharDefaultQuestFile), []byte(testQuests), 0o644); err != nil {
		t.Fatal(err)
	}
	d, err := LoadCharDefaultsDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if m, s, q := d.Counts(); m != 5 || s != 5 || q != 6 {
		t.Errorf("counts %d/%d/%d, want 5/5/6", m, s, q)
	}
}

func TestCompareRefCharGen(t *testing.T) {
	set := NewCreatableSet([]Creatable{
		{ID: 1907, Kind: CreatableModel}, {ID: 3632, Kind: CreatableItem}, {ID: 10886, Kind: CreatableItem},
		{ID: 3655, Kind: CreatableAmmo, Code: AmmoArrowCode},
	})
	ids, err := LoadRefCharGen(strings.NewReader("Service,RefObjID\r\n1,10886\r\n1,1907\r\n1,3632\r\n0,4000\r\n"))
	if err != nil {
		t.Fatal(err)
	}
	if want := []int64{1907, 3632, 10886}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids %v, want %v (Service 1 only, sorted)", ids, want)
	}
	if missing, extra := set.CompareRefCharGen(ids); len(missing) != 0 || len(extra) != 0 {
		t.Errorf("agreeing lists: missing %v extra %v", missing, extra)
	}
	missing, extra := set.CompareRefCharGen([]int64{1907, 3632, 11617})
	if !reflect.DeepEqual(missing, []int64{11617}) || !reflect.DeepEqual(extra, []int64{10886}) {
		t.Errorf("missing %v extra %v, want [11617] [10886]", missing, extra)
	}
}

// TestRefCharGenAgreesWithTheRule runs on real exports when both are given
// (they are never in the repo): SRREVAMP_TEST_CHARGEN_CSV, the rule's
// chargen.csv from the operator's archive, and SRREVAMP_TEST_REFCHARGEN_CSV,
// the shard's `_RefCharGen.csv`. Round 692 ran it on the render box's two
// (MEASURED: the same 104 ids).
func TestRefCharGenAgreesWithTheRule(t *testing.T) {
	rulePath, refPath := os.Getenv("SRREVAMP_TEST_CHARGEN_CSV"), os.Getenv("SRREVAMP_TEST_REFCHARGEN_CSV")
	if rulePath == "" || refPath == "" {
		t.Skip("SRREVAMP_TEST_CHARGEN_CSV and SRREVAMP_TEST_REFCHARGEN_CSV not set")
	}
	f, err := os.Open(rulePath)
	if err != nil {
		t.Fatal(err)
	}
	set, err := LoadCreatableCSV(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	g, err := os.Open(refPath)
	if err != nil {
		t.Fatal(err)
	}
	ids, err := LoadRefCharGen(g)
	g.Close()
	if err != nil {
		t.Fatal(err)
	}
	missing, extra := set.CompareRefCharGen(ids)
	if len(missing) != 0 || len(extra) != 0 {
		t.Errorf("the rule and _RefCharGen differ: in _RefCharGen only %v, in the rule only %v", missing, extra)
	}
	t.Logf("rule %d ids, _RefCharGen %d ids, missing %d, extra %d", set.Len(), len(ids), len(missing), len(extra))
}

// TestCharDefaultsRealExport runs on the shard's export when
// SRREVAMP_TEST_CHARDEFAULTS_DIR names a directory holding it (never in the
// repo), and skips otherwise. It checks the counts round 692 MEASURED (China
// 7 masteries, 4 skills, 3 level-1 quests; Europe 6, 10, 2), that the
// masteries are each race's own (skillmasterydata.txt: China 257-276, Europe
// 513-518), and that nothing in it is odd enough to warn about.
func TestCharDefaultsRealExport(t *testing.T) {
	dir := os.Getenv("SRREVAMP_TEST_CHARDEFAULTS_DIR")
	if dir == "" {
		t.Skip("SRREVAMP_TEST_CHARDEFAULTS_DIR not set")
	}
	d, err := LoadCharDefaultsDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		country, masteries, skills, quests int
		lo, hi                             int64
	}{{0, 7, 4, 3, 257, 276}, {1, 6, 10, 2, 513, 518}} {
		ms := d.Masteries(c.country)
		if len(ms) != c.masteries || len(d.Skills(c.country)) != c.skills || len(d.Quests(c.country)) != c.quests {
			t.Errorf("Country %d: %d/%d/%d, want %d/%d/%d", c.country, len(ms), len(d.Skills(c.country)),
				len(d.Quests(c.country)), c.masteries, c.skills, c.quests)
		}
		for _, id := range ms {
			if id < c.lo || id > c.hi {
				t.Errorf("Country %d: mastery %d outside %d..%d", c.country, id, c.lo, c.hi)
			}
		}
	}
	if w := d.Warnings(); len(w) != 0 {
		t.Errorf("warnings on the export: %q", w)
	}
}
