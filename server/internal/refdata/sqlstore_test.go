package refdata

import (
	"context"
	"os"
	"reflect"
	"strings"
	"testing"
)

// testDSN points at a local PostgreSQL instance for tests. Override with
// OPENSRO_TEST_POSTGRES_DSN if your dev setup differs (e.g. CI).
func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running? see testDSN)", err)
	}
	if _, err := s.db.Exec(`TRUNCATE TABLE items`); err != nil {
		t.Fatalf("truncating items table: %v", err)
	}
	if _, err := s.db.Exec(`TRUNCATE TABLE skills`); err != nil {
		t.Fatalf("truncating skills table: %v", err)
	}
	if _, err := s.db.Exec(`TRUNCATE TABLE monster_drops`); err != nil {
		t.Fatalf("truncating monster_drops table: %v", err)
	}
	if _, err := s.db.Exec(`TRUNCATE TABLE drop_group_entries`); err != nil {
		t.Fatalf("truncating drop_group_entries table: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestImportAndGetItem(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3,3,1,6,2,0,1,1,1\n"
	items, err := LoadItemsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadItemsCSV: %v", err)
	}
	if err := store.ImportItems(ctx, items); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}

	got, err := store.GetItem(ctx, 1)
	if err != nil {
		t.Fatalf("GetItem: %v", err)
	}
	if *got != items[0] {
		t.Fatalf("got %+v, want %+v", got, items[0])
	}

	count, err := store.Count(ctx)
	if err != nil {
		t.Fatalf("Count: %v", err)
	}
	if count != 1 {
		t.Fatalf("got count %d, want 1", count)
	}
}

func TestListAll(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3,3,1,6,2,0,1,1,1\n" +
		"2,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3,3,1,6,2,0,1,1,1\n"
	items, err := LoadItemsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadItemsCSV: %v", err)
	}
	if err := store.ImportItems(ctx, items); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}

	got, err := store.ListAll(ctx)
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	if len(got) != 2 || got[0].ID != 1 || got[1].ID != 2 {
		t.Fatalf("got %+v, want items 1 and 2 in ID order", got)
	}
}

func TestImportItemsUpserts(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	first := Item{ID: 1, MaxStack: 100}
	if err := store.ImportItems(ctx, []Item{first}); err != nil {
		t.Fatalf("first ImportItems: %v", err)
	}

	updated := Item{ID: 1, MaxStack: 200}
	if err := store.ImportItems(ctx, []Item{updated}); err != nil {
		t.Fatalf("second ImportItems: %v", err)
	}

	got, err := store.GetItem(ctx, 1)
	if err != nil {
		t.Fatalf("GetItem: %v", err)
	}
	if got.MaxStack != 200 {
		t.Fatalf("got MaxStack %d, want 200 (upsert should have replaced the row)", got.MaxStack)
	}

	count, err := store.Count(ctx)
	if err != nil {
		t.Fatalf("Count: %v", err)
	}
	if count != 1 {
		t.Fatalf("got count %d, want 1 (upsert should not duplicate)", count)
	}
}

func TestGetItemNotFound(t *testing.T) {
	store := openTestSQLStore(t)
	if _, err := store.GetItem(context.Background(), 999); err == nil {
		t.Fatal("expected an error looking up a nonexistent item, got nil")
	}
}

func TestImportAndGetSkill(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	csv := "1,10,SKILL_CH_SWORD_ATTACK_01,SN_SWORD_ATTACK_01,1,0,5,500,300,1000,3000,3000,0.0,1,0,1,10,0,20,100,0,Sword Slash,257,5\n"
	skills, err := LoadSkillsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadSkillsCSV: %v", err)
	}
	if err := store.ImportSkills(ctx, skills); err != nil {
		t.Fatalf("ImportSkills: %v", err)
	}

	got, err := store.GetSkill(ctx, 1)
	if err != nil {
		t.Fatalf("GetSkill: %v", err)
	}
	if !reflect.DeepEqual(*got, skills[0]) {
		t.Fatalf("got %+v, want %+v", got, skills[0])
	}

	count, err := store.CountSkills(ctx)
	if err != nil {
		t.Fatalf("CountSkills: %v", err)
	}
	if count != 1 {
		t.Fatalf("got count %d, want 1", count)
	}

	all, err := store.ListAllSkills(ctx)
	if err != nil {
		t.Fatalf("ListAllSkills: %v", err)
	}
	if len(all) != 1 || !reflect.DeepEqual(*all[0], skills[0]) {
		t.Fatalf("got %+v, want one skill matching %+v", all, skills[0])
	}
}

func TestImportSkillsUpserts(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	first := Skill{ID: 1, BasicLevel: 1}
	if err := store.ImportSkills(ctx, []Skill{first}); err != nil {
		t.Fatalf("first ImportSkills: %v", err)
	}

	updated := Skill{ID: 1, BasicLevel: 5}
	if err := store.ImportSkills(ctx, []Skill{updated}); err != nil {
		t.Fatalf("second ImportSkills: %v", err)
	}

	got, err := store.GetSkill(ctx, 1)
	if err != nil {
		t.Fatalf("GetSkill: %v", err)
	}
	if got.BasicLevel != 5 {
		t.Fatalf("got BasicLevel %d, want 5 (upsert should have replaced the row)", got.BasicLevel)
	}

	count, err := store.CountSkills(ctx)
	if err != nil {
		t.Fatalf("CountSkills: %v", err)
	}
	if count != 1 {
		t.Fatalf("got count %d, want 1 (upsert should not duplicate)", count)
	}
}

func TestGetSkillNotFound(t *testing.T) {
	store := openTestSQLStore(t)
	if _, err := store.GetSkill(context.Background(), 999); err == nil {
		t.Fatal("expected an error looking up a nonexistent skill, got nil")
	}
}

func TestImportAndGetMonsterDrops(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	csv := "1001,50,1,1,3,0.15\n1001,51,0,1,1,0.05\n"
	drops, err := LoadMonsterDropsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadMonsterDropsCSV: %v", err)
	}
	if err := store.ImportMonsterDrops(ctx, drops); err != nil {
		t.Fatalf("ImportMonsterDrops: %v", err)
	}

	got, err := store.GetMonsterDrops(ctx, 1001)
	if err != nil {
		t.Fatalf("GetMonsterDrops: %v", err)
	}
	if len(got) != 2 || *got[0] != drops[0] || *got[1] != drops[1] {
		t.Fatalf("got %+v, want %+v", got, drops)
	}

	count, err := store.CountMonsterDrops(ctx)
	if err != nil {
		t.Fatalf("CountMonsterDrops: %v", err)
	}
	if count != 2 {
		t.Fatalf("got count %d, want 2", count)
	}
}

func TestImportMonsterDropsUpserts(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	first := MonsterDrop{MonsterID: 1001, ItemGroupID: 50, DropRatio: 0.1}
	if err := store.ImportMonsterDrops(ctx, []MonsterDrop{first}); err != nil {
		t.Fatalf("first ImportMonsterDrops: %v", err)
	}

	updated := MonsterDrop{MonsterID: 1001, ItemGroupID: 50, DropRatio: 0.5}
	if err := store.ImportMonsterDrops(ctx, []MonsterDrop{updated}); err != nil {
		t.Fatalf("second ImportMonsterDrops: %v", err)
	}

	got, err := store.GetMonsterDrops(ctx, 1001)
	if err != nil {
		t.Fatalf("GetMonsterDrops: %v", err)
	}
	if len(got) != 1 || got[0].DropRatio != 0.5 {
		t.Fatalf("got %+v, want one drop with DropRatio 0.5 (upsert should have replaced the row)", got)
	}
}

func TestGetMonsterDropsEmpty(t *testing.T) {
	store := openTestSQLStore(t)
	got, err := store.GetMonsterDrops(context.Background(), 999)
	if err != nil {
		t.Fatalf("GetMonsterDrops: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %+v, want none for a monster with no drops", got)
	}
}

func TestImportAndGetDropGroupEntries(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	csv := "50,GROUP_POTION_BASIC,500,0.7\n50,GROUP_POTION_BASIC,501,0.3\n"
	entries, err := LoadDropGroupEntriesCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadDropGroupEntriesCSV: %v", err)
	}
	if err := store.ImportDropGroupEntries(ctx, entries); err != nil {
		t.Fatalf("ImportDropGroupEntries: %v", err)
	}

	got, err := store.GetDropGroupEntries(ctx, 50)
	if err != nil {
		t.Fatalf("GetDropGroupEntries: %v", err)
	}
	if len(got) != 2 || *got[0] != entries[0] || *got[1] != entries[1] {
		t.Fatalf("got %+v, want %+v", got, entries)
	}

	count, err := store.CountDropGroupEntries(ctx)
	if err != nil {
		t.Fatalf("CountDropGroupEntries: %v", err)
	}
	if count != 2 {
		t.Fatalf("got count %d, want 2", count)
	}
}

func TestImportDropGroupEntriesUpserts(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	first := DropGroupEntry{GroupID: 50, ItemID: 500, SelectRatio: 0.1}
	if err := store.ImportDropGroupEntries(ctx, []DropGroupEntry{first}); err != nil {
		t.Fatalf("first ImportDropGroupEntries: %v", err)
	}

	updated := DropGroupEntry{GroupID: 50, ItemID: 500, SelectRatio: 0.9}
	if err := store.ImportDropGroupEntries(ctx, []DropGroupEntry{updated}); err != nil {
		t.Fatalf("second ImportDropGroupEntries: %v", err)
	}

	got, err := store.GetDropGroupEntries(ctx, 50)
	if err != nil {
		t.Fatalf("GetDropGroupEntries: %v", err)
	}
	if len(got) != 1 || got[0].SelectRatio != 0.9 {
		t.Fatalf("got %+v, want one entry with SelectRatio 0.9 (upsert should have replaced the row)", got)
	}
}

// TestSkillDamageSurvivesTheSQLRoundTrip is the regression test for a defect
// that shipped silently.
//
// The exporter emitted a skill's real damage ('att') and the CSV loader parsed
// it, but ImportSkills never wrote those columns and GetSkill never read them
// back. So on any SQL deployment -- the production path; -in-memory is the
// option -- every skill silently lost its recovered damage and fell back to the
// disclosed per-level stand-in. Nothing failed; the numbers were just quietly
// wrong.
//
// This fails against the old schema, which had no columns to hold them.
func TestSkillDamageSurvivesTheSQLRoundTrip(t *testing.T) {
	ctx := context.Background()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	defer s.Close()

	// SKILL_CH_SWORD_SMASH_A_01's real shape, plus a two-hit count.
	want := Skill{
		ID: 70001, GroupID: 7, BasicCode: "SKILL_CH_SWORD_SMASH_A", BasicLevel: 1,
		AttackPercent: 143, DamageMin: 15, DamageMax: 18, HitCount: 2,
	}
	if err := s.ImportSkills(ctx, []Skill{want}); err != nil {
		t.Fatalf("ImportSkills: %v", err)
	}
	got, err := s.GetSkill(ctx, want.ID)
	if err != nil || got == nil {
		t.Fatalf("GetSkill: %v", err)
	}
	if got.AttackPercent != want.AttackPercent || got.DamageMin != want.DamageMin || got.DamageMax != want.DamageMax {
		t.Errorf("damage lost in the round trip: got %d%%/%d-%d, want %d%%/%d-%d",
			got.AttackPercent, got.DamageMin, got.DamageMax,
			want.AttackPercent, want.DamageMin, want.DamageMax)
	}
	if got.HitCount != want.HitCount || got.HitsFor() != 2 {
		t.Errorf("hit count lost in the round trip: got %d (HitsFor %d), want 2",
			got.HitCount, got.HitsFor())
	}
}

// Round 666: the boot check's count. A table imported before round 659 holds
// the empty string in every status_params (the column's default); one row with a status
// block counts 1. Synthetic rows.
func TestCountSkillsWithStatusParams(t *testing.T) {
	ctx := context.Background()
	for _, store := range []interface {
		ImportSkills(context.Context, []Skill) error
		CountSkillsWithStatusParams(context.Context) (int, error)
	}{openTestSQLStore(t), NewMemStore()} {
		if err := store.ImportSkills(ctx, []Skill{{ID: 1}, {ID: 2}}); err != nil {
			t.Fatalf("ImportSkills: %v", err)
		}
		if n, err := store.CountSkillsWithStatusParams(ctx); err != nil || n != 0 {
			t.Fatalf("%T: %d skills with status params (err %v), want 0 before any carries one", store, n, err)
		}
		if err := store.ImportSkills(ctx, []Skill{{ID: 2, StatusParams: "bl:30000,100,1,200,0"}}); err != nil {
			t.Fatalf("ImportSkills: %v", err)
		}
		if n, err := store.CountSkillsWithStatusParams(ctx); err != nil || n != 1 {
			t.Fatalf("%T: %d skills with status params (err %v), want 1", store, n, err)
		}
	}
}
