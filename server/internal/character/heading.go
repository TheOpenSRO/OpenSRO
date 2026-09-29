package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// HeadingStore keeps the way each character last faced, saved with its
// position under cmd/server's -persist-position so a fresh world entry faces
// the way the character left (round 637's review follow-up). The value is the
// client's heading (world.Entity.Heading: radians in [0, 2 pi)).
//
// OURS: the engine's `_CHAR` declares no heading column (EngineCharColumns:
// LatestRegion and PosX/PosY/PosZ, no angle), and whether or where retail
// keeps a facing across a logout is not read. Kept off Character, as
// InventorySizeStore is, so Character's mapping onto `_CHAR` is unchanged.
type HeadingStore interface {
	// Heading returns characterID's saved heading, 0 when none was saved.
	Heading(ctx context.Context, characterID int64) (float64, error)
	// SetHeading saves characterID's heading.
	SetHeading(ctx context.Context, characterID int64, heading float64) error
}

// Heading implements HeadingStore.
func (m *MemStore) Heading(_ context.Context, characterID int64) (float64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return 0, ErrNotFound
	}
	return m.headings[characterID], nil
}

// SetHeading implements HeadingStore.
func (m *MemStore) SetHeading(_ context.Context, characterID int64, heading float64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.headings == nil {
		m.headings = make(map[int64]float64)
	}
	m.headings[characterID] = heading
	return nil
}

// Heading implements HeadingStore.
func (s *SQLStore) Heading(ctx context.Context, characterID int64) (float64, error) {
	var h float64
	err := s.db.QueryRowContext(ctx, `SELECT heading FROM characters WHERE id = $1`, characterID).Scan(&h)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: reading heading: %w", err)
	}
	return h, nil
}

// SetHeading implements HeadingStore.
func (s *SQLStore) SetHeading(ctx context.Context, characterID int64, heading float64) error {
	res, err := s.db.ExecContext(ctx, `UPDATE characters SET heading = $1 WHERE id = $2`, heading, characterID)
	if err != nil {
		return fmt.Errorf("character: saving heading: %w", err)
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
