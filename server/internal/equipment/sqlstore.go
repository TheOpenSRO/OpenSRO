package equipment

import (
	"context"
	"database/sql"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

const schema = `
CREATE TABLE IF NOT EXISTS equipment_slots (
	character_id BIGINT NOT NULL,
	slot         SMALLINT NOT NULL,
	item_id      BIGINT NOT NULL,
	PRIMARY KEY (character_id, slot)
);
`

// SQLStore is a Store backed by PostgreSQL. Depends on an inventory.Store
// to move items between inventory and equipment.
type SQLStore struct {
	db  *sql.DB
	inv inventory.Store
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string, inv inventory.Store) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("equipment: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("equipment: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("equipment: creating schema: %w", err)
	}
	return &SQLStore{db: db, inv: inv}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// TruncateForTest clears all equipment data, for other packages' tests
// sharing this Postgres instance. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE equipment_slots`)
	return err
}

func validSlot(slot Slot) bool {
	switch slot {
	case SlotWeapon, SlotHelm, SlotMail, SlotShoulderGuard, SlotPants, SlotBoots, SlotShield, SlotExtra:
		return true
	default:
		return false
	}
}

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, characterID int64) ([]Equipped, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT slot, item_id FROM equipment_slots WHERE character_id = $1`, characterID)
	if err != nil {
		return nil, fmt.Errorf("equipment: listing equipped items: %w", err)
	}
	defer rows.Close()

	var out []Equipped
	for rows.Next() {
		var e Equipped
		var slot int
		if err := rows.Scan(&slot, &e.ItemID); err != nil {
			return nil, fmt.Errorf("equipment: scanning row: %w", err)
		}
		e.Slot = Slot(slot)
		out = append(out, e)
	}
	return out, rows.Err()
}

// Equip implements Store.
func (s *SQLStore) Equip(ctx context.Context, characterID int64, slot Slot, inventorySlot int) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}

	invSlots, err := s.inv.List(ctx, characterID)
	if err != nil {
		return fmt.Errorf("equipment: reading inventory: %w", err)
	}
	var newItemID int64 = -1
	for _, sl := range invSlots {
		if sl.Index == inventorySlot {
			newItemID = sl.ItemID
			break
		}
	}
	if newItemID == -1 {
		return ErrInventorySlotEmpty
	}

	// Unequip whatever's currently there first (back to inventory), so we
	// never lose an item by overwriting a populated slot.
	if err := s.unequipIfPresent(ctx, characterID, slot); err != nil {
		return err
	}

	if err := s.inv.RemoveItem(ctx, characterID, inventorySlot, 1); err != nil {
		return fmt.Errorf("equipment: removing item from inventory: %w", err)
	}

	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO equipment_slots (character_id, slot, item_id) VALUES ($1, $2, $3)
		 ON CONFLICT (character_id, slot) DO UPDATE SET item_id = excluded.item_id`,
		characterID, int(slot), newItemID); err != nil {
		return fmt.Errorf("equipment: equipping item: %w", err)
	}
	return nil
}

// Unequip implements Store.
func (s *SQLStore) Unequip(ctx context.Context, characterID int64, slot Slot) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}

	var itemID int64
	err := s.db.QueryRowContext(ctx,
		`SELECT item_id FROM equipment_slots WHERE character_id = $1 AND slot = $2`,
		characterID, int(slot)).Scan(&itemID)
	if err == sql.ErrNoRows {
		return ErrSlotEmpty
	}
	if err != nil {
		return fmt.Errorf("equipment: reading slot: %w", err)
	}

	if err := s.inv.AddItem(ctx, characterID, itemID, 1); err != nil {
		return fmt.Errorf("equipment: returning item to inventory: %w", err)
	}
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM equipment_slots WHERE character_id = $1 AND slot = $2`, characterID, int(slot)); err != nil {
		return fmt.Errorf("equipment: clearing slot: %w", err)
	}
	return nil
}

// unequipIfPresent is like Unequip but treats an empty slot as a no-op,
// for Equip's "clear the slot first" step.
func (s *SQLStore) unequipIfPresent(ctx context.Context, characterID int64, slot Slot) error {
	err := s.Unequip(ctx, characterID, slot)
	if err == ErrSlotEmpty {
		return nil
	}
	return err
}
