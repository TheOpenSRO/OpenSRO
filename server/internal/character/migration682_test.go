package character

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

// The schema as it stood on dev before round 682 (3857a5e), verbatim: the
// table a deployed server already has, which round 682's migration must take
// as it finds it.
const schemaBefore682 = `
CREATE TABLE IF NOT EXISTS characters (
	id         BIGSERIAL PRIMARY KEY,
	account_id BIGINT NOT NULL,
	name       TEXT NOT NULL,
	gold       BIGINT NOT NULL DEFAULT 0,
	hp         INTEGER NOT NULL DEFAULT 100,
	gender     TEXT NOT NULL DEFAULT 'china_man'
);
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gold BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS hp INTEGER NOT NULL DEFAULT 100;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gender TEXT NOT NULL DEFAULT 'china_man';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS level INTEGER NOT NULL DEFAULT 1;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS exp BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS stat_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS storage_gold BIGINT NOT NULL DEFAULT 0;
-- The berserk orbs, the engine's _CHAR.RemainHwanCount (charData+0x86). A
-- persisted column there, so it must survive a logout here too.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS hwan_count INTEGER NOT NULL DEFAULT 0;
-- Str and Int are what health and mana are derived from (character.MaxHPFor).
-- Existing rows default to the starting values rather than 0, which would
-- otherwise leave every migrated character on zero health.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS str INTEGER NOT NULL DEFAULT 20;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS intel INTEGER NOT NULL DEFAULT 20;
-- Where the character last stood (round 573, cmd/server's -persist-position):
-- the engine's _CHAR.LatestRegion / PosX / PosY / PosZ (charData +0x94..+0xa0,
-- docs/protocol/db_bind_offsets.tsv), in srrevamp's shape -- the zone label,
-- the frame region "x/y" and a world point in that frame (Character.Zone).
-- latest_zone '' is "nothing saved": every existing row enters at the spawn.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS latest_zone TEXT NOT NULL DEFAULT '';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS latest_frame TEXT NOT NULL DEFAULT '';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS pos_x DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS pos_y DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS pos_z DOUBLE PRECISION NOT NULL DEFAULT 0;
-- The bag's size in slots (round 633), the engine's _CHAR.InventorySize
-- (charData+0xac) less its 13 equipment slots. 0 is "none stored": the
-- server's -inventory-size default applies (InventorySizeStore).
ALTER TABLE characters ADD COLUMN IF NOT EXISTS inventory_size INTEGER NOT NULL DEFAULT 0;
-- The way the character last faced (round 637's review follow-up,
-- HeadingStore): the client's heading in radians, saved with the position.
-- OURS: _CHAR declares no such column.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS heading DOUBLE PRECISION NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS characters_name_lower ON characters (LOWER(name));
CREATE INDEX IF NOT EXISTS characters_account_id ON characters(account_id);
`

// openMigrationDB opens the test database with its own schema (search_path
// mig682), dropped and recreated, so the old table can be built from scratch
// without touching the shared one.
func openMigrationDB(t *testing.T) (string, *sql.DB) {
	t.Helper()
	dsn := testDSN()
	admin, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })
	if _, err := admin.Exec(`DROP SCHEMA IF EXISTS mig682 CASCADE; CREATE SCHEMA mig682`); err != nil {
		t.Fatalf("creating the migration schema: %v (is postgres running? see testDSN)", err)
	}
	t.Cleanup(func() { admin.Exec(`DROP SCHEMA IF EXISTS mig682 CASCADE`) })
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	scoped := dsn + sep + "search_path=mig682"
	db, err := sql.Open("pgx", scoped)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	// The probe of the probe: the scoped connection must really be in the
	// scratch schema, or the "old table" below would be the shared one.
	var schema string
	if err := db.QueryRow(`SELECT current_schema()`).Scan(&schema); err != nil || schema != "mig682" {
		t.Fatalf("the scoped connection's schema is %q (%v), want mig682", schema, err)
	}
	return scoped, db
}

// TestMigration682 builds the pre-682 table with existing characters --
// including names the new rules refuse -- and opens the store on it twice.
// NEGATIVE: before round 682 there is no ref_obj_id, scale or deleted_at
// column, and the reads below fail.
func TestMigration682(t *testing.T) {
	dsn, db := openMigrationDB(t)
	if _, err := db.Exec(schemaBefore682); err != nil {
		t.Fatalf("old schema: %v", err)
	}
	var oldCols int
	db.QueryRow(`SELECT count(*) FROM information_schema.columns WHERE table_schema = 'mig682' AND table_name = 'characters' AND column_name IN ('ref_obj_id', 'scale', 'deleted_at')`).Scan(&oldCols)
	if oldCols != 0 {
		t.Fatalf("the old table already has %d of the new columns", oldCols)
	}
	rows := []struct {
		account int64
		name    string
		gender  string
	}{
		{1, "Aria", "china_man"},
		{1, "Mei", "china_woman"},
		{2, "x", "china_man"},                    // one byte: below the new 2..12
		{2, "A Name With Spaces", "china_woman"}, // 18 bytes and spaces
		{3, "O'Brien", "china_man"},              // a quote
		{3, "Ünïcode", "china_woman"},            // non-ASCII
	}
	for _, r := range rows {
		if _, err := db.Exec(`INSERT INTO characters (account_id, name, gold, hp, gender, level, str, intel, latest_zone, pos_x) VALUES ($1, $2, 5, 77, $3, 9, 31, 22, 'jangan', 12.5)`,
			r.account, r.name, r.gender); err != nil {
			t.Fatal(err)
		}
	}
	for pass := 1; pass <= 2; pass++ {
		s, err := OpenSQLStore(dsn)
		if err != nil {
			t.Fatalf("pass %d: OpenSQLStore on the old table: %v", pass, err)
		}
		for _, r := range rows {
			list, err := s.ListByAccount(context.Background(), r.account)
			if err != nil {
				t.Fatalf("pass %d: %v", pass, err)
			}
			var got *Character
			for _, c := range list {
				if c.Name == r.name {
					got = c
				}
			}
			if got == nil {
				t.Fatalf("pass %d: %q lost (names are kept whatever the new rules say)", pass, r.name)
			}
			if got.RefObjID != LegacyModelFor(r.gender) || got.Scale != DefaultScale || got.Deleting() || got.StartZone != "" {
				t.Errorf("pass %d: %q migrated to model %d scale %#x deleting %v start %q", pass, r.name, got.RefObjID, got.Scale, got.Deleting(), got.StartZone)
			}
			if got.Gender != r.gender || got.Gold != 5 || got.HP != 77 || got.Level != 9 || got.Str != 31 || got.Zone != "jangan" || got.PosX != 12.5 {
				t.Errorf("pass %d: %q lost a field: %+v", pass, r.name, got)
			}
		}
		if pass == 1 {
			// A row the lobby has since given another body is left alone by
			// the second run: the migration only touches ref_obj_id 0.
			if _, err := db.Exec(`UPDATE characters SET ref_obj_id = 14875, scale = 65 WHERE name = 'Aria'`); err != nil {
				t.Fatal(err)
			}
			rows[0].gender = "china_man"
		}
		if pass == 2 {
			var ref int64
			var scale int
			db.QueryRow(`SELECT ref_obj_id, scale FROM characters WHERE name = 'Aria'`).Scan(&ref, &scale)
			if ref != 14875 || scale != 65 {
				t.Errorf("the second run rewrote a migrated row: %d %#x", ref, scale)
			}
		}
		s.Close()
		if pass == 1 {
			// Aria's row is checked against its new body on pass 2 above.
			rows = rows[1:]
		}
	}
}

// The SQL half of LobbyStore: create with a body and a start, the limit, the
// name lookup, delete, restore and purge.
func TestSQLLobbyStore(t *testing.T) {
	s := openTestSQLStore(t)
	ctx := context.Background()
	nc := func(name string) NewCharacter {
		return NewCharacter{Name: name, RefObjID: 14888, Scale: 0x41, Gender: GenderEuropeWoman,
			StartZone: "constantinople", StartX: 245, StartY: 80, StartZ: -3276}
	}
	c, err := s.CreateCharacter(ctx, 7, nc("Kasia"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.GetByID(ctx, c.ID)
	if err != nil || got.RefObjID != 14888 || got.Scale != 0x41 || got.Gender != GenderEuropeWoman ||
		got.StartZone != "constantinople" || got.StartX != 245 || got.StartY != 80 || got.StartZ != -3276 || got.Deleting() {
		t.Fatalf("stored %+v %v", got, err)
	}
	if _, err := s.CreateCharacter(ctx, 8, nc("KASIA")); err != ErrNameTaken {
		t.Errorf("a taken name: %v", err)
	}
	for _, n := range []string{"B1", "B2", "B3"} {
		if _, err := s.CreateCharacter(ctx, 7, nc(n)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.CreateCharacter(ctx, 7, nc("B4")); err != ErrAccountFull {
		t.Errorf("a fifth: %v", err)
	}
	if taken, _ := s.NameTaken(ctx, "kasia"); !taken {
		t.Error("NameTaken missed a name in another case")
	}
	at := time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)
	if err := s.MarkDeleted(ctx, 8, c.ID, at); err != ErrNotFound {
		t.Errorf("another account's delete: %v", err)
	}
	if err := s.MarkDeleted(ctx, 7, c.ID, at); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkDeleted(ctx, 7, c.ID, at); err != ErrAlreadyDeleting {
		t.Errorf("deleting twice: %v", err)
	}
	got, _ = s.GetByID(ctx, c.ID)
	if !got.DeletedAt.Equal(at) || got.MinutesLeft(at.Add(time.Hour)) != 10080-60 {
		t.Errorf("deleted at %v, %d minutes left", got.DeletedAt, got.MinutesLeft(at.Add(time.Hour)))
	}
	if err := s.Restore(ctx, 7, c.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Restore(ctx, 7, c.ID); err != ErrNotDeleting {
		t.Errorf("restoring twice: %v", err)
	}
	s.MarkDeleted(ctx, 7, c.ID, at)
	if ids, _ := s.PurgeDeleted(ctx, at.Add(-time.Second)); len(ids) != 0 {
		t.Errorf("purged %v early", ids)
	}
	if ids, _ := s.PurgeDeleted(ctx, at); len(ids) != 1 || ids[0] != c.ID {
		t.Errorf("purged %v, want %d", ids, c.ID)
	}
	if taken, _ := s.NameTaken(ctx, "Kasia"); taken {
		t.Error("the purged name is still taken")
	}
}
