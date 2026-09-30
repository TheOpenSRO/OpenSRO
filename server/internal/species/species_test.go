package species

import (
	"encoding/csv"
	"strconv"
	"strings"
	"testing"
)

// Every row in these tests is SYNTHETIC: built here, field by field, with
// sentinel values. No game data.

// charRow is a 105-field characterdata row of zeros, "xxx" in the string
// columns, with the given id, code name and TypeID.
func charRow(id int, code string, tid ...string) []string {
	cols := make([]string, 105)
	for i := range cols {
		cols[i] = "0"
	}
	cols[0] = "1"
	cols[104] = "" // a retail 105-field row's last field is empty (MEASURED)
	for _, c := range []int{3, ColOrgCodeName, ColNameKey, 6, ColModel, 53, 54, 55, 56} {
		cols[c] = noString
	}
	cols[ColID] = strconv.Itoa(id)
	cols[ColCodeName] = code
	for i, v := range tid {
		cols[ColTypeID1+i] = v
	}
	return cols
}

func monsterRow(id int, code string) []string { return charRow(id, code, "1", "2", "1", "1") }

func exportCSV(t *testing.T, ex *Exporter, gold LevelGold, names ObjectNames) (*Table, ExportStats) {
	t.Helper()
	recs, st := ex.Records(gold, names)
	var b strings.Builder
	w := csv.NewWriter(&b)
	w.Write(CSVColumns)
	w.WriteAll(recs)
	tab, err := Read(strings.NewReader(b.String()))
	if err != nil {
		t.Fatalf("the export does not load back: %v", err)
	}
	return tab, st
}

// TestColumnIndicesAgainstASyntheticLine: a line with a distinct sentinel in
// every column the table reads comes back with each sentinel in its own field
// -- so a column number off by one lands a wrong sentinel, not a plausible
// number.
func TestColumnIndicesAgainstASyntheticLine(t *testing.T) {
	cols := monsterRow(90001, "MOB_TEST_SENTINEL")
	cols[ColTypeID4] = "7"
	cols[ColNameKey] = "SN_MOB_TEST_SENTINEL"
	cols[ColRarity] = "15"
	cols[ColWalkSpeed] = "46"
	cols[ColRunSpeed] = "47"
	cols[ColBCRadius] = "50"
	cols[ColModel] = "mob\\test\\sentinel.bsr"
	cols[ColLevel] = "57"
	cols[ColMaxHP] = "59"
	for i := 0; i < NumParams; i++ {
		cols[ColParams+i] = strconv.Itoa(71 + i)
	}
	for i := 0; i < NumSkills; i++ {
		cols[ColSkills+i] = strconv.Itoa(8300 + i)
	}
	// Neighbours of every read column carry a different sentinel, so a
	// reader shifted by one picks it up.
	for _, c := range []int{14, 16, 45, 48, 49, 51, 56, 58, 60, 70, 79, 82, 93} {
		cols[c] = "-999"
	}
	ex := NewExporter()
	if !ex.Add(cols) {
		t.Fatal("the row was refused")
	}
	tab, _ := exportCSV(t, ex, LevelGold{57: {1057, 2057}}, ObjectNames{"SN_MOB_TEST_SENTINEL": "Sentinel"})
	r, ok := tab.ByID(90001)
	if !ok {
		t.Fatal("the row is not in the table")
	}
	want := Row{ID: 90001, CodeName: "MOB_TEST_SENTINEL", NameKey: "SN_MOB_TEST_SENTINEL", Name: "Sentinel",
		TypeID4: 7, Rarity: 15, Level: 57, MaxHP: 59, WalkSpeed: 46, RunSpeed: 47, BCRadius: 50,
		Model: "mob\\test\\sentinel.bsr", GoldMin: 1057, GoldMax: 2057}
	for i := 0; i < NumParams; i++ {
		want.Params[i] = 71 + i
	}
	for i := 0; i < NumSkills; i++ {
		want.Skills[i] = int64(8300 + i)
	}
	if r != want {
		t.Fatalf("row = %+v\nwant  %+v", r, want)
	}
	if r.Defense() != 71 || r.Block() != 76 || r.Critical() != 78 {
		t.Errorf("Defense/Block/Critical = %d/%d/%d, want cols 71/76/78", r.Defense(), r.Block(), r.Critical())
	}
	// The column numbers themselves, against the project's recorded map
	// (reference_characterdata_columns, verify_monster_specs.py).
	for name, got := range map[string][2]int{
		"Rarity": {ColRarity, 15}, "WalkSpeed": {ColWalkSpeed, 46}, "RunSpeed": {ColRunSpeed, 47},
		"BCRadius": {ColBCRadius, 50}, "Model": {ColModel, 52}, "Level": {ColLevel, 57}, "MaxHP": {ColMaxHP, 59},
		"Params": {ColParams, 71}, "Skills": {ColSkills, 83}, "Org": {ColOrgCodeName, 4}, "NameKey": {ColNameKey, 5},
		"TypeID1": {ColTypeID1, 9},
	} {
		if got[0] != got[1] {
			t.Errorf("%s is column %d, want %d", name, got[0], got[1])
		}
	}
}

// TestOrgFallbackOnSyntheticClon: a _CLON row whose own model is "xxx" takes
// its Org row's model, flagged, with the Org's id -- even when the Org row
// comes in a LATER part; an Org that has no model, an Org naming no row, and
// "xxx" all leave the model empty.
func TestOrgFallbackOnSyntheticClon(t *testing.T) {
	clon := monsterRow(91001, "MOB_TEST_GHOST_CLON")
	clon[ColOrgCodeName] = "MOB_TEST_GHOST"
	parent := monsterRow(91002, "MOB_TEST_GHOST")
	parent[ColModel] = "mob\\test\\ghost.bsr"
	orphan := monsterRow(91003, "MOB_TEST_ORPHAN_CLON")
	orphan[ColOrgCodeName] = "MOB_TEST_NOBODY"
	bare := monsterRow(91004, "MOB_TEST_BARE_CLON")
	bare[ColOrgCodeName] = "MOB_TEST_BARE"
	bareParent := monsterRow(91005, "MOB_TEST_BARE")
	self := monsterRow(91006, "MOB_TEST_SELF")
	self[ColModel] = "mob\\test\\self.bsr"
	self[ColOrgCodeName] = "MOB_TEST_GHOST" // an own model wins over any Org

	ex := NewExporter()
	for _, r := range [][]string{clon, orphan, bare, bareParent, self, parent} { // parent last
		ex.Add(r)
	}
	tab, st := exportCSV(t, ex, nil, nil)
	for _, c := range []struct {
		id         int64
		org        string
		orgID      int64
		model      string
		fromOrg    bool
		wantInStat string
	}{
		{91001, "MOB_TEST_GHOST", 91002, "mob\\test\\ghost.bsr", true, "org"},
		{91003, "MOB_TEST_NOBODY", 0, "", false, "none"},
		{91004, "MOB_TEST_BARE", 91005, "", false, "none"},
		{91005, "", 0, "", false, "none"},
		{91006, "MOB_TEST_GHOST", 91002, "mob\\test\\self.bsr", false, "own"},
		{91002, "", 0, "mob\\test\\ghost.bsr", false, "own"},
	} {
		r, ok := tab.ByID(c.id)
		if !ok {
			t.Fatalf("%d missing", c.id)
		}
		if r.OrgCodeName != c.org || r.OrgID != c.orgID || r.Model != c.model || r.ModelFromOrg != c.fromOrg {
			t.Errorf("%s: org %q/%d model %q fromOrg %v, want %q/%d %q %v",
				r.CodeName, r.OrgCodeName, r.OrgID, r.Model, r.ModelFromOrg, c.org, c.orgID, c.model, c.fromOrg)
		}
	}
	if st.OwnModel != 2 || st.OrgModel != 1 || st.NoModel != 3 || st.WithOrgRow != 3 || st.OrgUnmatched != 1 {
		t.Errorf("stats %+v", st)
	}
}

// TestMonstersOnlyAndLastPartWins: only TypeID (1,2,1,x) rows are written
// (but every row can be an Org); a repeated id keeps its LAST definition, a
// repeat that differs only in width (104 against 105 fields) is not a
// conflict, and the first-seen order stands.
func TestMonstersOnlyAndLastPartWins(t *testing.T) {
	ex := NewExporter()
	player := charRow(92001, "CHAR_TEST_MAN", "1", "1", "1", "1")
	npc := charRow(92002, "NPC_TEST_MERCHANT", "1", "2", "2", "1")
	old := monsterRow(92003, "MOB_TEST_TWICE")
	old[ColLevel] = "3"
	other := monsterRow(92004, "MOB_TEST_OTHER")
	newer := monsterRow(92003, "MOB_TEST_TWICE")
	newer[ColLevel] = "4"
	narrow := append([]string(nil), other[:104]...) // the same row, one field short
	for _, r := range [][]string{player, npc, old, other, newer, narrow, {"//", "comment"}} {
		ex.Add(r)
	}
	if ex.Rows != 6 || ex.Dupes != 2 || ex.Conflicts != 1 {
		t.Fatalf("rows %d dupes %d conflicts %d, want 6/2/1", ex.Rows, ex.Dupes, ex.Conflicts)
	}
	tab, st := exportCSV(t, ex, nil, nil)
	if tab.Len() != 2 || st.Monsters != 2 {
		t.Fatalf("%d species, want the two monsters", tab.Len())
	}
	if tab.Rows[0].ID != 92003 || tab.Rows[0].Level != 4 || tab.Rows[1].ID != 92004 {
		t.Errorf("rows %+v", tab.Rows)
	}
	if _, ok := tab.ByCode("mob_test_twice"); !ok {
		t.Error("ByCode is not case-insensitive")
	}
}

// TestObjectNamesFollowTheClientRule: service-1 rows only, the first row of a
// key wins, column 8 when it holds Latin text, else the first Latin field to
// its right, else from column 3; with none, column 8 as it stands.
func TestObjectNamesFollowTheClientRule(t *testing.T) {
	row := func(service, token string, fields map[int]string) []string {
		cols := make([]string, 12)
		for i := range cols {
			cols[i] = "0"
		}
		cols[0], cols[1] = service, token
		for i, v := range fields {
			cols[i] = v
		}
		return cols
	}
	names := ParseObjectNames([][]string{
		row("1", "SN_A", map[int]string{2: "한국어", 8: "Alpha"}),
		row("1", "SN_A", map[int]string{8: "Second"}),
		row("0", "SN_B", map[int]string{8: "Off"}),
		row("1", "SN_C", map[int]string{8: "0", 9: "Gamma"}),
		row("1", "SN_D", map[int]string{4: "Delta"}),
		row("1", "SN_E", nil),
	})
	for k, want := range map[string]string{"SN_A": "Alpha", "SN_C": "Gamma", "SN_D": "Delta", "SN_E": "0"} {
		if got, ok := names[k]; !ok || got != want {
			t.Errorf("%s = %q (%v), want %q", k, got, ok, want)
		}
	}
	if _, ok := names["SN_B"]; ok {
		t.Error("a service-0 row was loaded")
	}
	// DisplayName never shows "0": the code name stands in (OURS).
	if n := (Row{CodeName: "MOB_TEST_E", Name: "0"}).DisplayName(); n != "MOB_TEST_E" {
		t.Errorf("DisplayName = %q", n)
	}
}

func TestLevelGoldJoin(t *testing.T) {
	g := ParseLevelGold([][]string{{"1", "28", "59"}, {"2", "32", "66"}, {"x", "1", "2"}, {"3"}})
	if len(g) != 2 || g[1] != [2]int64{28, 59} || g[2] != [2]int64{32, 66} {
		t.Fatalf("levelgold %v", g)
	}
	ex := NewExporter()
	a := monsterRow(93001, "MOB_TEST_L2")
	a[ColLevel] = "2"
	b := monsterRow(93002, "MOB_TEST_L9")
	b[ColLevel] = "9"
	ex.Add(a)
	ex.Add(b)
	tab, st := exportCSV(t, ex, g, nil)
	if r, _ := tab.ByID(93001); r.GoldMin != 32 || r.GoldMax != 66 {
		t.Errorf("level 2 gold %d-%d", r.GoldMin, r.GoldMax)
	}
	if r, _ := tab.ByID(93002); r.GoldMin != 0 || r.GoldMax != 0 {
		t.Errorf("a level with no levelgold row got gold %d-%d", r.GoldMin, r.GoldMax)
	}
	if st.Gold != 1 {
		t.Errorf("stats gold %d", st.Gold)
	}
}

// TestReadTakesALongerCSV: the header check is a strict PREFIX, so a CSV a
// later round extends with a trailing column still loads, its known columns
// read as before -- while a short header, a renamed column or a row that
// disagrees with its header's width is still refused.
func TestReadTakesALongerCSV(t *testing.T) {
	ex := NewExporter()
	cols := monsterRow(94001, "MOB_TEST_LATER")
	cols[ColLevel] = "12"
	ex.Add(cols)
	recs, _ := ex.Records(nil, nil)
	var b strings.Builder
	w := csv.NewWriter(&b)
	w.Write(append(append([]string{}, CSVColumns...), "SomeLaterColumn"))
	w.Write(append(recs[0], "42"))
	w.Flush()
	tab, err := Read(strings.NewReader(b.String()))
	if err != nil {
		t.Fatalf("a CSV with an extra trailing column: %v", err)
	}
	if r, ok := tab.ByID(94001); !ok || r.Level != 12 || r.CodeName != "MOB_TEST_LATER" {
		t.Fatalf("row %+v (%v)", r, ok)
	}
	short := strings.Join(append(append([]string{}, CSVColumns...), "SomeLaterColumn"), ",") + "\n" + strings.Join(recs[0], ",") + "\n"
	if _, err := Read(strings.NewReader(short)); err == nil {
		t.Error("accepted a row narrower than its header")
	}
	// Round 654 wrote 35 columns and requires them all; a later round
	// appends to CSVColumns and leaves this at 35.
	if RequiredCSVColumns != 35 || len(CSVColumns) < RequiredCSVColumns {
		t.Fatalf("RequiredCSVColumns %d, CSVColumns %d", RequiredCSVColumns, len(CSVColumns))
	}
}

func TestReadRejectsAnotherCSV(t *testing.T) {
	for _, in := range []string{
		"ObjectID,RegionID,LocalX,LocalY,LocalZ\n1,2,3,4,5\n",
		strings.Join(CSVColumns[:len(CSVColumns)-1], ",") + "\n",
		strings.Join(CSVColumns, ",") + "\n" + strings.Repeat("1,", len(CSVColumns)-2) + "1\n",
		strings.Join(CSVColumns, ",") + "\nx" + strings.Repeat(",1", len(CSVColumns)-1) + "\n",
	} {
		if _, err := Read(strings.NewReader(in)); err == nil {
			t.Errorf("accepted %q", in)
		}
	}
}

// TestAttacks: the list is the resolved ids in column order, the col-83 skill
// is the primary, and the list is WholeList only when every id resolves with a
// known AI_AttackChance.
func TestAttacks(t *testing.T) {
	sk := map[int64]SkillRow{
		160: {ReuseMs: 3000, Range: 10, AttMin: 17, AttMax: 19, Chance: 100, ChanceKnown: true},
		169: {ReuseMs: 4000, Range: 16, Chance: 10, ChanceKnown: true},
		500: {ReuseMs: 1000, Range: 5, AttMin: 1, AttMax: 2, Chance: -1},
	}
	lookup := func(id int64) (SkillRow, bool) { s, ok := sk[id]; return s, ok }
	r := Row{Skills: [NumSkills]int64{160, 169}}
	a := r.Attacks(lookup)
	if !a.WholeList || !a.HasPrimary || len(a.Skills) != 2 || a.Primary.ID != 160 || a.Skills[1].Chance != 10 || a.Primary.AttMax != 19 {
		t.Fatalf("complete list: %+v", a)
	}
	a = (Row{Skills: [NumSkills]int64{160, 0, 777}}).Attacks(lookup)
	if a.WholeList || len(a.Skills) != 1 || len(a.Unresolved) != 1 || a.Unresolved[0] != 777 {
		t.Fatalf("unresolved id: %+v", a)
	}
	a = (Row{Skills: [NumSkills]int64{500}}).Attacks(lookup)
	if a.WholeList || !a.HasPrimary {
		t.Fatalf("unknown chance: %+v", a)
	}
	a = (Row{Skills: [NumSkills]int64{0, 160}}).Attacks(lookup)
	if a.HasPrimary || len(a.Skills) != 1 {
		t.Fatalf("no col-83 skill: %+v", a)
	}
	if a = (Row{}).Attacks(nil); !a.WholeList || a.HasPrimary || len(a.Skills) != 0 {
		t.Fatalf("no skills: %+v", a)
	}
}
