package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// StallDecorationStore keeps the stall decoration a character's stall shows
// (round 838): the RefObjID of the last stall decoration item it used
// (ITEM_MALL_BOOTH_*, TypeID 3/3/3/4), 0 for none -- the default stall.
//
// READ (SR_GameServer): CGItemExpendable::vslot_307 case 4 (0x49c0bd) hands
// the item's RefObjID to GObjPC::FUN_004a3f10, which writes it to the
// character's CInstanceStaticAvatar record (pc+0x1f20), the `_STATICAVATAR`
// table's Param1 (record +0x1c; the binder at 0x852db4 registers CharID and
// Param1), and queues the UPDATE on DB thread 1. `_AddNewChar` inserts the
// row with the character, so every character has one, Param1 0.
//
// OURS: a column on the characters table rather than a table of its own.
type StallDecorationStore interface {
	// StallDecoration returns characterID's decoration RefObjID, 0 for none.
	StallDecoration(ctx context.Context, characterID int64) (int, error)
	// SetStallDecoration stores it.
	SetStallDecoration(ctx context.Context, characterID int64, refObjID int) error
}

// StallDecoration implements StallDecorationStore.
func (m *MemStore) StallDecoration(_ context.Context, characterID int64) (int, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return 0, ErrNotFound
	}
	return m.stallDeco[characterID], nil
}

// SetStallDecoration implements StallDecorationStore.
func (m *MemStore) SetStallDecoration(_ context.Context, characterID int64, refObjID int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.stallDeco == nil {
		m.stallDeco = make(map[int64]int)
	}
	m.stallDeco[characterID] = refObjID
	return nil
}

// StallDecoration implements StallDecorationStore.
func (s *SQLStore) StallDecoration(ctx context.Context, characterID int64) (int, error) {
	var v int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT stall_decoration FROM characters WHERE id = $1`, characterID).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: reading the stall decoration: %w", err)
	}
	return v, nil
}

// SetStallDecoration implements StallDecorationStore.
func (s *SQLStore) SetStallDecoration(ctx context.Context, characterID int64, refObjID int) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE characters SET stall_decoration = $1 WHERE id = $2`, refObjID, characterID)
	if err != nil {
		return fmt.Errorf("character: saving the stall decoration: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
