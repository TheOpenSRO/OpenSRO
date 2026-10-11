package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/txn"
)

// ReturnPointStore keeps the two places the reverse return scroll can send a
// character back to (round 778, docs/protocol/reverse_return_scroll.md): the
// last recall point and the last death point -- the engine's `_CHAR`
// TelRegion/TelPosX/Y/Z/TelWorldID and DiedRegion/DiedPosX/Y/Z/DiedWorldID.
//
// READ (SR_GameServer): charData +0xcc is the recall point's region word,
// +0xd0/+0xd4/+0xd8 its x, y, z floats and +0xee its world word; +0xdc,
// +0xe0..+0xe8 and +0xf0 the death point's (persistence/schema.go's bind
// offsets name the columns). CGObjPC::SaveCurPosAsLastTelPosition (0x4e0250,
// vtable slot 153) writes the recall point from the character's current
// region (+0x94), position (+0x98..+0xa0) and world (+0xec) -- the ordinary
// return scroll's handler calls it when the scroll is used (0x4a0555) --
// and GObjPC::FUN_004e0330 writes the death point the same way from the
// death path (CGObjPC vslot_306, 0x529b10). The scroll's options 2 and 3
// refuse a region word of 0 (FUN_004e0130 / FUN_004e01c0: 0x1885 / 0x1886).
//
// OURS: kept off Character, as RecallStore is; a point is stored as the
// region id and the region-local (or, in a dungeon, the dungeon-space)
// position the tables use, which the session layer turns into an arrival.
type ReturnPointStore interface {
	// ReturnPoint returns characterID's point of `kind`; Region 0 is none.
	ReturnPoint(ctx context.Context, characterID int64, kind ReturnPointKind) (SavedPoint, error)
	// SetReturnPoint stores it.
	SetReturnPoint(ctx context.Context, characterID int64, kind ReturnPointKind, p SavedPoint) error
}

// ReturnPointKind names which of the two points.
type ReturnPointKind int

const (
	// RecallPoint is TelRegion..: where a return scroll was last used.
	RecallPoint ReturnPointKind = iota
	// DeathPoint is DiedRegion..: where the character last died.
	DeathPoint
)

// SavedPoint is one stored point: Region 0 means none was recorded.
type SavedPoint struct {
	Region  int
	X, Y, Z float64
	WorldID int
}

// Set reports whether a point was recorded.
func (p SavedPoint) Set() bool { return p.Region != 0 }

func (k ReturnPointKind) valid() bool { return k == RecallPoint || k == DeathPoint }

// ReturnPoint implements ReturnPointStore.
func (m *MemStore) ReturnPoint(_ context.Context, characterID int64, kind ReturnPointKind) (SavedPoint, error) {
	if !kind.valid() {
		return SavedPoint{}, fmt.Errorf("character: no return point kind %d", kind)
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return SavedPoint{}, ErrNotFound
	}
	return m.points[[2]int64{characterID, int64(kind)}], nil
}

// SetReturnPoint implements ReturnPointStore.
func (m *MemStore) SetReturnPoint(_ context.Context, characterID int64, kind ReturnPointKind, p SavedPoint) error {
	if !kind.valid() {
		return fmt.Errorf("character: no return point kind %d", kind)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.points == nil {
		m.points = make(map[[2]int64]SavedPoint)
	}
	m.points[[2]int64{characterID, int64(kind)}] = p
	return nil
}

// returnPointColumns are the characters table's columns for a kind.
func returnPointColumns(kind ReturnPointKind) (region, x, y, z, world string) {
	if kind == DeathPoint {
		return "died_region", "died_x", "died_y", "died_z", "died_world"
	}
	return "tel_region", "tel_x", "tel_y", "tel_z", "tel_world"
}

// ReturnPoint implements ReturnPointStore.
func (s *SQLStore) ReturnPoint(ctx context.Context, characterID int64, kind ReturnPointKind) (SavedPoint, error) {
	if !kind.valid() {
		return SavedPoint{}, fmt.Errorf("character: no return point kind %d", kind)
	}
	r, x, y, z, w := returnPointColumns(kind)
	var p SavedPoint
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		fmt.Sprintf(`SELECT %s, %s, %s, %s, %s FROM characters WHERE id = $1`, r, x, y, z, w), characterID).
		Scan(&p.Region, &p.X, &p.Y, &p.Z, &p.WorldID)
	if errors.Is(err, sql.ErrNoRows) {
		return SavedPoint{}, ErrNotFound
	}
	if err != nil {
		return SavedPoint{}, fmt.Errorf("character: reading a return point: %w", err)
	}
	return p, nil
}

// SetReturnPoint implements ReturnPointStore.
func (s *SQLStore) SetReturnPoint(ctx context.Context, characterID int64, kind ReturnPointKind, p SavedPoint) error {
	if !kind.valid() {
		return fmt.Errorf("character: no return point kind %d", kind)
	}
	r, x, y, z, w := returnPointColumns(kind)
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		fmt.Sprintf(`UPDATE characters SET %s = $1, %s = $2, %s = $3, %s = $4, %s = $5 WHERE id = $6`, r, x, y, z, w),
		p.Region, p.X, p.Y, p.Z, p.WorldID, characterID)
	if err != nil {
		return fmt.Errorf("character: saving a return point: %w", err)
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
