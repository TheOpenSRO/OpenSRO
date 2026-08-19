package refdata

import (
	"context"
	"strings"
	"testing"
)

func TestImportAndGetItem(t *testing.T) {
	store, err := OpenSQLStore(":memory:")
	if err != nil {
		t.Fatalf("OpenSQLStore: %v", err)
	}
	defer store.Close()
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

func TestImportItemsUpserts(t *testing.T) {
	store, err := OpenSQLStore(":memory:")
	if err != nil {
		t.Fatalf("OpenSQLStore: %v", err)
	}
	defer store.Close()
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
	store, err := OpenSQLStore(":memory:")
	if err != nil {
		t.Fatalf("OpenSQLStore: %v", err)
	}
	defer store.Close()

	if _, err := store.GetItem(context.Background(), 999); err == nil {
		t.Fatal("expected an error looking up a nonexistent item, got nil")
	}
}
