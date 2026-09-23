package refdata

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// fillStruct gives every field of a struct a distinct, non-zero value, so that
// a field dropped anywhere in the round trip comes back as the zero value and
// is visibly different from what went in.
//
// Distinct matters as much as non-zero: if every int were 1, two fields swapped
// in a column list would still compare equal.
func fillStruct(t *testing.T, v reflect.Value, seed *int) {
	t.Helper()
	for i := 0; i < v.NumField(); i++ {
		f := v.Field(i)
		if !f.CanSet() {
			continue
		}
		*seed++
		switch f.Kind() {
		case reflect.Int, reflect.Int32, reflect.Int64:
			f.SetInt(int64(*seed))
		case reflect.Float64, reflect.Float32:
			// Fractional, so a column typed INTEGER instead of DOUBLE
			// PRECISION truncates and fails rather than passing by luck.
			f.SetFloat(float64(*seed) + 0.5)
		case reflect.String:
			f.SetString("v" + strings.Repeat("x", *seed%3) + string(rune('a'+*seed%26)))
		case reflect.Bool:
			f.SetBool(true)
		}
	}
}

// diffFields reports which exported fields differ between two structs.
func diffFields(t *testing.T, want, got reflect.Value) []string {
	t.Helper()
	var bad []string
	for i := 0; i < want.NumField(); i++ {
		name := want.Type().Field(i).Name
		w, g := want.Field(i).Interface(), got.Field(i).Interface()
		if !reflect.DeepEqual(w, g) {
			bad = append(bad, name+": stored "+fmtAny(w)+", read back "+fmtAny(g))
		}
	}
	return bad
}

func fmtAny(v any) string {
	return strings.TrimSpace(reflect.ValueOf(v).String() + " " + fmtNum(v))
}

func fmtNum(v any) string {
	switch x := v.(type) {
	case int:
		return itoa(int64(x))
	case int32:
		return itoa(int64(x))
	case int64:
		return itoa(x)
	case float64:
		return ftoa(x)
	case bool:
		if x {
			return "true"
		}
		return "false"
	}
	return ""
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b []byte
	for v > 0 {
		b = append([]byte{byte('0' + v%10)}, b...)
		v /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}

func ftoa(f float64) string {
	whole := int64(f)
	frac := int64((f - float64(whole)) * 10)
	if frac < 0 {
		frac = -frac
	}
	return itoa(whole) + "." + itoa(frac)
}

// TestEveryItemFieldSurvivesSQL walks EVERY field of refdata.Item through
// import and read-back.
//
// This exists because a whole class of defect shipped silently: a value is
// recovered, exported, and parsed out of the CSV, but the SQL store has no
// column for it, so ImportItems drops it and GetItem returns a zero. Nothing
// errors. That is how a skill's real damage was lost on every SQL deployment
// until 2026-09-15, and it was found only by accident while editing nearby
// code. A field-by-field round trip finds all of them at once, and keeps
// finding them as fields are added.
func TestEveryItemFieldSurvivesSQL(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	var want Item
	seed := 0
	fillStruct(t, reflect.ValueOf(&want).Elem(), &seed)
	want.ID = 987654

	if err := s.ImportItems(ctx, []Item{want}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	got, err := s.GetItem(ctx, want.ID)
	if err != nil || got == nil {
		t.Fatalf("GetItem: %v", err)
	}
	if bad := diffFields(t, reflect.ValueOf(want), reflect.ValueOf(*got)); len(bad) > 0 {
		t.Errorf("%d of %d Item fields did not survive the SQL round trip:\n  %s",
			len(bad), reflect.TypeOf(want).NumField(), strings.Join(bad, "\n  "))
	}
}

// TestCanUseFalseSurvivesSQL covers the case the audit above cannot: fillStruct
// sets every bool TRUE, and can_use defaults TRUE in the schema, so a CanUse
// dropped from the INSERT or the SELECT would still pass it. A clear CanUse
// (round 489) is the value that forbids a use, so it is the one that has to
// arrive -- through GetItem, which useitem reads, and ListAll, which the shop
// catalog reads.
func TestCanUseFalseSurvivesSQL(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	const id = 987656
	if err := s.ImportItems(ctx, []Item{{ID: id, MaxStack: 1, CanUse: false}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	got, err := s.GetItem(ctx, id)
	if err != nil || got == nil {
		t.Fatalf("GetItem: %v", err)
	}
	if got.CanUse {
		t.Error("GetItem read CanUse back as true; a clear bit was lost on the way through SQL")
	}
	all, err := s.ListAll(ctx)
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	found := false
	for _, it := range all {
		if it.ID != id {
			continue
		}
		found = true
		if it.CanUse {
			t.Error("ListAll read CanUse back as true; a clear bit was lost on the way through SQL")
		}
	}
	if !found {
		t.Fatalf("ListAll did not return item %d", id)
	}
}

// TestCanPickFalseSurvivesSQL is TestCanUseFalseSurvivesSQL's twin for
// CanPick (round 493): can_pick defaults TRUE, so only a clear bit proves the
// column is really written and read -- through GetItem, which the ground
// hub's pick lookup reads, and ListAll.
func TestCanPickFalseSurvivesSQL(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	const id = 987657
	if err := s.ImportItems(ctx, []Item{{ID: id, MaxStack: 1, CanUse: true, CanPick: false}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	got, err := s.GetItem(ctx, id)
	if err != nil || got == nil {
		t.Fatalf("GetItem: %v", err)
	}
	if got.CanPick {
		t.Error("GetItem read CanPick back as true; a clear bit was lost on the way through SQL")
	}
	if !got.CanUse {
		t.Error("GetItem read CanUse back as false; the neighbouring column was shifted")
	}
	all, err := s.ListAll(ctx)
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	found := false
	for _, it := range all {
		if it.ID != id {
			continue
		}
		found = true
		if it.CanPick {
			t.Error("ListAll read CanPick back as true; a clear bit was lost on the way through SQL")
		}
	}
	if !found {
		t.Fatalf("ListAll did not return item %d", id)
	}
}

// TestEverySkillFieldSurvivesSQL is the same audit for refdata.Skill.
func TestEverySkillFieldSurvivesSQL(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	var want Skill
	seed := 0
	fillStruct(t, reflect.ValueOf(&want).Elem(), &seed)
	want.ID = 987655

	if err := s.ImportSkills(ctx, []Skill{want}); err != nil {
		t.Fatalf("ImportSkills: %v", err)
	}
	got, err := s.GetSkill(ctx, want.ID)
	if err != nil || got == nil {
		t.Fatalf("GetSkill: %v", err)
	}
	if bad := diffFields(t, reflect.ValueOf(want), reflect.ValueOf(*got)); len(bad) > 0 {
		t.Errorf("%d of %d Skill fields did not survive the SQL round trip:\n  %s",
			len(bad), reflect.TypeOf(want).NumField(), strings.Join(bad, "\n  "))
	}
}

// TestCSVColumnsCoverEveryField guards the other half of the same class of
// defect. The SQL round trip above catches a field with no column in the
// database; this catches one with no column in the CSV, which would be dropped
// a step earlier -- between the exporter and the importer -- and just as
// silently.
//
// Every field of Item and Skill currently has exactly one CSV column, and the
// parsers index the slice positionally, so the counts must agree. If a field is
// ever deliberately derived rather than exported, this test is the right place
// to record that: exclude it by name here, with the reason, rather than
// loosening the comparison.
func TestCSVColumnsCoverEveryField(t *testing.T) {
	for _, tc := range []struct {
		name    string
		fields  int
		columns int
	}{
		{"Item", reflect.TypeOf(Item{}).NumField(), len(itemCSVColumns)},
		{"Skill", reflect.TypeOf(Skill{}).NumField(), len(skillCSVColumns)},
	} {
		if tc.fields != tc.columns {
			t.Errorf("%s has %d fields but %d CSV columns; a field with no column is "+
				"dropped between the exporter and the importer without erroring",
				tc.name, tc.fields, tc.columns)
		}
	}
}

// TestEveryDropFieldSurvivesSQL completes the sweep over refdata's stored
// types. MonsterDrop and DropGroupEntry go through the same import/read-back
// path as Item and Skill, so they can lose a field the same way.
//
// DropRatio and SelectRatio are float64 and the audit fills floats with a
// fractional value, so a column typed INTEGER rather than DOUBLE PRECISION
// fails here rather than silently rounding every drop rate.
func TestEveryDropFieldSurvivesSQL(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	var drop MonsterDrop
	seed := 0
	fillStruct(t, reflect.ValueOf(&drop).Elem(), &seed)
	drop.MonsterID = 987656
	if err := s.ImportMonsterDrops(ctx, []MonsterDrop{drop}); err != nil {
		t.Fatalf("ImportMonsterDrops: %v", err)
	}
	gotDrops, err := s.GetMonsterDrops(ctx, drop.MonsterID)
	if err != nil {
		t.Fatalf("GetMonsterDrops: %v", err)
	}
	if len(gotDrops) != 1 {
		t.Fatalf("GetMonsterDrops returned %d rows, want 1", len(gotDrops))
	}
	if bad := diffFields(t, reflect.ValueOf(drop), reflect.ValueOf(*gotDrops[0])); len(bad) > 0 {
		t.Errorf("%d of %d MonsterDrop fields did not survive:\n  %s",
			len(bad), reflect.TypeOf(drop).NumField(), strings.Join(bad, "\n  "))
	}

	var entry DropGroupEntry
	seed = 0
	fillStruct(t, reflect.ValueOf(&entry).Elem(), &seed)
	entry.GroupID = 987657
	if err := s.ImportDropGroupEntries(ctx, []DropGroupEntry{entry}); err != nil {
		t.Fatalf("ImportDropGroupEntries: %v", err)
	}
	gotEntries, err := s.GetDropGroupEntries(ctx, entry.GroupID)
	if err != nil {
		t.Fatalf("GetDropGroupEntries: %v", err)
	}
	if len(gotEntries) != 1 {
		t.Fatalf("GetDropGroupEntries returned %d rows, want 1", len(gotEntries))
	}
	if bad := diffFields(t, reflect.ValueOf(entry), reflect.ValueOf(*gotEntries[0])); len(bad) > 0 {
		t.Errorf("%d of %d DropGroupEntry fields did not survive:\n  %s",
			len(bad), reflect.TypeOf(entry).NumField(), strings.Join(bad, "\n  "))
	}
}

// TestDropCSVReachesTheStore walks the whole drop path the way an operator
// does: CSV text -> loader -> SQL store -> read back.
//
// It exists because the path was BUILT but not REACHABLE. refdata had
// LoadMonsterDropsCSV and LoadDropGroupEntriesCSV, and the SQL store had
// ImportMonsterDrops and ImportDropGroupEntries, since the schemas were
// curated -- but cmd/import-refdata exposed no flag for either, so an operator
// holding the real _RefMonster_AssignedItemRndDrop and _RefDropItemGroup tables
// had no way to load them. Every piece passed its own test; the chain had a
// missing link in the one place nothing tested.
//
// Same lesson as the SQL column drops: a capability is not shipped until
// something exercises it end to end.
func TestDropCSVReachesTheStore(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	// MOB_CH_MANGNYANG is RefObjChar 1933 -- characterdata col 1 is the id and
	// col 2 the code name, which is the mapping the loot system was missing.
	const mangyang = 1933
	drops, err := LoadMonsterDropsCSV(strings.NewReader("1933,700,1,1,2,0.25\n"))
	if err != nil {
		t.Fatalf("LoadMonsterDropsCSV: %v", err)
	}
	if err := s.ImportMonsterDrops(ctx, drops); err != nil {
		t.Fatalf("ImportMonsterDrops: %v", err)
	}
	got, err := s.GetMonsterDrops(ctx, mangyang)
	if err != nil || len(got) != 1 {
		t.Fatalf("GetMonsterDrops(%d) = %v, %v; want one row", mangyang, got, err)
	}
	if got[0].ItemGroupID != 700 || got[0].DropAmountMax != 2 || got[0].DropRatio != 0.25 {
		t.Errorf("drop round trip: got group %d, max %d, ratio %v; want 700, 2, 0.25",
			got[0].ItemGroupID, got[0].DropAmountMax, got[0].DropRatio)
	}

	entries, err := LoadDropGroupEntriesCSV(strings.NewReader("700,ITEM_ETC_HP_POTION_01,3629,0.5\n"))
	if err != nil {
		t.Fatalf("LoadDropGroupEntriesCSV: %v", err)
	}
	if err := s.ImportDropGroupEntries(ctx, entries); err != nil {
		t.Fatalf("ImportDropGroupEntries: %v", err)
	}
	gotEntries, err := s.GetDropGroupEntries(ctx, 700)
	if err != nil || len(gotEntries) != 1 {
		t.Fatalf("GetDropGroupEntries(700) = %v, %v; want one row", gotEntries, err)
	}
	if gotEntries[0].ItemID != 3629 || gotEntries[0].SelectRatio != 0.5 {
		t.Errorf("group round trip: got item %d ratio %v; want 3629, 0.5",
			gotEntries[0].ItemID, gotEntries[0].SelectRatio)
	}
}
