package storage

import (
	"context"
	"database/sql"
	"os"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/testdb"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// testDSN points at a local PostgreSQL instance for tests. Override with
// SRREVAMP_TEST_POSTGRES_DSN if your dev setup differs (e.g. CI).
func testDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

// TestMain holds the shared test-database lock for the whole package run
// (see internal/testdb).
func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}

// The move from the per-character warehouse to the account's, on the real
// schema: two characters on one account each hold slot 0 (a collision) and
// slot 1 (Aria) / slot 3 (Bram) (no collision), and each has stored gold.
// Afterwards the account holds all four rows -- the colliding one moved to
// the lowest free slot, the others where they were -- and the summed gold;
// the legacy table is empty; a second run does nothing.
func TestMigrateToAccountsIsLosslessAndRunsOnce(t *testing.T) {
	ctx := context.Background()
	dsn := testDSN()

	accounts, err := account.OpenSQLStore(dsn)
	if err != nil {
		t.Fatalf("opening accounts: %v (is postgres running? see testDSN)", err)
	}
	defer accounts.Close()
	chars, err := character.OpenSQLStore(dsn)
	if err != nil {
		t.Fatalf("opening characters: %v", err)
	}
	defer chars.Close()
	// The legacy container, per character, and the new one, per account.
	legacy, err := inventory.OpenSQLStoreNamed(dsn, generousStacks{}, LegacyWarehouseTable)
	if err != nil {
		t.Fatalf("opening legacy warehouse: %v", err)
	}
	defer legacy.Close()
	warehouse, err := inventory.OpenSQLStoreOwned(dsn, generousStacks{}, inventory.WarehouseTable, inventory.WarehouseOwnerColumn)
	if err != nil {
		t.Fatalf("opening warehouse: %v", err)
	}
	defer warehouse.Close()
	db := warehouse.DB()

	// A clean slate: this package owns these rows for the duration of the
	// lock. The migration marker is removed so the move runs.
	for _, stmt := range []string{
		`DELETE FROM ` + LegacyWarehouseTable,
		`DELETE FROM ` + inventory.WarehouseTable,
		`DELETE FROM characters WHERE name IN ('MigAria', 'MigBram')`,
		`DELETE FROM accounts WHERE username = 'migrate-test'`,
		`CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`,
		`DELETE FROM schema_migrations WHERE name = '` + migrationName + `'`,
	} {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}

	acc, err := accounts.Register(ctx, "migrate-test", "pw")
	if err != nil {
		t.Fatalf("registering account: %v", err)
	}
	aria, err := chars.Create(ctx, acc.ID, "MigAria")
	if err != nil {
		t.Fatalf("creating MigAria: %v", err)
	}
	bram, err := chars.Create(ctx, acc.ID, "MigBram")
	if err != nil {
		t.Fatalf("creating MigBram: %v", err)
	}

	// Legacy rows, written the way the old server wrote them: a row per
	// (character, slot) with per-instance columns.
	seed := func(cid int64, slot int, item int64, qty int, variance int64, dur int) {
		t.Helper()
		if _, err := db.ExecContext(ctx, `INSERT INTO `+LegacyWarehouseTable+` (character_id, slot, item_id, quantity, variance, durability) VALUES ($1, $2, $3, $4, $5, $6)`,
			cid, slot, item, qty, variance, dur); err != nil {
			t.Fatalf("seeding legacy row: %v", err)
		}
	}
	seed(aria.ID, 0, 100, 5, 0, -1)
	seed(aria.ID, 1, 200, 1, 0x1f, 40)
	seed(bram.ID, 0, 300, 2, 0, -1) // collides with Aria's slot 0
	seed(bram.ID, 3, 400, 1, 0, 7)
	if err := chars.AddStorageGold(ctx, aria.ID, 300); err != nil {
		t.Fatalf("seeding Aria's stored gold: %v", err)
	}
	if err := chars.AddStorageGold(ctx, bram.ID, 200); err != nil {
		t.Fatalf("seeding Bram's stored gold: %v", err)
	}

	moved, err := MigrateToAccounts(ctx, db, nil)
	if err != nil {
		t.Fatalf("MigrateToAccounts: %v", err)
	}
	if !moved.Applied || moved.Rows != 4 || moved.Reslotted != 1 || moved.Gold != 500 || moved.Characters != 2 || moved.Accounts != 1 || moved.Orphans != 0 {
		t.Fatalf("migration report %+v, want applied, 4 rows, 1 reslotted, 500 gold, 2 characters, 1 account, 0 orphans", moved)
	}

	got, err := warehouse.List(ctx, acc.ID)
	if err != nil {
		t.Fatalf("listing the account's warehouse: %v", err)
	}
	// Order of the copy: Aria's rows first (slot 0, slot 1), then Bram's
	// (slot 0 -> lowest free = 2, slot 3 stays).
	want := []inventory.Slot{
		{Index: 0, ItemID: 100, Quantity: 5, Variance: 0, Durability: -1},
		{Index: 1, ItemID: 200, Quantity: 1, Variance: 0x1f, Durability: 40},
		{Index: 2, ItemID: 300, Quantity: 2, Variance: 0, Durability: -1},
		{Index: 3, ItemID: 400, Quantity: 1, Variance: 0, Durability: 7},
	}
	if len(got) != len(want) {
		t.Fatalf("account warehouse has %d rows %+v, want %d", len(got), got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("row %d: got %+v, want %+v", i, got[i], want[i])
		}
	}

	var legacyLeft int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM `+LegacyWarehouseTable).Scan(&legacyLeft); err != nil {
		t.Fatalf("counting legacy rows: %v", err)
	}
	if legacyLeft != 0 {
		t.Errorf("legacy table still holds %d rows", legacyLeft)
	}
	if gold, _ := accounts.StorageGold(ctx, acc.ID); gold != 500 {
		t.Errorf("account stored gold %d, want 500", gold)
	}
	for _, c := range []*character.Character{aria, bram} {
		fresh, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("re-reading %s: %v", c.Name, err)
		}
		if fresh.StorageGold != 0 {
			t.Errorf("%s still carries %d stored gold on the character row", c.Name, fresh.StorageGold)
		}
	}

	// Once. A second boot finds the marker and touches nothing -- even with
	// a fresh legacy row present, which is exactly the double-count trap.
	seed(aria.ID, 5, 999, 1, 0, -1)
	again, err := MigrateToAccounts(ctx, db, nil)
	if err != nil {
		t.Fatalf("second MigrateToAccounts: %v", err)
	}
	if again.Applied {
		t.Fatalf("second run applied the migration again: %+v", again)
	}
	if after, _ := warehouse.List(ctx, acc.ID); len(after) != 4 {
		t.Errorf("second run changed the account warehouse: %+v", after)
	}
	_, _ = db.ExecContext(ctx, `DELETE FROM `+LegacyWarehouseTable)
}

// A database that never ran the per-character server has no legacy table;
// the migration must still record itself and not fail.
func TestMigrateToAccountsWithoutLegacyTable(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatalf("opening db: %v", err)
	}
	defer db.Close()
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`); err != nil {
		t.Fatalf("schema_migrations: %v", err)
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM schema_migrations WHERE name = $1`, migrationName); err != nil {
		t.Fatalf("clearing marker: %v", err)
	}
	// The new warehouse table must exist for the move (main opens it first).
	warehouse, err := inventory.OpenSQLStoreOwned(testDSN(), generousStacks{}, inventory.WarehouseTable, inventory.WarehouseOwnerColumn)
	if err != nil {
		t.Fatalf("opening warehouse: %v", err)
	}
	defer warehouse.Close()
	if _, err := db.ExecContext(ctx, `DROP TABLE IF EXISTS `+LegacyWarehouseTable); err != nil {
		t.Fatalf("dropping legacy table: %v", err)
	}
	moved, err := MigrateToAccounts(ctx, db, nil)
	if err != nil {
		t.Fatalf("MigrateToAccounts without legacy table: %v", err)
	}
	if !moved.Applied || moved.Rows != 0 {
		t.Fatalf("report %+v, want applied with 0 rows", moved)
	}
	var marked bool
	if err := db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE name = $1)`, migrationName).Scan(&marked); err != nil || !marked {
		t.Fatalf("marker missing after the run (err %v)", err)
	}
}
