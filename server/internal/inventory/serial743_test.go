package inventory

import (
	"context"
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// serialOf reads one slot's serial straight from the table.
func serialOf(t *testing.T, s *SQLStore, owner int64, slot int) int64 {
	t.Helper()
	var v int64
	if err := s.db.QueryRow(s.q(`SELECT serial FROM %s WHERE character_id = $1 AND slot = $2`), owner, slot).Scan(&v); err != nil {
		t.Fatalf("reading the serial of %d/%d: %v", owner, slot, err)
	}
	return v
}

// Two takes of one whole stack: one gets it (with its serial), the other
// finds the slot empty.
func TestSQLTakeItemRacedTakesOnce(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{})
	ctx := context.Background()
	if err := store.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	serial := serialOf(t, store, 1, 0)
	db := openRaceDB(t)
	var insts [2]Instance
	n := 0
	errs := raceTwice(t, db, `SELECT 1 FROM inventory_slots WHERE character_id = 1 AND slot = 0 FOR UPDATE`, nil,
		func() error {
			_, inst, err := store.TakeItem(ctx, 1, 0, 1, 100)
			if err == nil {
				insts[0] = inst
			}
			return err
		})
	for _, err := range errs {
		if err == nil {
			n++
		} else if !errors.Is(err, ErrSlotEmpty) {
			t.Fatalf("the losing take: %v, want ErrSlotEmpty", err)
		}
	}
	if n != 1 || insts[0].Serial != serial {
		t.Fatalf("%d takes succeeded (want 1), serial %d (want the row's %d)", n, insts[0].Serial, serial)
	}
}

// A whole stack moved by TakeItem + AddItemInstance keeps its serial; a part
// of one gets a new serial; the unique index refuses the same serial written
// into a table twice, so a replayed move fails rather than duplicating.
func TestSQLSerialFollowsTheWholeStack(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{200: 10})
	ctx := context.Background()
	if err := store.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	sword := serialOf(t, store, 1, 0)
	_, inst, err := store.TakeItem(ctx, 1, 0, 1, 100)
	if err != nil || inst.Serial != sword {
		t.Fatalf("TakeItem: %+v %v", inst, err)
	}
	if err := store.AddItemInstance(ctx, 2, 100, 1, inst); err != nil {
		t.Fatalf("AddItemInstance: %v", err)
	}
	if got := serialOf(t, store, 2, 0); got != sword {
		t.Fatalf("the sword arrived as serial %d, want its own %d", got, sword)
	}
	// The same instance written again: refused, nothing added.
	if err := store.AddItemInstance(ctx, 3, 100, 1, inst); err == nil {
		t.Fatal("a second copy of the same serial was written")
	}
	if list, _ := store.List(ctx, 3); len(list) != 0 {
		t.Fatalf("the refused copy left %+v", list)
	}

	// A part of a stack is a new stack.
	if err := store.AddItem(ctx, 4, 200, 5); err != nil {
		t.Fatalf("seeding potions: %v", err)
	}
	potions := serialOf(t, store, 4, 0)
	_, part, err := store.TakeItem(ctx, 4, 0, 2, 200)
	if err != nil || part.Serial != 0 {
		t.Fatalf("a part of a stack: %+v %v, want serial 0", part, err)
	}
	if err := store.AddItemInstance(ctx, 5, 200, 2, part); err != nil {
		t.Fatalf("placing the part: %v", err)
	}
	if got := serialOf(t, store, 5, 0); got == 0 || got == potions {
		t.Fatalf("the part's serial %d: want a new one (source %d)", got, potions)
	}
	// A swap keeps both rows' serials.
	if err := store.AddItem(ctx, 4, 100, 1); err != nil {
		t.Fatalf("seeding a sword: %v", err)
	}
	other := serialOf(t, store, 4, 1)
	if err := store.MoveItem(ctx, 4, 0, 1); err != nil {
		t.Fatalf("swap: %v", err)
	}
	if serialOf(t, store, 4, 1) != potions || serialOf(t, store, 4, 0) != other {
		t.Fatal("a swap renumbered its rows")
	}
}

// The schema is live-safe: a table from before the column gets one serial per
// row (the backfill), then NOT NULL and the unique index; a second open
// changes nothing.
func TestSQLSerialBackfill(t *testing.T) {
	store := openTestSQLStore(t, stubMaxStacks{})
	db := store.db
	if _, err := db.Exec(`DROP TABLE IF EXISTS inv_legacy743`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE inv_legacy743 (character_id BIGINT NOT NULL, slot INTEGER NOT NULL, item_id BIGINT NOT NULL, quantity INTEGER NOT NULL, PRIMARY KEY (character_id, slot));
		INSERT INTO inv_legacy743 VALUES (1, 0, 100, 1), (1, 1, 101, 3), (2, 0, 100, 1)`); err != nil {
		t.Fatalf("a legacy table: %v", err)
	}
	t.Cleanup(func() { db.Exec(`DROP TABLE IF EXISTS inv_legacy743`) })
	for i := 0; i < 2; i++ {
		if _, err := NewSQLStoreOwned(db, stubMaxStacks{}, "inv_legacy743", DefaultOwnerColumn); err != nil {
			t.Fatalf("open %d: %v", i+1, err)
		}
	}
	var rows, distinct, nulls int
	db.QueryRow(`SELECT count(*), count(DISTINCT serial), count(*) FILTER (WHERE serial IS NULL) FROM inv_legacy743`).Scan(&rows, &distinct, &nulls)
	if rows != 3 || distinct != 3 || nulls != 0 {
		t.Fatalf("after the backfill: %d rows, %d distinct serials, %d null; want 3, 3, 0", rows, distinct, nulls)
	}
	var notNull bool
	db.QueryRow(`SELECT attnotnull FROM pg_attribute WHERE attrelid = 'inv_legacy743'::regclass AND attname = 'serial'`).Scan(&notNull)
	var unique int
	db.QueryRow(`SELECT count(*) FROM pg_indexes WHERE tablename = 'inv_legacy743' AND indexname = 'inv_legacy743_serial_key'`).Scan(&unique)
	if !notNull || unique != 1 {
		t.Fatalf("serial NOT NULL %v, unique index %d; want true, 1", notNull, unique)
	}
}

// The in-memory bag inside a failed action comes back as it was.
func TestMemStoreRollsBackInAFailedAction(t *testing.T) {
	m := NewMemStore(stubMaxStacks{200: 10})
	ctx := context.Background()
	if err := m.AddItem(ctx, 1, 200, 4); err != nil {
		t.Fatalf("seeding: %v", err)
	}
	boom := errors.New("boom")
	err := txn.Runner{}.Run(ctx, func(ctx context.Context) error {
		if _, _, err := m.TakeItem(ctx, 1, 0, 3, 200); err != nil {
			return err
		}
		if err := m.AddItem(ctx, 2, 200, 3); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("Run: %v", err)
	}
	a, _ := m.List(ctx, 1)
	b, _ := m.List(ctx, 2)
	if len(a) != 1 || a[0].Quantity != 4 || len(b) != 0 {
		t.Fatalf("after the rollback: %+v and %+v, want 4 with 1 and nothing with 2", a, b)
	}
}
