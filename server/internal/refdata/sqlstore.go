package refdata

import (
	"context"
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite" // driver registration
)

const schema = `
CREATE TABLE IF NOT EXISTS items (
	id                INTEGER PRIMARY KEY,
	max_stack         INTEGER NOT NULL,
	req_str           INTEGER NOT NULL,
	req_int           INTEGER NOT NULL,
	item_class        INTEGER NOT NULL,
	two_handed        INTEGER NOT NULL,
	durability_min    REAL NOT NULL,
	durability_max    REAL NOT NULL,
	phys_defense_min  REAL NOT NULL,
	phys_defense_max  REAL NOT NULL,
	mag_defense_min   REAL NOT NULL,
	mag_defense_max   REAL NOT NULL,
	phys_attack_min   REAL NOT NULL,
	phys_attack_max   REAL NOT NULL,
	mag_attack_min    REAL NOT NULL,
	mag_attack_max    REAL NOT NULL,
	hit_rate_min      REAL NOT NULL,
	hit_rate_max      REAL NOT NULL,
	critical_min      REAL NOT NULL,
	critical_max      REAL NOT NULL
);
`

// SQLStore is this project's own item reference-data store, backed by
// SQLite via the pure-Go modernc.org/sqlite driver.
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens (creating if necessary) a SQLite database at dsn and
// ensures its schema exists. Use ":memory:" for an ephemeral database.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("refdata: opening sqlite database: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("refdata: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// ImportItems upserts every item in items (by ID), inside one transaction.
func (s *SQLStore) ImportItems(ctx context.Context, items []Item) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("refdata: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO items (
			id, max_stack, req_str, req_int, item_class, two_handed,
			durability_min, durability_max, phys_defense_min, phys_defense_max,
			mag_defense_min, mag_defense_max, phys_attack_min, phys_attack_max,
			mag_attack_min, mag_attack_max, hit_rate_min, hit_rate_max,
			critical_min, critical_max
		) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET
			max_stack=excluded.max_stack, req_str=excluded.req_str, req_int=excluded.req_int,
			item_class=excluded.item_class, two_handed=excluded.two_handed,
			durability_min=excluded.durability_min, durability_max=excluded.durability_max,
			phys_defense_min=excluded.phys_defense_min, phys_defense_max=excluded.phys_defense_max,
			mag_defense_min=excluded.mag_defense_min, mag_defense_max=excluded.mag_defense_max,
			phys_attack_min=excluded.phys_attack_min, phys_attack_max=excluded.phys_attack_max,
			mag_attack_min=excluded.mag_attack_min, mag_attack_max=excluded.mag_attack_max,
			hit_rate_min=excluded.hit_rate_min, hit_rate_max=excluded.hit_rate_max,
			critical_min=excluded.critical_min, critical_max=excluded.critical_max
	`)
	if err != nil {
		return fmt.Errorf("refdata: preparing insert: %w", err)
	}
	defer stmt.Close()

	for _, it := range items {
		twoHanded := 0
		if it.TwoHanded {
			twoHanded = 1
		}
		if _, err := stmt.ExecContext(ctx,
			it.ID, it.MaxStack, it.ReqStr, it.ReqInt, it.ItemClass, twoHanded,
			it.DurabilityMin, it.DurabilityMax, it.PhysDefenseMin, it.PhysDefenseMax,
			it.MagDefenseMin, it.MagDefenseMax, it.PhysAttackMin, it.PhysAttackMax,
			it.MagAttackMin, it.MagAttackMax, it.HitRateMin, it.HitRateMax,
			it.CriticalMin, it.CriticalMax,
		); err != nil {
			return fmt.Errorf("refdata: inserting item %d: %w", it.ID, err)
		}
	}
	return tx.Commit()
}

// GetItem looks up one item by ID.
func (s *SQLStore) GetItem(ctx context.Context, id int64) (*Item, error) {
	var it Item
	var twoHanded int
	row := s.db.QueryRowContext(ctx, `
		SELECT id, max_stack, req_str, req_int, item_class, two_handed,
			durability_min, durability_max, phys_defense_min, phys_defense_max,
			mag_defense_min, mag_defense_max, phys_attack_min, phys_attack_max,
			mag_attack_min, mag_attack_max, hit_rate_min, hit_rate_max,
			critical_min, critical_max
		FROM items WHERE id = ?`, id)
	if err := row.Scan(
		&it.ID, &it.MaxStack, &it.ReqStr, &it.ReqInt, &it.ItemClass, &twoHanded,
		&it.DurabilityMin, &it.DurabilityMax, &it.PhysDefenseMin, &it.PhysDefenseMax,
		&it.MagDefenseMin, &it.MagDefenseMax, &it.PhysAttackMin, &it.PhysAttackMax,
		&it.MagAttackMin, &it.MagAttackMax, &it.HitRateMin, &it.HitRateMax,
		&it.CriticalMin, &it.CriticalMax,
	); err != nil {
		return nil, fmt.Errorf("refdata: querying item %d: %w", id, err)
	}
	it.TwoHanded = twoHanded != 0
	return &it, nil
}

// Count returns how many items are stored.
func (s *SQLStore) Count(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM items`).Scan(&n)
	return n, err
}
