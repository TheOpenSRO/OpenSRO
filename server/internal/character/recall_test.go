package character

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
)

// Round 686: the designated return gate (RecallStore), in memory and in
// PostgreSQL alike. None designated reads 0; a set gate reads back; an
// unknown character is ErrNotFound.
func TestRecallStores(t *testing.T) {
	ctx := context.Background()
	for name, store := range map[string]interface {
		Store
		RecallStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			c, err := store.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			if id, err := store.AppointedTeleport(ctx, c.ID); err != nil || id != 0 {
				t.Fatalf("a new character's gate: %d, %v; want 0 (none designated)", id, err)
			}
			if err := store.SetAppointedTeleport(ctx, c.ID, 2095); err != nil {
				t.Fatalf("SetAppointedTeleport: %v", err)
			}
			if id, _ := store.AppointedTeleport(ctx, c.ID); id != 2095 {
				t.Fatalf("after designating 2095 the gate reads %d", id)
			}
			if _, err := store.AppointedTeleport(ctx, 999999); !errors.Is(err, ErrNotFound) {
				t.Errorf("an unknown character's gate: %v, want ErrNotFound", err)
			}
			if err := store.SetAppointedTeleport(ctx, 999999, 1); !errors.Is(err, ErrNotFound) {
				t.Errorf("designating for an unknown character: %v, want ErrNotFound", err)
			}
		})
	}
}

// openRecallMigrationDB opens the test database with a scratch schema of its
// own (search_path mig686), dropped and recreated, so the deployed table can
// be built from scratch without touching the shared one.
func openRecallMigrationDB(t *testing.T) (string, *sql.DB) {
	t.Helper()
	dsn := testDSN()
	admin, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })
	if _, err := admin.Exec(`DROP SCHEMA IF EXISTS mig686 CASCADE; CREATE SCHEMA mig686`); err != nil {
		t.Fatalf("creating the migration schema: %v (is postgres running? see testDSN)", err)
	}
	t.Cleanup(func() { admin.Exec(`DROP SCHEMA IF EXISTS mig686 CASCADE`) })
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	scoped := dsn + sep + "search_path=mig686"
	db, err := sql.Open("pgx", scoped)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	// The probe of the probe: the scoped connection must really be in the
	// scratch schema, or the "deployed table" below would be the shared one.
	var current string
	if err := db.QueryRow(`SELECT current_schema()`).Scan(&current); err != nil || current != "mig686" {
		t.Fatalf("the scoped connection's schema is %q (%v), want mig686", current, err)
	}
	return scoped, db
}

// recallColumnLine is the migration's own line, which the deployed table
// (the schema without it) lacks.
const recallColumnLine = "ALTER TABLE characters ADD COLUMN IF NOT EXISTS appointed_teleport BIGINT NOT NULL DEFAULT 0;\n"

// TestMigration686 builds the table a deployed server has -- this package's
// schema less round 686's line, so it is dev's before the round (or whatever
// a later round has added) -- with characters on it, saved places and all,
// then opens the store on it twice. Every existing character reads 0, the
// race's gate; nothing else on the rows changes; the second open is a no-op
// and keeps a designation made in between. NEGATIVE: before round 686 there
// is no appointed_teleport column and the read below fails.
func TestMigration686(t *testing.T) {
	if !strings.Contains(schema, recallColumnLine) {
		t.Fatal("the schema has no appointed_teleport line to leave out")
	}
	dsn, db := openRecallMigrationDB(t)
	if _, err := db.Exec(strings.Replace(schema, recallColumnLine, "", 1)); err != nil {
		t.Fatalf("the deployed schema: %v", err)
	}
	var has int
	db.QueryRow(`SELECT count(*) FROM information_schema.columns WHERE table_schema = 'mig686' AND table_name = 'characters' AND column_name = 'appointed_teleport'`).Scan(&has)
	if has != 0 {
		t.Fatal("the deployed table already has appointed_teleport")
	}
	type row struct {
		name, gender, zone string
		gold               int64
		x                  float64
	}
	rows := []row{
		{"Aria", "china_man", "donwhang", 125000, 412.5},
		{"Mei", "china_woman", "", 0, 0},
		{"Bram", "china_man", "jangan", 7, -96.25},
	}
	for i, r := range rows {
		if _, err := db.Exec(`INSERT INTO characters (account_id, name, gold, gender, latest_zone, pos_x) VALUES ($1, $2, $3, $4, $5, $6)`,
			int64(i+1), r.name, r.gold, r.gender, r.zone, r.x); err != nil {
			t.Fatalf("seeding %s: %v", r.name, err)
		}
	}
	ctx := context.Background()
	check := func(pass string, want map[string]int64) {
		t.Helper()
		store, err := OpenSQLStore(dsn)
		if err != nil {
			t.Fatalf("%s: OpenSQLStore on the deployed table: %v", pass, err)
		}
		defer store.Close()
		for i, r := range rows {
			list, err := store.ListByAccount(ctx, int64(i+1))
			if err != nil || len(list) != 1 {
				t.Fatalf("%s: listing %s: %v %v", pass, r.name, list, err)
			}
			c := list[0]
			if c.Name != r.name || c.Gender != r.gender || c.Zone != r.zone || c.Gold != r.gold || c.PosX != r.x {
				t.Errorf("%s: %s came back %+v; the migration changed the row", pass, r.name, c)
			}
			id, err := store.AppointedTeleport(ctx, c.ID)
			if err != nil || id != want[r.name] {
				t.Errorf("%s: %s's gate %d (%v), want %d", pass, r.name, id, err, want[r.name])
			}
		}
	}
	none := map[string]int64{"Aria": 0, "Mei": 0, "Bram": 0}
	check("first open", none)
	// A designation between the two opens survives the second: the line adds
	// a column only where there is none.
	store, err := OpenSQLStore(dsn)
	if err != nil {
		t.Fatal(err)
	}
	list, _ := store.ListByAccount(ctx, 1)
	if err := store.SetAppointedTeleport(ctx, list[0].ID, 2095); err != nil {
		t.Fatalf("designating after the migration: %v", err)
	}
	store.Close()
	check("second open", map[string]int64{"Aria": 2095, "Mei": 0, "Bram": 0})
}
