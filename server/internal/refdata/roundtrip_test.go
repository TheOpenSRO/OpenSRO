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
