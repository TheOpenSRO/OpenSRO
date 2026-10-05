package inventory

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// Splitting a stack (round 728).
//
// READ in the client (sro_client.exe): Shift+click on a stack of more than one
// opens MsgBoxDivideCount (`IFSlotWithHelp::FUN_006b3fa0`, mode 5), its edit
// prefilled "1" (0xd87bdc) and bounded at count - 1 (`0x634f20(count - 1)`).
// Its OK (`FUN_006b62d0`) finds the bag's FIRST EMPTY slot (`FUN_006b6280`)
// and sends the move request bag -> bag with the typed count
// (`FUN_007950b0(0x46, src, 0x46, that slot, count)`); with no empty slot it
// sends nothing. So a split always lands in an empty slot, chosen by the
// client.
//
// The server's bag -> bag (gs:0x4b2450, READ, r728_review.md F9): a count
// below 1 refuses 0x1829, an empty source 0x1809; into an empty slot the
// whole stack moves, a count above it refuses 0x1814, a smaller one splits
// (CGStorage::SplitItemTo). The session's 0x7034 type 0 (session/itemop.go)
// applies those; SplitItem is the split itself.

// ErrSplitCount is returned when a split's count is not in 1..stack-1.
var ErrSplitCount = errors.New("inventory: split count must be less than the stack")

// ErrSlotTaken is returned when a split's destination is not empty.
var ErrSlotTaken = errors.New("inventory: destination slot is not empty")

// Splitter is a Store that can split a stack into an empty slot: count of
// `from`'s stack moves to `to`, which must be empty, the rest stays; the new
// stack keeps the instance. Implemented by MemStore and SQLStore.
type Splitter interface {
	SplitItem(ctx context.Context, characterID int64, from, to, count int) error
}

// SplitItem implements Splitter.
func (m *MemStore) SplitItem(ctx context.Context, characterID int64, from, to, count int) error {
	reach := m.capacityFor(ctx, characterID)
	place := m.placeCapacityFor(ctx, characterID)
	if from < 0 || from >= reach || to < 0 || to >= place || from == to {
		return ErrInvalidSlot
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	held := m.slots[characterID]
	src := held[from]
	if src == nil {
		return ErrSlotEmpty
	}
	if held[to] != nil {
		return ErrSlotTaken
	}
	if count <= 0 || count >= src.Quantity {
		return ErrSplitCount
	}
	part := *src
	part.Index = to
	part.Quantity = count
	src.Quantity -= count
	held[to] = &part
	return nil
}

// SplitItem implements Splitter, in one transaction.
func (s *SQLStore) SplitItem(ctx context.Context, characterID int64, from, to, count int) error {
	reach := s.capacityFor(ctx, characterID)
	place := s.placeCapacityFor(ctx, characterID)
	if from < 0 || from >= reach || to < 0 || to >= place || from == to {
		return ErrInvalidSlot
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	var itemID int64
	var qty, durability int
	var variance int64
	err = tx.QueryRowContext(ctx,
		s.q(`SELECT item_id, quantity, variance, durability FROM %s WHERE character_id = $1 AND slot = $2`),
		characterID, from).Scan(&itemID, &qty, &variance, &durability)
	if err == sql.ErrNoRows {
		return ErrSlotEmpty
	}
	if err != nil {
		return fmt.Errorf("inventory: reading slot %d: %w", from, err)
	}
	var taken int
	if err := tx.QueryRowContext(ctx,
		s.q(`SELECT COUNT(*) FROM %s WHERE character_id = $1 AND slot = $2`), characterID, to).Scan(&taken); err != nil {
		return fmt.Errorf("inventory: reading slot %d: %w", to, err)
	}
	if taken > 0 {
		return ErrSlotTaken
	}
	if count <= 0 || count >= qty {
		return ErrSplitCount
	}
	if _, err := tx.ExecContext(ctx,
		s.q(`UPDATE %s SET quantity = quantity - $1 WHERE character_id = $2 AND slot = $3`),
		count, characterID, from); err != nil {
		return fmt.Errorf("inventory: decrementing slot %d: %w", from, err)
	}
	if _, err := tx.ExecContext(ctx,
		s.q(`INSERT INTO %s (character_id, slot, item_id, quantity, variance, durability) VALUES ($1, $2, $3, $4, $5, $6)`),
		characterID, to, itemID, count, variance, durability); err != nil {
		return fmt.Errorf("inventory: filling slot %d: %w", to, err)
	}
	return tx.Commit()
}

// Placer is a Store that can put an item instance into one named EMPTY slot,
// never merging (round 728's review: the retail buy back, GObjPC 0x42aae0,
// takes CGStorage::FindFirstEmptySlot and SetItem -- READ). Implemented by
// MemStore and SQLStore.
type Placer interface {
	PlaceItemInstance(ctx context.Context, characterID int64, slot int, itemID int64, quantity int, inst Instance) error
	PlacementCapacityFor(ctx context.Context, owner int64) int
}

// FirstEmptySlot is the lowest slot below the placement capacity that holds
// nothing, or -1 when the bag is full.
func FirstEmptySlot(ctx context.Context, st Store, p Placer, characterID int64) (int, error) {
	held, err := st.List(ctx, characterID)
	if err != nil {
		return -1, err
	}
	taken := make(map[int]bool, len(held))
	for _, s := range held {
		taken[s.Index] = true
	}
	for i := 0; i < p.PlacementCapacityFor(ctx, characterID); i++ {
		if !taken[i] {
			return i, nil
		}
	}
	return -1, nil
}

// PlaceItemInstance implements Placer.
func (m *MemStore) PlaceItemInstance(ctx context.Context, characterID int64, slot int, itemID int64, quantity int, inst Instance) error {
	if slot < 0 || slot >= m.placeCapacityFor(ctx, characterID) || quantity <= 0 {
		return ErrInvalidSlot
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	held := m.slots[characterID]
	if held == nil {
		held = make(map[int]*Slot)
		m.slots[characterID] = held
	}
	if held[slot] != nil {
		return ErrSlotTaken
	}
	held[slot] = &Slot{Index: slot, ItemID: itemID, Quantity: quantity, Variance: inst.Variance, Durability: inst.Durability}
	return nil
}

// PlaceItemInstance implements Placer.
func (s *SQLStore) PlaceItemInstance(ctx context.Context, characterID int64, slot int, itemID int64, quantity int, inst Instance) error {
	if slot < 0 || slot >= s.placeCapacityFor(ctx, characterID) || quantity <= 0 {
		return ErrInvalidSlot
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("inventory: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	var taken int
	if err := tx.QueryRowContext(ctx,
		s.q(`SELECT COUNT(*) FROM %s WHERE character_id = $1 AND slot = $2`), characterID, slot).Scan(&taken); err != nil {
		return fmt.Errorf("inventory: reading slot %d: %w", slot, err)
	}
	if taken > 0 {
		return ErrSlotTaken
	}
	if _, err := tx.ExecContext(ctx,
		s.q(`INSERT INTO %s (character_id, slot, item_id, quantity, variance, durability) VALUES ($1, $2, $3, $4, $5, $6)`),
		characterID, slot, itemID, quantity, int64(inst.Variance), inst.Durability); err != nil {
		return fmt.Errorf("inventory: filling slot %d: %w", slot, err)
	}
	return tx.Commit()
}
