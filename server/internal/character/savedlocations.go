package character

import (
	"context"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// SavedLocationSlots is how many saved locations a character keeps for the
// special reverse return scroll's fifth option (round 838). OURS: the
// archive's add-on texts ("Setting Location: Register current location...",
// "Empty Slot", "Do you confirm updating this slot?") show numbered slots but
// not how many; the add-on is packed.
const SavedLocationSlots = 5

// SavedLocationStore keeps a character's saved locations (round 838, OURS:
// ITEM_MALL_REVERSE_RETURN_SCROLL_SPECIAL's "5. Move to a previously saved
// location", a private server's add-on with no counterpart in the engine).
// A slot's point is stored as ReturnPointStore's are; Region 0 is an empty
// slot.
type SavedLocationStore interface {
	// SavedLocations returns characterID's SavedLocationSlots points, in
	// slot order.
	SavedLocations(ctx context.Context, characterID int64) ([]SavedPoint, error)
	// SetSavedLocation stores slot's point (0..SavedLocationSlots-1).
	SetSavedLocation(ctx context.Context, characterID int64, slot int, p SavedPoint) error
}

func validSavedSlot(slot int) bool { return slot >= 0 && slot < SavedLocationSlots }

// SavedLocations implements SavedLocationStore.
func (m *MemStore) SavedLocations(_ context.Context, characterID int64) ([]SavedPoint, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return nil, ErrNotFound
	}
	out := make([]SavedPoint, SavedLocationSlots)
	for i := range out {
		out[i] = m.savedLocs[[2]int64{characterID, int64(i)}]
	}
	return out, nil
}

// SetSavedLocation implements SavedLocationStore.
func (m *MemStore) SetSavedLocation(_ context.Context, characterID int64, slot int, p SavedPoint) error {
	if !validSavedSlot(slot) {
		return fmt.Errorf("character: no saved location slot %d", slot)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.savedLocs == nil {
		m.savedLocs = make(map[[2]int64]SavedPoint)
	}
	m.savedLocs[[2]int64{characterID, int64(slot)}] = p
	return nil
}

// SavedLocations implements SavedLocationStore.
func (s *SQLStore) SavedLocations(ctx context.Context, characterID int64) ([]SavedPoint, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx,
		`SELECT slot, region, x, y, z, world FROM character_saved_locations WHERE character_id = $1`, characterID)
	if err != nil {
		return nil, fmt.Errorf("character: reading saved locations: %w", err)
	}
	defer rows.Close()
	out := make([]SavedPoint, SavedLocationSlots)
	for rows.Next() {
		var slot int
		var p SavedPoint
		if err := rows.Scan(&slot, &p.Region, &p.X, &p.Y, &p.Z, &p.WorldID); err != nil {
			return nil, fmt.Errorf("character: reading saved locations: %w", err)
		}
		if validSavedSlot(slot) {
			out[slot] = p
		}
	}
	return out, rows.Err()
}

// SetSavedLocation implements SavedLocationStore.
func (s *SQLStore) SetSavedLocation(ctx context.Context, characterID int64, slot int, p SavedPoint) error {
	if !validSavedSlot(slot) {
		return fmt.Errorf("character: no saved location slot %d", slot)
	}
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`INSERT INTO character_saved_locations (character_id, slot, region, x, y, z, world)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 ON CONFLICT (character_id, slot) DO UPDATE SET region = excluded.region, x = excluded.x,
		   y = excluded.y, z = excluded.z, world = excluded.world`,
		characterID, slot, p.Region, p.X, p.Y, p.Z, p.WorldID); err != nil {
		return fmt.Errorf("character: saving a saved location: %w", err)
	}
	return nil
}
