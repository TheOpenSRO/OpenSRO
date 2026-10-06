package equipment

import (
	"context"
	"database/sql"
	"fmt"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

const schema = `
CREATE TABLE IF NOT EXISTS equipment_slots (
	character_id BIGINT NOT NULL,
	slot         SMALLINT NOT NULL,
	item_id      BIGINT NOT NULL,
	variance     BIGINT NOT NULL DEFAULT 0,
	durability   INTEGER NOT NULL DEFAULT -1,
	PRIMARY KEY (character_id, slot)
);
ALTER TABLE equipment_slots ADD COLUMN IF NOT EXISTS variance BIGINT NOT NULL DEFAULT 0;
ALTER TABLE equipment_slots ADD COLUMN IF NOT EXISTS durability INTEGER NOT NULL DEFAULT -1;
ALTER TABLE equipment_slots ADD COLUMN IF NOT EXISTS opt_level SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE equipment_slots ADD COLUMN IF NOT EXISTS mag_params BYTEA NOT NULL DEFAULT ''::bytea;
ALTER TABLE equipment_slots ADD COLUMN IF NOT EXISTS adv_elixir SMALLINT NOT NULL DEFAULT 0;
`

// SQLStore is a Store backed by PostgreSQL. Depends on an inventory.Store
// to move items between inventory and equipment.
type SQLStore struct {
	db        *sql.DB
	inv       inventory.Store
	rollFresh func(ctx context.Context, itemID int64) (inventory.Instance, error)
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
	case SlotHelm, SlotMail, SlotShoulderGuard, SlotGauntlet, SlotPants, SlotBoots, SlotWeapon, SlotShield, SlotJobSuit,
		SlotEarring, SlotNecklace, SlotRingLeft, SlotRingRight:
		return true
	default:
		return false
	}
}

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, characterID int64) ([]Equipped, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT slot, item_id, variance, durability, opt_level, mag_params, adv_elixir FROM equipment_slots WHERE character_id = $1`, characterID)
	if err != nil {
		return nil, fmt.Errorf("equipment: listing equipped items: %w", err)
	}
	defer rows.Close()

	var out []Equipped
	for rows.Next() {
		var e Equipped
		var slot int
		var variance int64
		var opt, adv int
		var params []byte
		if err := rows.Scan(&slot, &e.ItemID, &variance, &e.Durability, &opt, &params, &adv); err != nil {
			return nil, fmt.Errorf("equipment: scanning row: %w", err)
		}
		e.Slot = Slot(slot)
		e.Variance = uint64(variance)
		e.OptLevel, e.MagParams, e.AdvElixir = uint8(opt), inventory.DecodeMagParams(params), uint8(adv)
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// A worn row from before durability existed gets its instance on first
	// read, the same way the bag does (inventory.SQLStore.List), so that no
	// sword already on a character reads as broken.
	for i := range out {
		if out[i].Durability != durability.Untracked || s.rollFresh == nil {
			continue
		}
		inst, err := s.rollFresh(ctx, out[i].ItemID)
		if err != nil {
			return nil, err
		}
		if inst.Durability == durability.Untracked {
			continue
		}
		out[i].Variance, out[i].Durability = inst.Variance, inst.Durability
		if _, err := s.db.ExecContext(ctx,
			`UPDATE equipment_slots SET variance = $1, durability = $2 WHERE character_id = $3 AND slot = $4`,
			int64(inst.Variance), inst.Durability, characterID, int(out[i].Slot)); err != nil {
			return nil, fmt.Errorf("equipment: initialising slot %d: %w", out[i].Slot, err)
		}
	}
	return out, nil
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
	var incoming *inventory.Slot
	for i := range invSlots {
		if invSlots[i].Index == inventorySlot {
			incoming = &invSlots[i]
			break
		}
	}
	if incoming == nil {
		return ErrInventorySlotEmpty
	}

	// A swap, as retail's CGObjPC::AttachEquipItem (0x00524cd0) does it
	// with CGStorage::SwapItem(bag, worn) (round 652, READ): the incoming
	// item leaves the bag first, then whatever was worn goes back (never
	// lost) into the bag slot it left.
	if err := s.inv.RemoveItem(ctx, characterID, inventorySlot, 1); err != nil {
		return fmt.Errorf("equipment: removing item from inventory: %w", err)
	}
	before, _ := s.inv.List(ctx, characterID)
	displaced := wornItemID(ctx, s, characterID, slot)
	if err := s.unequipIfPresent(ctx, characterID, slot); err != nil {
		putBack(ctx, s.inv, characterID, *incoming)
		return err
	}
	if displaced >= 0 {
		after, _ := s.inv.List(ctx, characterID)
		settleInto(ctx, s.inv, characterID, landedIndex(before, after, displaced), inventorySlot)
	}

	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO equipment_slots (character_id, slot, item_id, variance, durability, opt_level, mag_params, adv_elixir) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		 ON CONFLICT (character_id, slot) DO UPDATE SET item_id = excluded.item_id, variance = excluded.variance, durability = excluded.durability,
		   opt_level = excluded.opt_level, mag_params = excluded.mag_params, adv_elixir = excluded.adv_elixir`,
		characterID, int(slot), incoming.ItemID, int64(incoming.Variance), incoming.Durability,
		int(incoming.OptLevel), inventory.EncodeMagParams(incoming.MagParams), int(incoming.AdvElixir)); err != nil {
		return fmt.Errorf("equipment: equipping item: %w", err)
	}
	return nil
}

// Unequip implements Store.
func (s *SQLStore) Unequip(ctx context.Context, characterID int64, slot Slot) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}

	var itemID, variance int64
	var dura, opt, adv int
	var params []byte
	err := s.db.QueryRowContext(ctx,
		`SELECT item_id, variance, durability, opt_level, mag_params, adv_elixir FROM equipment_slots WHERE character_id = $1 AND slot = $2`,
		characterID, int(slot)).Scan(&itemID, &variance, &dura, &opt, &params, &adv)
	if err == sql.ErrNoRows {
		return ErrSlotEmpty
	}
	if err != nil {
		return fmt.Errorf("equipment: reading slot: %w", err)
	}

	if err := s.inv.AddItemInstance(ctx, characterID, itemID, 1, inventory.Instance{Variance: uint64(variance), Durability: dura,
		OptLevel: uint8(opt), MagParams: inventory.DecodeMagParams(params), AdvElixir: uint8(adv)}); err != nil {
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
// SetDurability implements Store.
func (s *SQLStore) SetDurability(ctx context.Context, characterID int64, slot Slot, durabilityLeft int) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE equipment_slots SET durability = $1 WHERE character_id = $2 AND slot = $3`,
		durabilityLeft, characterID, int(slot))
	if err != nil {
		return fmt.Errorf("equipment: setting durability of slot %d: %w", slot, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrSlotEmpty
	}
	return nil
}

// SetInstance implements InstanceSetter.
func (s *SQLStore) SetInstance(ctx context.Context, characterID int64, slot Slot, inst inventory.Instance) error {
	if !validSlot(slot) {
		return ErrInvalidSlot
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE equipment_slots SET variance = $1, durability = $2, opt_level = $3, mag_params = $4, adv_elixir = $5
		 WHERE character_id = $6 AND slot = $7`,
		int64(inst.Variance), inst.Durability, int(inst.OptLevel), inventory.EncodeMagParams(inst.MagParams), int(inst.AdvElixir),
		characterID, int(slot))
	if err != nil {
		return fmt.Errorf("equipment: setting the instance of slot %d: %w", slot, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrSlotEmpty
	}
	return nil
}

// SetFreshInstanceRoller gives the store a way to initialise worn rows
// written before durability existed: the same roll the bag store makes for
// a new item. Optional; without it legacy worn rows stay Untracked.
func (s *SQLStore) SetFreshInstanceRoller(roll func(ctx context.Context, itemID int64) (inventory.Instance, error)) {
	s.rollFresh = roll
}

func (s *SQLStore) unequipIfPresent(ctx context.Context, characterID int64, slot Slot) error {
	err := s.Unequip(ctx, characterID, slot)
	if err == ErrSlotEmpty {
		return nil
	}
	return err
}
