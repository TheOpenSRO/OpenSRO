package inventory

import (
	"context"
	"database/sql"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

const schema = `
CREATE TABLE IF NOT EXISTS inventory_slots (
	character_id BIGINT NOT NULL,
	slot         INTEGER NOT NULL,
	item_id      BIGINT NOT NULL,
	quantity     INTEGER NOT NULL,
	PRIMARY KEY (character_id, slot)
);
`

// SQLStore is a Store backed by PostgreSQL, consistent with
// account/character/refdata's approach. Needs a MaxStackLookup (in
// production, refdata.SQLStore) to know each item's stack limit.
type SQLStore struct {
	db        *sql.DB
	maxStacks MaxStackLookup
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists. maxStacks resolves item stack limits for AddItem.
func OpenSQLStore(dsn string, maxStacks MaxStackLookup) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("inventory: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("inventory: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("inventory: creating schema: %w", err)
	}
	return &SQLStore{db: db, maxStacks: maxStacks}, nil
}

// TruncateForTest clears all inventory data. Exported only so other
// packages' tests (which share this Postgres instance and can't reach the
// unexported db field directly) can isolate themselves between runs; not
// for production use.
//
// **Isolation between runs, not between packages.** Twenty-one test files
// truncate these shared tables, so two packages testing at once clear each
// other's rows mid-test -- which showed up in CI as internal/shop failing
// with a duplicate key on inventory slot 0, its insert racing another
// package's after both had been told the slot was free. The Go tests
// therefore run one package at a time (`go test -p 1`); see the CI
// workflow.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE inventory_slots`)
	return err
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// List implements Store.
func (s *SQLStore) List(ctx context.Context, characterID int64) ([]Slot, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT slot, item_id, quantity FROM inventory_slots WHERE character_id = $1 ORDER BY slot`,
		characterID)
	if err != nil {
		return nil, fmt.Errorf("inventory: listing slots: %w", err)
	}
	defer rows.Close()

	var out []Slot
	for rows.Next() {
		var sl Slot
		if err := rows.Scan(&sl.Index, &sl.ItemID, &sl.Quantity); err != nil {
			return nil, fmt.Errorf("inventory: scanning row: %w", err)
		}
		out = append(out, sl)
	}
	return out, rows.Err()
}

// AddItem implements Store.
func (s *SQLStore) AddItem(ctx context.Context, characterID, itemID int64, quantity int) error {
	maxStack, err := s.maxStacks.GetMaxStack(ctx, itemID)
	if err != nil {
		return fmt.Errorf("inventory: looking up max stack for item %d: %w", itemID, err)
	}
	if maxStack <= 0 {
		maxStack = 1 // an item with no configured stack limit doesn't stack
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	existing, occupied, err := loadOccupancy(ctx, tx, characterID)
	if err != nil {
		return err
	}

	remaining := quantity

	// Fill existing under-full stacks of the same item first.
	for i := range existing {
		if remaining == 0 {
			break
		}
		sl := &existing[i]
		if sl.ItemID != itemID || sl.Quantity >= maxStack {
			continue
		}
		room := maxStack - sl.Quantity
		add := min(room, remaining)
		if _, err := tx.ExecContext(ctx,
			`UPDATE inventory_slots SET quantity = quantity + $1 WHERE character_id = $2 AND slot = $3`,
			add, characterID, sl.Index); err != nil {
			return fmt.Errorf("inventory: topping up slot %d: %w", sl.Index, err)
		}
		remaining -= add
	}

	// Use empty slots for whatever's left.
	for remaining > 0 {
		slotIdx := firstFree(occupied)
		if slotIdx < 0 {
			return ErrNoRoom
		}
		occupied[slotIdx] = true

		add := min(maxStack, remaining)
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO inventory_slots (character_id, slot, item_id, quantity) VALUES ($1, $2, $3, $4)`,
			characterID, slotIdx, itemID, add); err != nil {
			return fmt.Errorf("inventory: inserting into slot %d: %w", slotIdx, err)
		}
		remaining -= add
	}

	return tx.Commit()
}

// RemoveItem implements Store.
func (s *SQLStore) RemoveItem(ctx context.Context, characterID int64, slot int, quantity int) error {
	if slot < 0 || slot >= SlotsPerCharacter {
		return ErrInvalidSlot
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var current int
	err = tx.QueryRowContext(ctx,
		`SELECT quantity FROM inventory_slots WHERE character_id = $1 AND slot = $2`,
		characterID, slot).Scan(&current)
	if err == sql.ErrNoRows {
		return ErrSlotEmpty
	}
	if err != nil {
		return fmt.Errorf("inventory: reading slot %d: %w", slot, err)
	}
	if quantity > current {
		return ErrInsufficientQuantity
	}

	if quantity == current {
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM inventory_slots WHERE character_id = $1 AND slot = $2`, characterID, slot); err != nil {
			return fmt.Errorf("inventory: clearing slot %d: %w", slot, err)
		}
	} else {
		if _, err := tx.ExecContext(ctx,
			`UPDATE inventory_slots SET quantity = quantity - $1 WHERE character_id = $2 AND slot = $3`,
			quantity, characterID, slot); err != nil {
			return fmt.Errorf("inventory: decrementing slot %d: %w", slot, err)
		}
	}
	return tx.Commit()
}

// loadOccupancy returns the current slots plus a SlotsPerCharacter-sized
// occupancy map, for AddItem's stacking/placement logic.
func loadOccupancy(ctx context.Context, tx *sql.Tx, characterID int64) ([]Slot, [SlotsPerCharacter]bool, error) {
	var occupied [SlotsPerCharacter]bool
	rows, err := tx.QueryContext(ctx,
		`SELECT slot, item_id, quantity FROM inventory_slots WHERE character_id = $1 ORDER BY slot`,
		characterID)
	if err != nil {
		return nil, occupied, fmt.Errorf("inventory: loading current slots: %w", err)
	}
	defer rows.Close()

	var out []Slot
	for rows.Next() {
		var sl Slot
		if err := rows.Scan(&sl.Index, &sl.ItemID, &sl.Quantity); err != nil {
			return nil, occupied, fmt.Errorf("inventory: scanning row: %w", err)
		}
		if sl.Index >= 0 && sl.Index < SlotsPerCharacter {
			occupied[sl.Index] = true
		}
		out = append(out, sl)
	}
	return out, occupied, rows.Err()
}

func firstFree(occupied [SlotsPerCharacter]bool) int {
	for i, taken := range occupied {
		if !taken {
			return i
		}
	}
	return -1
}
