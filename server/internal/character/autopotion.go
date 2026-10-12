package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/txn"
)

// AutoPotionStore keeps each character's auto potion settings (round 786):
// the three rows of the Auto potion window (HP, MP, abnormal status) and the
// potion use delay.
//
// READ (docs/protocol/auto_potion.md): retail keeps them on the SERVER. The
// client's CAutoPotion::Send (0x82d2e0) sends packet 0x7158 {u8 2, u16 hp,
// u16 mp, u16 abnormal, u8 delay} when Confirm changed anything; the game
// server's 0x7158 handler GObjPC::FUN_00518c20 hands type 2 to FUN_00407ee0,
// which stores the words, as they came, in the character's _ClientConfig
// record (DB_Bind__ClientConfig 0x85c590: CharID, ConfigType, SlotSeq,
// SlotType ...); and the character data the client reads at entry carries
// them back (0x8ab0e0 -> 0x8a7bd0, the same three words and byte). The server
// checks nothing in them. So the store keeps the client's seven bytes as they
// are -- AutoPotionSize of them, no length means "never set" -- and
// the client applies retail's defaults to an all-zero delay byte itself
// (0x8a7c0d..0x8a7c44).
//
// OURS: one BYTEA column on the characters table, not a _ClientConfig table.
// Kept off Character, as RecallStore and HeadingStore are.
type AutoPotionStore interface {
	// AutoPotion returns characterID's settings, nil when none were saved.
	AutoPotion(ctx context.Context, characterID int64) ([]byte, error)
	// SetAutoPotion saves characterID's settings (AutoPotionSize bytes).
	SetAutoPotion(ctx context.Context, characterID int64, settings []byte) error
}

// AutoPotionSize is the settings' length: three u16 rows and the delay byte.
const AutoPotionSize = 7

// ErrBadAutoPotion is a SetAutoPotion whose settings are not AutoPotionSize
// bytes.
var ErrBadAutoPotion = errors.New("character: auto potion settings must be 7 bytes")

// AutoPotion implements AutoPotionStore.
func (m *MemStore) AutoPotion(_ context.Context, characterID int64) ([]byte, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return nil, ErrNotFound
	}
	v := m.autoPotion[characterID]
	if v == nil {
		return nil, nil
	}
	return append([]byte(nil), v...), nil
}

// SetAutoPotion implements AutoPotionStore.
func (m *MemStore) SetAutoPotion(_ context.Context, characterID int64, settings []byte) error {
	if len(settings) != AutoPotionSize {
		return ErrBadAutoPotion
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if m.autoPotion == nil {
		m.autoPotion = make(map[int64][]byte)
	}
	m.autoPotion[characterID] = append([]byte(nil), settings...)
	return nil
}

// AutoPotion implements AutoPotionStore.
func (s *SQLStore) AutoPotion(ctx context.Context, characterID int64) ([]byte, error) {
	var v []byte
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT auto_potion FROM characters WHERE id = $1`, characterID).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("character: reading the auto potion settings: %w", err)
	}
	if len(v) != AutoPotionSize {
		return nil, nil
	}
	return v, nil
}

// SetAutoPotion implements AutoPotionStore.
func (s *SQLStore) SetAutoPotion(ctx context.Context, characterID int64, settings []byte) error {
	if len(settings) != AutoPotionSize {
		return ErrBadAutoPotion
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE characters SET auto_potion = $1 WHERE id = $2`, settings, characterID)
	if err != nil {
		return fmt.Errorf("character: saving the auto potion settings: %w", err)
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
