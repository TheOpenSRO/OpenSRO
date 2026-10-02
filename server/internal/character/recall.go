package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// RecallStore keeps each character's designated return point (round 686): the
// engine's `_CHAR.AppointedTeleport` (charData +0xa4, db_bind_offsets.tsv),
// which a town gate's "Designate as return/recall point" line sets and the
// return-point revive reads.
//
// READ (docs/protocol/teleport_network.md, "The return point (round 686)"):
//   - the value is a REF OBJECT id, the gate building's: the designate handler
//     (dispatch 0x059, GObjPC_HandleDesignateRecallMsg_059) compares the
//     talked-to gate's IGObj::GetRefObjID (vslot 1, `call [edx+0x4]` at
//     0x5134d8) with charData +0xa4 and writes it through
//     CharData_SetAppointedTeleport (0x51db20) when they differ;
//   - CGObjPC::ResolveRevivePoint (0x4e08a0) looks it up as a ref object and
//     takes that object's teleport record's point.
//
// OURS: 0 stands for "none designated", the character's race's gate
// (session's return point resolves it). Retail never stores 0 for a living
// character -- SR_ShardManager's FUN_0042bb20 hands `_AddNewChar` the race's
// STORE_CH_GATE / STORE_EU_GATE id at creation -- but srrevamp's tables are
// the operator's export, so the id is looked up by the gate's code when it is
// needed rather than written into rows. Kept off Character, as
// InventorySizeStore and HeadingStore are, so Character's mapping onto
// `_CHAR` and its SELECTs are unchanged.
type RecallStore interface {
	// AppointedTeleport returns characterID's designated gate (a teleport
	// building's ref object id), 0 when none was designated.
	AppointedTeleport(ctx context.Context, characterID int64) (int64, error)
	// SetAppointedTeleport stores characterID's designated gate.
	SetAppointedTeleport(ctx context.Context, characterID int64, objectID int64) error
}

// AppointedTeleport implements RecallStore.
func (m *MemStore) AppointedTeleport(_ context.Context, characterID int64) (int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return 0, ErrNotFound
	}
	return m.appointed[characterID], nil
}

// SetAppointedTeleport implements RecallStore.
func (m *MemStore) SetAppointedTeleport(_ context.Context, characterID int64, objectID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.appointed == nil {
		m.appointed = make(map[int64]int64)
	}
	m.appointed[characterID] = objectID
	return nil
}

// AppointedTeleport implements RecallStore.
func (s *SQLStore) AppointedTeleport(ctx context.Context, characterID int64) (int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `SELECT appointed_teleport FROM characters WHERE id = $1`, characterID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: reading the appointed teleport: %w", err)
	}
	return id, nil
}

// SetAppointedTeleport implements RecallStore.
func (s *SQLStore) SetAppointedTeleport(ctx context.Context, characterID int64, objectID int64) error {
	res, err := s.db.ExecContext(ctx, `UPDATE characters SET appointed_teleport = $1 WHERE id = $2`, objectID, characterID)
	if err != nil {
		return fmt.Errorf("character: saving the appointed teleport: %w", err)
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
