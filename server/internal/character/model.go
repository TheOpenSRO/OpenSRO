package character

import (
	"context"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// ModelStore changes a character's body: the skin change scroll's write
// (round 838). READ (SR_GameServer, GObjPC::UpdateCharRefObjIDAndScale
// 0x4efe50): the engine sets chardata +0x28 (RefObjID) and +0x64 (Scale) and
// runs `UPDATE _CHAR SET REFOBJID = %d, SCALE = %d WHERE CHARID = %d`
// (0xaf5858). OpenSRO keeps the Gender string beside the model (Gender's
// comment), so the write carries the new model's Gender too.
type ModelStore interface {
	// SetModel stores characterID's body, scale byte and the Gender string
	// that goes with the body. Returns ErrNotFound if no such character.
	SetModel(ctx context.Context, characterID, refObjID int64, scale int, gender string) error
}

// SetModel implements ModelStore.
func (m *MemStore) SetModel(_ context.Context, characterID, refObjID int64, scale int, gender string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.byID[characterID]
	if !ok {
		return ErrNotFound
	}
	c.RefObjID, c.Scale, c.Gender = refObjID, scale, gender
	return nil
}

// SetModel implements ModelStore.
func (s *SQLStore) SetModel(ctx context.Context, characterID, refObjID int64, scale int, gender string) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET ref_obj_id = $1, scale = $2, gender = $3 WHERE id = $4`,
		refObjID, scale, gender, characterID)
	if err != nil {
		return fmt.Errorf("character: setting the model: %w", err)
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
