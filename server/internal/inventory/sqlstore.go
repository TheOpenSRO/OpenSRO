package inventory

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/durability"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// DefaultTable is the bag's table. A second container (the warehouse) opens
// the same store against a different table via OpenSQLStoreNamed, so all the
// stacking and placement logic is shared rather than duplicated.
const DefaultTable = "inventory_slots"

// WarehouseTable is the warehouse's table, owned by the ACCOUNT
// (WarehouseOwnerColumn). The older per-character table `storage_slots` is
// left in place, read once by storage.MigrateToAccounts and never written
// again.
const WarehouseTable = "account_storage_slots"

// schemaFor returns the CREATE TABLE for a container's table. The table and
// owner-column names are trusted constants (never user input), so
// interpolating them is safe. The owner column is `character_id` for the bag
// and `account_id` for the warehouse -- the game's `_INVENTORY` is keyed by
// CharID and its `_CHEST` by UserJID (docs/protocol/server_sql.md).
func schemaFor(table, owner string) string {
	return fmt.Sprintf(`
CREATE TABLE IF NOT EXISTS %[1]s (
	%[2]s        BIGINT NOT NULL,
	slot         INTEGER NOT NULL,
	item_id      BIGINT NOT NULL,
	quantity     INTEGER NOT NULL,
	variance     BIGINT NOT NULL DEFAULT 0,
	durability   INTEGER NOT NULL DEFAULT -1,
	PRIMARY KEY (%[2]s, slot)
);
ALTER TABLE %[1]s ADD COLUMN IF NOT EXISTS variance BIGINT NOT NULL DEFAULT 0;
ALTER TABLE %[1]s ADD COLUMN IF NOT EXISTS durability INTEGER NOT NULL DEFAULT -1;
`, table, owner)
}

// The per-instance columns. `variance` is the 64-bit white-stat field
// (twelve 5-bit groups; it never uses the sign bit); `durability` is the
// current points, -1 (durability.Untracked) for a row written before this
// existed -- initialised on first read, never read as broken.

// SQLStore is a Store backed by PostgreSQL, consistent with
// account/character/refdata's approach. Needs a MaxStackLookup (in
// production, refdata.SQLStore) to know each item's stack limit. `table` is
// the container's table -- the bag or the warehouse.
type SQLStore struct {
	db           *sql.DB
	maxStacks    MaxStackLookup
	table        string
	owner        string       // the owner column: character_id (bag) or account_id (warehouse)
	capacity     int          // this container's slot count (SlotsPerCharacter unless SetCapacity said otherwise)
	capacityOf   CapacityFunc // per-owner slot counts, when set (SetCapacityFunc)
	reach        heldReach    // keeps slots held past the size reachable (SetKeepHeld)
	durabilities DurabilityLookup
	// Rand is the source the instance rolls draw from; tests set it.
	Rand durability.Rand
}

// q renders one statement for this container: `%s` is the table, and the
// literal column token `character_id` becomes the owner column, so the same
// statements serve the bag (owned by a character) and the warehouse (owned
// by an account).
func (s *SQLStore) q(stmt string) string {
	return strings.ReplaceAll(fmt.Sprintf(stmt, s.table), "character_id", s.owner)
}

// SetDurabilityLookup gives the store the reference data it needs to roll a
// fresh item's variance and durability. Set once, before the store is used.
func (s *SQLStore) SetDurabilityLookup(l DurabilityLookup) { s.durabilities = l }

// OpenSQLStore opens the bag store (the DefaultTable). See OpenSQLStoreNamed
// for a second container.
func OpenSQLStore(dsn string, maxStacks MaxStackLookup) (*SQLStore, error) {
	return OpenSQLStoreNamed(dsn, maxStacks, DefaultTable)
}

// OpenSQLStoreNamed opens a PostgreSQL-backed container using the given table,
// owned by a character (owner column `character_id`), ensuring its schema
// exists. A container owned by something else passes its own column through
// OpenSQLStoreOwned.
func OpenSQLStoreNamed(dsn string, maxStacks MaxStackLookup, table string) (*SQLStore, error) {
	return OpenSQLStoreOwned(dsn, maxStacks, table, DefaultOwnerColumn)
}

// DefaultOwnerColumn is the bag's owner column; the warehouse uses
// WarehouseOwnerColumn because the game keys it by the account.
const (
	DefaultOwnerColumn   = "character_id"
	WarehouseOwnerColumn = "account_id"
)

// OpenSQLStoreOwned opens a PostgreSQL-backed container on `table` whose rows
// belong to whatever id the owner column names. The warehouse is opened this
// way on WarehouseTable with WarehouseOwnerColumn: every character on an
// account shares it, as the game's `_CHEST WHERE UserJID=%d` does.
func OpenSQLStoreOwned(dsn string, maxStacks MaxStackLookup, table, owner string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("inventory: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("inventory: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schemaFor(table, owner)); err != nil {
		db.Close()
		return nil, fmt.Errorf("inventory: creating schema: %w", err)
	}
	return &SQLStore{db: db, maxStacks: maxStacks, table: table, owner: owner, capacity: SlotsPerCharacter}, nil
}

// SetCapacity sets this container's slot count. The bag keeps
// SlotsPerCharacter; the warehouse is opened with storage.DefaultCapacity.
func (s *SQLStore) SetCapacity(n int) {
	if n > 0 {
		s.capacity = n
	}
}

// Capacity implements Store.
func (s *SQLStore) Capacity() int { return s.capacity }

// SetCapacityFunc makes the slot count per owner: every operation on an owner
// is bounded by f's answer for it, falling back to Capacity() when f answers
// zero or less. Set once, before the store is used.
func (s *SQLStore) SetCapacityFunc(f CapacityFunc) { s.capacityOf = f }

// placeCapacityFor is owner's configured slot count, the bound on every NEW
// placement. It is asked outside any transaction of this store's: f may
// reach another table.
func (s *SQLStore) placeCapacityFor(ctx context.Context, owner int64) int {
	if s.capacityOf != nil {
		if n := s.capacityOf(ctx, owner); n > 0 {
			return n
		}
	}
	return s.capacity
}

// capacityFor is owner's reach: placeCapacityFor, raised to the highest held
// slot + 1 under SetKeepHeld -- the bound on reading, removing and moving OUT
// what is already held. Asked outside any transaction, like placeCapacityFor.
func (s *SQLStore) capacityFor(ctx context.Context, owner int64) int {
	return s.reach.raise(ctx, s, owner, s.placeCapacityFor(ctx, owner))
}

// DB exposes the connection for a one-off migration (storage.MigrateToAccounts)
// that has to read this container's rows alongside other tables.
func (s *SQLStore) DB() *sql.DB { return s.db }

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
	_, err := s.db.ExecContext(ctx, s.q(`TRUNCATE TABLE %s`))
	return err
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// List implements Store.
func (s *SQLStore) List(ctx context.Context, characterID int64) ([]Slot, error) {
	rows, err := s.db.QueryContext(ctx,
		s.q(`SELECT slot, item_id, quantity, variance, durability FROM %s WHERE character_id = $1 ORDER BY slot`),
		characterID)
	if err != nil {
		return nil, fmt.Errorf("inventory: listing slots: %w", err)
	}
	defer rows.Close()
	var out []Slot
	var legacy []Slot
	for rows.Next() {
		var sl Slot
		var variance int64
		if err := rows.Scan(&sl.Index, &sl.ItemID, &sl.Quantity, &variance, &sl.Durability); err != nil {
			return nil, fmt.Errorf("inventory: scanning slot: %w", err)
		}
		sl.Variance = uint64(variance)
		changed, err := initLegacy(ctx, s.durabilities, s.Rand, &sl)
		if err != nil {
			return nil, err
		}
		if changed {
			legacy = append(legacy, sl)
		}
		out = append(out, sl)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("inventory: iterating slots: %w", err)
	}
	// Persist the instances legacy rows just received, so the roll happens
	// once and every later read agrees with this one.
	for _, sl := range legacy {
		if _, err := s.db.ExecContext(ctx,
			s.q(`UPDATE %s SET variance = $1, durability = $2 WHERE character_id = $3 AND slot = $4`),
			int64(sl.Variance), sl.Durability, characterID, sl.Index); err != nil {
			return nil, fmt.Errorf("inventory: initialising slot %d: %w", sl.Index, err)
		}
	}
	return out, nil
}

// AddItem implements Store.
func (s *SQLStore) AddItem(ctx context.Context, characterID, itemID int64, quantity int) error {
	if quantity <= 0 {
		return ErrInvalidQuantity
	}
	inst, err := FreshInstance(ctx, s.durabilities, s.Rand, itemID)
	if err != nil {
		return err
	}
	return s.addItem(ctx, characterID, itemID, quantity, inst)
}

// AddItemInstance implements Store: an existing instance moving in.
func (s *SQLStore) AddItemInstance(ctx context.Context, characterID, itemID int64, quantity int, inst Instance) error {
	if quantity <= 0 {
		return ErrInvalidQuantity
	}
	return s.addItem(ctx, characterID, itemID, quantity, inst)
}

// SetDurability implements Store.
func (s *SQLStore) SetDurability(ctx context.Context, characterID int64, slot int, durabilityLeft int) error {
	if slot < 0 || slot >= s.capacityFor(ctx, characterID) {
		return ErrInvalidSlot
	}
	res, err := s.db.ExecContext(ctx,
		s.q(`UPDATE %s SET durability = $1 WHERE character_id = $2 AND slot = $3`),
		durabilityLeft, characterID, slot)
	if err != nil {
		return fmt.Errorf("inventory: setting durability of slot %d: %w", slot, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrSlotEmpty
	}
	return nil
}

func (s *SQLStore) addItem(ctx context.Context, characterID, itemID int64, quantity int, inst Instance) error {
	maxStack, err := s.maxStacks.GetMaxStack(ctx, itemID)
	if err != nil {
		return fmt.Errorf("inventory: looking up max stack for item %d: %w", itemID, err)
	}
	if maxStack <= 0 {
		maxStack = 1 // an item with no configured stack limit doesn't stack
	}
	// New items go only within the configured size, never into the slots a
	// held item keeps reachable past it (SetKeepHeld).
	capacity := s.placeCapacityFor(ctx, characterID)

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	existing, occupied, err := s.loadOccupancy(ctx, tx, characterID, capacity)
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
		if sl.Index >= capacity || sl.ItemID != itemID || sl.Quantity >= maxStack {
			continue
		}
		room := maxStack - sl.Quantity
		add := min(room, remaining)
		if _, err := tx.ExecContext(ctx,
			s.q(`UPDATE %s SET quantity = quantity + $1 WHERE character_id = $2 AND slot = $3`),
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
			s.q(`INSERT INTO %s (character_id, slot, item_id, quantity, variance, durability) VALUES ($1, $2, $3, $4, $5, $6)`),
			characterID, slotIdx, itemID, add, int64(inst.Variance), inst.Durability); err != nil {
			return fmt.Errorf("inventory: inserting into slot %d: %w", slotIdx, err)
		}
		remaining -= add
	}

	return tx.Commit()
}

// RemoveItem implements Store.
func (s *SQLStore) RemoveItem(ctx context.Context, characterID int64, slot int, quantity int) error {
	if slot < 0 || slot >= s.capacityFor(ctx, characterID) {
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
		s.q(`SELECT quantity FROM %s WHERE character_id = $1 AND slot = $2`),
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
			s.q(`DELETE FROM %s WHERE character_id = $1 AND slot = $2`), characterID, slot); err != nil {
			return fmt.Errorf("inventory: clearing slot %d: %w", slot, err)
		}
	} else {
		if _, err := tx.ExecContext(ctx,
			s.q(`UPDATE %s SET quantity = quantity - $1 WHERE character_id = $2 AND slot = $3`),
			quantity, characterID, slot); err != nil {
			return fmt.Errorf("inventory: decrementing slot %d: %w", slot, err)
		}
	}
	return tx.Commit()
}

// MoveItem implements Store. See the interface for the three outcomes. One
// transaction, so a swap can never be observed half-done.
//
// `from` may be any reachable slot; `to` must be within the configured size,
// and a slot held past it (SetKeepHeld) may be emptied or merged from but not
// swapped into -- a swap would place the other item there.
func (s *SQLStore) MoveItem(ctx context.Context, characterID int64, from, to int) error {
	reach := s.capacityFor(ctx, characterID)
	place := s.placeCapacityFor(ctx, characterID)
	if from < 0 || from >= reach || to < 0 || to >= place {
		return ErrInvalidSlot
	}
	if from == to {
		return nil
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	type row struct {
		itemID     int64
		qty        int
		variance   int64
		durability int
	}
	readSlot := func(slot int) (r row, found bool, err error) {
		err = tx.QueryRowContext(ctx,
			s.q(`SELECT item_id, quantity, variance, durability FROM %s WHERE character_id = $1 AND slot = $2`),
			characterID, slot).Scan(&r.itemID, &r.qty, &r.variance, &r.durability)
		if err == sql.ErrNoRows {
			return row{}, false, nil
		}
		if err != nil {
			return row{}, false, fmt.Errorf("inventory: reading slot %d: %w", slot, err)
		}
		return r, true, nil
	}
	src, srcFound, err := readSlot(from)
	if err != nil {
		return err
	}
	if !srcFound {
		return ErrSlotEmpty
	}
	srcItem, srcQty := src.itemID, src.qty
	dst, dstFound, err := readSlot(to)
	dstItem, dstQty := dst.itemID, dst.qty
	if err != nil {
		return err
	}
	space := 0
	if dstFound && dstItem == srcItem {
		space = s.mergeSpace(ctx, srcItem, dstQty)
	}

	switch {
	case !dstFound:
		// Plain move into a free slot.
		if _, err := tx.ExecContext(ctx,
			s.q(`UPDATE %s SET slot = $1 WHERE character_id = $2 AND slot = $3`),
			to, characterID, from); err != nil {
			return fmt.Errorf("inventory: moving slot %d to %d: %w", from, to, err)
		}
	case space > 0:
		// Same item with room: merge what fits, the rest stays behind.
		moved := min(space, srcQty)
		if _, err := tx.ExecContext(ctx,
			s.q(`UPDATE %s SET quantity = quantity + $1 WHERE character_id = $2 AND slot = $3`),
			moved, characterID, to); err != nil {
			return fmt.Errorf("inventory: merging into slot %d: %w", to, err)
		}
		if moved == srcQty {
			if _, err := tx.ExecContext(ctx,
				s.q(`DELETE FROM %s WHERE character_id = $1 AND slot = $2`), characterID, from); err != nil {
				return fmt.Errorf("inventory: clearing slot %d: %w", from, err)
			}
		} else if _, err := tx.ExecContext(ctx,
			s.q(`UPDATE %s SET quantity = quantity - $1 WHERE character_id = $2 AND slot = $3`),
			moved, characterID, from); err != nil {
			return fmt.Errorf("inventory: decrementing slot %d: %w", from, err)
		}
	case from >= place:
		// A swap would put the other item into a slot past the size.
		return ErrInvalidSlot
	default:
		// Swap. (character_id, slot) is the primary key, so the two rows are
		// rewritten rather than renumbered past each other.
		if _, err := tx.ExecContext(ctx,
			s.q(`DELETE FROM %s WHERE character_id = $1 AND slot IN ($2, $3)`),
			characterID, from, to); err != nil {
			return fmt.Errorf("inventory: swapping slots %d and %d: %w", from, to, err)
		}
		if _, err := tx.ExecContext(ctx,
			s.q(`INSERT INTO %s (character_id, slot, item_id, quantity, variance, durability) VALUES ($1, $2, $3, $4, $5, $6), ($1, $7, $8, $9, $10, $11)`),
			characterID, to, srcItem, srcQty, src.variance, src.durability, from, dstItem, dstQty, dst.variance, dst.durability); err != nil {
			return fmt.Errorf("inventory: swapping slots %d and %d: %w", from, to, err)
		}
	}
	return tx.Commit()
}

// mergeSpace is how many more of itemID a slot already holding `have` can
// take -- zero for an item that does not stack, or whose limit the lookup
// cannot answer (a failed lookup means "do not merge", which falls through
// to a swap rather than to a lost item).
func (s *SQLStore) mergeSpace(ctx context.Context, itemID int64, have int) int {
	limit, err := s.maxStacks.GetMaxStack(ctx, itemID)
	if err != nil || limit <= 1 {
		return 0
	}
	return limit - have
}

// loadOccupancy returns the current slots plus a capacity-sized occupancy
// map, for AddItem's stacking/placement logic. capacity is the owner's own
// (capacityFor), read before the transaction began.
func (s *SQLStore) loadOccupancy(ctx context.Context, tx *sql.Tx, characterID int64, capacity int) ([]Slot, []bool, error) {
	occupied := make([]bool, capacity)
	rows, err := tx.QueryContext(ctx,
		s.q(`SELECT slot, item_id, quantity FROM %s WHERE character_id = $1 ORDER BY slot`),
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
		if sl.Index >= 0 && sl.Index < capacity {
			occupied[sl.Index] = true
		}
		out = append(out, sl)
	}
	return out, occupied, rows.Err()
}

func firstFree(occupied []bool) int {
	for i, taken := range occupied {
		if !taken {
			return i
		}
	}
	return -1
}
