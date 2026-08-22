package refdata

import (
	"context"
	"os"
	"strings"
	"testing"
)

// testDSN points at a local PostgreSQL instance for tests. Override with
// SRREVAMP_TEST_POSTGRES_DSN if your dev setup differs (e.g. CI).
func testDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
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
	t.Cleanup(func() { s.Close() })
	return s
}

func TestImportAndGetItem(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3\n"
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

	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3\n" +
		"2,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3\n"
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

	csv := "1,10,SKILL_CH_SWORD_ATTACK_01,SN_SWORD_ATTACK_01,1,0,5,500,300,1000,3000,3000,0.0,1,0,1\n"
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
	if *got != skills[0] {
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
	if len(all) != 1 || *all[0] != skills[0] {
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
