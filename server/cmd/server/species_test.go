package main

import (
	"context"
	"encoding/csv"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/species"
)

// rosterAsTables writes the hand-typed roster back out as SYNTHETIC client
// tables -- a characterdata line, a textdata_object line and a levelgold line
// per species, each value put in the column the roster's comments say it was
// read from -- plus a skill lookup holding the roster's skill numbers. No game
// data: every number is one monsterSpecs already carries. A _CLON species gets
// "xxx" for its own model and its parent's code as Org, so the Org columns are
// exercised too.
func rosterAsTables(specs []monsterSpec) (chars, names, gold [][]string, lookup species.SkillLookup) {
	skills := map[int64]species.SkillRow{}
	levels := map[int][2]int64{}
	for _, s := range specs {
		cols := make([]string, 105)
		for i := range cols {
			cols[i] = "0"
		}
		cols[104] = ""
		for _, c := range []int{3, species.ColOrgCodeName, 6, species.ColModel, 53, 54, 55, 56} {
			cols[c] = "xxx"
		}
		cols[0] = "1"
		cols[species.ColID] = strconv.FormatInt(s.RefObjID, 10)
		cols[species.ColCodeName] = s.CodeName
		cols[species.ColNameKey] = "SN_" + s.CodeName
		cols[species.ColTypeID1], cols[species.ColTypeID2], cols[species.ColTypeID3], cols[species.ColTypeID4] = "1", "2", "1", "1"
		cols[species.ColRarity] = strconv.Itoa(s.Rarity)
		cols[species.ColWalkSpeed] = strconv.FormatFloat(s.WalkSpeed, 'g', -1, 64)
		cols[species.ColRunSpeed] = strconv.FormatFloat(s.RunSpeed, 'g', -1, 64)
		cols[species.ColBCRadius] = strconv.Itoa(s.BCRadius)
		if parent, isClon := strings.CutSuffix(s.CodeName, "_CLON"); isClon {
			cols[species.ColOrgCodeName] = parent
		} else {
			cols[species.ColModel] = "mob\\synthetic\\" + strings.ToLower(s.CodeName) + ".bsr"
		}
		cols[species.ColLevel] = strconv.Itoa(s.Level)
		cols[species.ColMaxHP] = strconv.Itoa(s.MaxHP)
		cols[species.ColParams+0] = strconv.Itoa(s.Defense)
		cols[species.ColParams+2] = strconv.Itoa(s.Level)
		cols[species.ColParams+3] = strconv.Itoa(s.Level)
		cols[species.ColParams+5] = strconv.Itoa(s.Block)
		cols[species.ColParams+7] = strconv.Itoa(s.Critical)
		for i, sk := range s.Skills {
			cols[species.ColSkills+i] = strconv.FormatInt(sk.ID, 10)
			skills[sk.ID] = species.SkillRow{ReuseMs: sk.ReuseMs, Range: sk.Range, AttMin: sk.AttMin, AttMax: sk.AttMax, Chance: sk.Chance, ChanceKnown: true}
		}
		chars = append(chars, cols)
		name := make([]string, 12)
		for i := range name {
			name[i] = "0"
		}
		name[0], name[1], name[8] = "1", "SN_"+s.CodeName, s.Name
		names = append(names, name)
		levels[s.Level] = [2]int64{s.GoldMin, s.GoldMax}
	}
	for lvl, g := range levels {
		gold = append(gold, []string{strconv.Itoa(lvl), strconv.FormatInt(g[0], 10), strconv.FormatInt(g[1], 10)})
	}
	lookup = func(id int64) (species.SkillRow, bool) { s, ok := skills[id]; return s, ok }
	return
}

// exportAndLoad runs the export half and the load half of internal/species
// over tables, through the CSV text between them.
func exportAndLoad(t *testing.T, chars, names, gold [][]string) *species.Table {
	t.Helper()
	ex := species.NewExporter()
	for _, c := range chars {
		ex.Add(c)
	}
	recs, _ := ex.Records(species.ParseLevelGold(gold), species.ParseObjectNames(names))
	var b strings.Builder
	w := csv.NewWriter(&b)
	w.Write(species.CSVColumns)
	w.WriteAll(recs)
	tab, err := species.Read(strings.NewReader(b.String()))
	if err != nil {
		t.Fatalf("species.Read: %v", err)
	}
	return tab
}

// TestSpeciesTableRederivesTheRoster: the roster's eleven species, written out
// as client tables and taken back through the export, the CSV and the loader,
// come back EXACTLY as monsterSpecs has them -- every species number, and the
// zone, anchor and placements untouched. The negative half: one wrong column
// (Mangyang's MaxHP) is reported as a change, so the comparison can fail.
func TestSpeciesTableRederivesTheRoster(t *testing.T) {
	chars, names, gold, lookup := rosterAsTables(monsterSpecs)
	tab := exportAndLoad(t, chars, names, gold)
	if tab.Len() != len(monsterSpecs) {
		t.Fatalf("table has %d species, the roster %d", tab.Len(), len(monsterSpecs))
	}
	specs := append([]monsterSpec(nil), monsterSpecs...)
	ov := overlaySpeciesTable(specs, tab, lookup)
	if ov.Overlaid != len(monsterSpecs) || len(ov.Missing) != 0 || len(ov.Changed) != 0 || len(ov.Kept) != 0 {
		t.Fatalf("overlay %d, missing %v, changed %v, kept %v", ov.Overlaid, ov.Missing, ov.Changed, ov.Kept)
	}
	for i := range specs {
		if !reflect.DeepEqual(specs[i], monsterSpecs[i]) {
			t.Errorf("%s re-derived as\n  %+v\nwant\n  %+v", monsterSpecs[i].Name, specs[i], monsterSpecs[i])
		}
	}
	// Each _CLON whose parent is on the roster took its model from that Org
	// row (a field only, this round); MOB_CH_TOMBSTONE_CLON's parent is not,
	// so it has none.
	fromOrg := 0
	for _, r := range tab.Rows {
		parent, isClon := strings.CutSuffix(r.CodeName, "_CLON")
		_, parentHere := tab.ByCode(parent)
		want := isClon && parentHere
		if hasModel, wantModel := r.Model != "", !isClon || want; r.ModelFromOrg != want || hasModel != wantModel {
			t.Errorf("%s: ModelFromOrg %v, model %q", r.CodeName, r.ModelFromOrg, r.Model)
		}
		if r.ModelFromOrg {
			fromOrg++
		}
	}
	if fromOrg != 3 {
		t.Errorf("%d models from the Org row, want 3 (the Big-eyed Ghost's, Weasel's and Water Ghost's slaves)", fromOrg)
	}

	chars[0][species.ColMaxHP] = strconv.Itoa(monsterSpecs[0].MaxHP + 1)
	specs = append([]monsterSpec(nil), monsterSpecs...)
	ov = overlaySpeciesTable(specs, exportAndLoad(t, chars, names, gold), lookup)
	if len(ov.Changed) != 1 || !strings.HasPrefix(ov.Changed[0], monsterSpecs[0].Name+":") || specs[0].MaxHP != monsterSpecs[0].MaxHP+1 {
		t.Fatalf("a wrong MaxHP column was not reported: %v", ov.Changed)
	}
}

// TestSpeciesTableKeepsWhatItCannotSupply: an export without textdata_object
// and levelgold, and a skill store from before round 654 (every
// AI_AttackChance unknown), leaves a roster species its hand-typed name, gold
// and attack list -- the table's own numbers still apply -- and says so.
func TestSpeciesTableKeepsWhatItCannotSupply(t *testing.T) {
	chars, _, _, lookup := rosterAsTables(monsterSpecs)
	stale := func(id int64) (species.SkillRow, bool) {
		s, ok := lookup(id)
		s.Chance, s.ChanceKnown = -1, false
		return s, ok
	}
	tab := exportAndLoad(t, chars, nil, nil)
	specs := append([]monsterSpec(nil), monsterSpecs...)
	ov := overlaySpeciesTable(specs, tab, stale)
	if len(ov.Changed) != 0 || len(ov.Kept) != len(monsterSpecs) {
		t.Fatalf("changed %v kept %v", ov.Changed, ov.Kept)
	}
	if !strings.HasSuffix(ov.Kept[0], ": name,gold,attacks") {
		t.Errorf("kept %q", ov.Kept[0])
	}
	if !reflect.DeepEqual(specs, monsterSpecs) {
		t.Error("a kept field changed")
	}
}

// TestGMSpawnsAnyTableSpecies: the GM console finds a species the roster does
// not hold by id, code name or display name, with the table's level, HP and
// rarity; it is Unplaced, so /goto refuses it and /spawn puts it down.
func TestGMSpawnsAnyTableSpecies(t *testing.T) {
	chars, names, gold, lookup := rosterAsTables(append(append([]monsterSpec(nil), monsterSpecs...), monsterSpec{
		Name: "Test Giant", CodeName: "MOB_TEST_GIANT", RefObjID: 99001, Level: 12, Rarity: 4, MaxHP: 300,
		Defense: 30, Block: 20, Critical: 2, BCRadius: 9, WalkSpeed: 10, RunSpeed: 40, GoldMin: 70, GoldMax: 140,
		Skills: []combat.MonsterSkill{{ID: 99100, ReuseMs: 2000, Range: 12, AttMin: 50, AttMax: 60, Chance: 100}},
	}))
	tab := exportAndLoad(t, chars, names, gold)
	find := gmSpeciesLookup(tab, lookup)
	for _, want := range []string{"99001", "mob_test_giant", "test giant"} {
		sp, ok := find(want)
		if !ok {
			t.Fatalf("%q not found", want)
		}
		if !sp.Unplaced || sp.RefObjID != 99001 || sp.Level != 12 || sp.Rarity != 4 || sp.MaxHP != 300 || sp.Block != 0 ||
			sp.AttackMax != 60 || len(sp.Skills) != 1 || sp.GoldMax != 140 || sp.Name != "Test Giant" {
			t.Fatalf("%q -> %+v", want, sp)
		}
	}
	if row, ok := tab.ByID(99001); !ok || row.Block() != 20 {
		t.Fatalf("col 76 not carried: %+v", row)
	} else if spec, _ := specFromRow(monsterSpec{}, row, lookup); spec.Block != 20 {
		t.Fatalf("spec Block %d, want col 76's 20", spec.Block)
	}
	if _, ok := find("mob_nobody"); ok {
		t.Fatal("found a species the table does not hold")
	}

	hub := combat.NewHub()
	d := &gm.Deps{Monsters: hub, Species: gmSpecies(), LookupSpecies: find, LookupCount: tab.Len()}
	actor := gm.Actor{Zone: "jangan", X: 10, Z: 20}
	res := d.Run(context.Background(), actor, "/spawn 99001 2")
	if res.Refused || len(res.SpawnedMonsterIDs) != 2 {
		t.Fatalf("/spawn 99001 2: %+v", res)
	}
	m, _ := hub.Get(res.SpawnedMonsterIDs[0])
	// Block stays 0 on the spawned monster: col 76 is carried (the spec's
	// Block, checked below) but not handed to combat until the TODO's blocked
	// skill-percentage item is fixed.
	if m.RefObjID != 99001 || m.Level != 12 || m.Rarity != 4 || m.Block != 0 || m.MaxHP != 300*combat.RarityHPPercent(4)/100 {
		t.Errorf("spawned %+v", m)
	}
	if res := d.Run(context.Background(), actor, "/goto mob_test_giant"); !res.Refused || !strings.Contains(res.Text, "not placed") {
		t.Errorf("/goto an unplaced species: %+v", res)
	}
	// A roster species is still found first, placed, by its id too.
	if res := d.Run(context.Background(), actor, "/spawn 1933"); res.Refused {
		t.Errorf("/spawn 1933 (Mangyang, the roster's): %+v", res)
	}
}

// TestSpeciesTableMatchesTheRealExport is the MEASUREMENT behind the claim that
// the loader re-derives the roster: point SRREVAMP_MONSTERS_CSV and
// SRREVAMP_SKILLS_CSV at CSVs exported from a real Media.pk2 (deploy/README.md)
// and every roster species must come back with no change and nothing kept.
// Skipped without them -- no game data is committed, so CI cannot run it.
func TestSpeciesTableMatchesTheRealExport(t *testing.T) {
	mpath, spath := os.Getenv("SRREVAMP_MONSTERS_CSV"), os.Getenv("SRREVAMP_SKILLS_CSV")
	if mpath == "" || spath == "" {
		t.Skip("SRREVAMP_MONSTERS_CSV and SRREVAMP_SKILLS_CSV name no real export")
	}
	tab, err := species.LoadCSV(mpath)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(spath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sk, err := refdata.LoadSkillsCSV(f)
	if err != nil {
		t.Fatal(err)
	}
	byID := map[int64]*refdata.Skill{}
	for i := range sk {
		byID[sk[i].ID] = &sk[i]
	}
	lookup := species.RefdataLookup(func(id int64) (*refdata.Skill, error) {
		if s, ok := byID[id]; ok {
			return s, nil
		}
		return nil, os.ErrNotExist
	})
	specs := append([]monsterSpec(nil), monsterSpecs...)
	ov := overlaySpeciesTable(specs, tab, lookup)
	t.Logf("real export: %d species, %d skills; roster overlaid %d, missing %d, changed %d, kept %d",
		tab.Len(), len(sk), ov.Overlaid, len(ov.Missing), len(ov.Changed), len(ov.Kept))
	for _, c := range ov.Changed {
		t.Errorf("changed: %s", c)
	}
	for _, k := range ov.Kept {
		t.Errorf("kept: %s", k)
	}
	if len(ov.Missing) != 0 {
		t.Errorf("missing: %v", ov.Missing)
	}
}
