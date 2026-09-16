package inventory

import (
	"context"
	"database/sql"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// DefaultTable is the bag's table. A second container (the warehouse) opens
// the same store against a different table via OpenSQLStoreNamed, so all the
// stacking and placement logic is shared rather than duplicated.
const DefaultTable = "inventory_slots"

// schemaFor returns the CREATE TABLE for a container's table. The table name
// is a trusted constant (never user input), so interpolating it is safe.
func schemaFor(table string) string {
	return fmt.Sprintf(`
CREATE TABLE IF NOT EXISTS %s (
	character_id BIGINT NOT NULL,
	slot         INTEGER NOT NULL,
	item_id      BIGINT NOT NULL,
	quantity     INTEGER NOT NULL,
	PRIMARY KEY (character_id, slot)
);
`, table)
}

// SQLStore is a Store backed by PostgreSQL, consistent with
// account/character/refdata's approach. Needs a MaxStackLookup (in
// production, refdata.SQLStore) to know each item's stack limit. `table` is
// the container's table -- the bag or the warehouse.
type SQLStore struct {
	db        *sql.DB
	maxStacks MaxStackLookup
	table     string
}

// OpenSQLStore opens the bag store (the DefaultTable). See OpenSQLStoreNamed
// for a second container.
func OpenSQLStore(dsn string, maxStacks MaxStackLookup) (*SQLStore, error) {
	return OpenSQLStoreNamed(dsn, maxStacks, DefaultTable)
}

// OpenSQLStoreNamed opens a PostgreSQL-backed container using the given table,
// ensuring its schema exists. The warehouse passes its own table so it is a
// separate container sharing all of the bag's logic.
func OpenSQLStoreNamed(dsn string, maxStacks MaxStackLookup, table string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("inventory: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("inventory: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schemaFor(table)); err != nil {
		db.Close()
		return nil, fmt.Errorf("inventory: creating schema: %w", err)
	}
	return &SQLStore{db: db, maxStacks: maxStacks, table: table}, nil
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
	_, err := s.db.ExecContext(ctx, fmt.Sprintf(`TRUNCATE TABLE %s`, s.table))
	return err
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// List implements Store.
func (s *SQLStore) List(ctx context.Context, characterID int64) ([]Slot, error) {
	rows, err := s.db.QueryContext(ctx,
		fmt.Sprintf(`SELECT slot, item_id, quantity FROM %s WHERE character_id = $1 ORDER BY slot`, s.table),
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
	if quantity <= 0 {
		return ErrInvalidQuantity
	}
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

	existing, occupied, err := s.loadOccupancy(ctx, tx, characterID)
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
			fmt.Sprintf(`UPDATE %s SET quantity = quantity + $1 WHERE character_id = $2 AND slot = $3`, s.table),
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
			fmt.Sprintf(`INSERT INTO %s (character_id, slot, item_id, quantity) VALUES ($1, $2, $3, $4)`, s.table),
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
	// See MemStore.RemoveItem: a negative quantity passes the upper-bound check
	// and turns the removal into an addition.
	if quantity <= 0 {
		return ErrInvalidQuantity
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var current int
	err = tx.QueryRowContext(ctx,
		fmt.Sprintf(`SELECT quantity FROM %s WHERE character_id = $1 AND slot = $2`, s.table),
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
			fmt.Sprintf(`DELETE FROM %s WHERE character_id = $1 AND slot = $2`, s.table), characterID, slot); err != nil {
			return fmt.Errorf("inventory: clearing slot %d: %w", slot, err)
		}
	} else {
		if _, err := tx.ExecContext(ctx,
			fmt.Sprintf(`UPDATE %s SET quantity = quantity - $1 WHERE character_id = $2 AND slot = $3`, s.table),
			quantity, characterID, slot); err != nil {
			return fmt.Errorf("inventory: decrementing slot %d: %w", slot, err)
		}
	}
	return tx.Commit()
}

// loadOccupancy returns the current slots plus a SlotsPerCharacter-sized
// occupancy map, for AddItem's stacking/placement logic.
func (s *SQLStore) loadOccupancy(ctx context.Context, tx *sql.Tx, characterID int64) ([]Slot, [SlotsPerCharacter]bool, error) {
	var occupied [SlotsPerCharacter]bool
	rows, err := tx.QueryContext(ctx,
		fmt.Sprintf(`SELECT slot, item_id, quantity FROM %s WHERE character_id = $1 ORDER BY slot`, s.table),
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
