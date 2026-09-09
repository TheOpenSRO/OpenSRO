package refdata

import (
	"context"
	"testing"
)

// Synthetic values throughout -- nothing here is any real game's data.

func TestMemStoreItems(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if n, _ := store.Count(ctx); n != 0 {
		t.Fatalf("a new store holds %d items, want 0", n)
	}
	if _, err := store.GetItem(ctx, 1); err == nil {
		t.Fatal("GetItem on an empty store succeeded")
	}

	if err := store.ImportItems(ctx, []Item{
		{ID: 2, MaxStack: 20, PhysAttackMin: 5},
		{ID: 1, MaxStack: 1},
	}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}

	got, err := store.GetItem(ctx, 2)
	if err != nil {
		t.Fatalf("GetItem: %v", err)
	}
	if got.MaxStack != 20 || got.PhysAttackMin != 5 {
		t.Fatalf("item 2 = %+v", got)
	}
	// The returned item is a copy: mutating it must not change the store.
	got.MaxStack = 999
	again, _ := store.GetItem(ctx, 2)
	if again.MaxStack != 20 {
		t.Fatalf("mutating a returned item changed the store: %+v", again)
	}

	if n, _ := store.GetMaxStack(ctx, 2); n != 20 {
		t.Fatalf("GetMaxStack(2) = %d, want 20", n)
	}
	// An item with no reference row answers "no configured limit" rather
	// than failing: an error there made such an item impossible to hold,
	// and cost a new character their starting kit on any deployment that
	// had not imported those five items.
	if n, err := store.GetMaxStack(ctx, 99); err != nil || n != 0 {
		t.Fatalf("GetMaxStack for an unknown item = %d, %v; want 0, nil", n, err)
	}

	all, err := store.ListAll(ctx)
	if err != nil {
		t.Fatalf("ListAll: %v", err)
	}
	if len(all) != 2 || all[0].ID != 1 || all[1].ID != 2 {
		t.Fatalf("ListAll = %+v, want both items in id order", all)
	}

	// Importing again upserts by ID rather than duplicating.
	if err := store.ImportItems(ctx, []Item{{ID: 1, MaxStack: 5}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	if n, _ := store.Count(ctx); n != 2 {
		t.Fatalf("re-importing gave %d items, want 2", n)
	}
	if n, _ := store.GetMaxStack(ctx, 1); n != 5 {
		t.Fatalf("re-import did not update item 1: max stack %d", n)
	}
}

func TestMemStoreSkills(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.ImportSkills(ctx, []Skill{{ID: 7}}); err != nil {
		t.Fatalf("ImportSkills: %v", err)
	}
	if _, err := store.GetSkill(ctx, 7); err != nil {
		t.Fatalf("GetSkill: %v", err)
	}
	if _, err := store.GetSkill(ctx, 8); err == nil {
		t.Fatal("GetSkill for an unimported skill succeeded")
	}
	if n, _ := store.CountSkills(ctx); n != 1 {
		t.Fatalf("CountSkills = %d, want 1", n)
	}
	if all, _ := store.ListAllSkills(ctx); len(all) != 1 || all[0].ID != 7 {
		t.Fatalf("ListAllSkills = %+v", all)
	}
}

// Importing a monster's drops replaces that monster's rows rather than
// appending to them, which is what the SQL store's delete-then-insert does.
func TestMemStoreDropsReplacePerMonster(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.ImportMonsterDrops(ctx, []MonsterDrop{
		{MonsterID: 1}, {MonsterID: 1}, {MonsterID: 2},
	}); err != nil {
		t.Fatalf("ImportMonsterDrops: %v", err)
	}
	if n, _ := store.CountMonsterDrops(ctx); n != 3 {
		t.Fatalf("CountMonsterDrops = %d, want 3", n)
	}

	if err := store.ImportMonsterDrops(ctx, []MonsterDrop{{MonsterID: 1}}); err != nil {
		t.Fatalf("ImportMonsterDrops: %v", err)
	}
	rows, _ := store.GetMonsterDrops(ctx, 1)
	if len(rows) != 1 {
		t.Fatalf("monster 1 has %d row(s) after re-import, want 1", len(rows))
	}
	if rows, _ := store.GetMonsterDrops(ctx, 2); len(rows) != 1 {
		t.Fatalf("re-importing monster 1 disturbed monster 2: %d row(s)", len(rows))
	}
}

func TestMemStoreDropGroups(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	if err := store.ImportDropGroupEntries(ctx, []DropGroupEntry{
		{GroupID: 5}, {GroupID: 5}, {GroupID: 6},
	}); err != nil {
		t.Fatalf("ImportDropGroupEntries: %v", err)
	}
	if n, _ := store.CountDropGroupEntries(ctx); n != 3 {
		t.Fatalf("CountDropGroupEntries = %d, want 3", n)
	}
	if rows, _ := store.GetDropGroupEntries(ctx, 5); len(rows) != 2 {
		t.Fatalf("group 5 has %d entries, want 2", len(rows))
	}
	if err := store.ImportDropGroupEntries(ctx, []DropGroupEntry{{GroupID: 5}}); err != nil {
		t.Fatalf("ImportDropGroupEntries: %v", err)
	}
	if rows, _ := store.GetDropGroupEntries(ctx, 5); len(rows) != 1 {
		t.Fatalf("group 5 has %d entries after re-import, want 1", len(rows))
	}
}
