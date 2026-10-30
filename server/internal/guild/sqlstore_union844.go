package guild

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
)

// The SQLStore's round 844 union additions (union844.go). The union crest's
// columns are added here, once per store, by the schema code itself (no
// migration): guild_unions.crest (the 256 palette indices, NULL for none)
// and crest_last_rev (the last revision handed out, as the guild's).
const union844Schema = `
ALTER TABLE guild_unions ADD COLUMN IF NOT EXISTS crest BYTEA;
ALTER TABLE guild_unions ADD COLUMN IF NOT EXISTS crest_last_rev BIGINT NOT NULL DEFAULT 0;
`

// union844Ready holds each pool the columns were added on (*sql.DB -> true).
var union844Ready sync.Map

func (s *SQLStore) ensureUnion844(ctx context.Context) error {
	if _, ok := union844Ready.Load(s.db); ok {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, union844Schema); err != nil {
		return fmt.Errorf("guild: the union crest columns: %w", err)
	}
	union844Ready.Store(s.db, true)
	return nil
}

// BreakUnion implements UnionBreaker (the members go with it: ON DELETE
// CASCADE).
func (s *SQLStore) BreakUnion(ctx context.Context, unionID int64) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM guild_unions WHERE id = $1`, unionID); err != nil {
		return fmt.Errorf("guild: breaking the union: %w", err)
	}
	return nil
}

// SetUnionCrest implements UnionCrestStore.
func (s *SQLStore) SetUnionCrest(ctx context.Context, unionID int64, pixels []byte) (uint32, error) {
	if len(pixels) != CrestBytes {
		return 0, fmt.Errorf("guild: a crest is %d bytes, not %d", CrestBytes, len(pixels))
	}
	if err := s.ensureUnion844(ctx); err != nil {
		return 0, err
	}
	var rev int64
	err := s.db.QueryRowContext(ctx,
		`UPDATE guild_unions SET crest = $2, crest_rev = crest_last_rev + 1, crest_last_rev = crest_last_rev + 1
		 WHERE id = $1 RETURNING crest_rev`, unionID, pixels).Scan(&rev)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoSuchUnion
	}
	if err != nil {
		return 0, fmt.Errorf("guild: storing the union crest: %w", err)
	}
	return uint32(rev), nil
}

// ClearUnionCrest implements UnionCrestStore.
func (s *SQLStore) ClearUnionCrest(ctx context.Context, unionID int64) error {
	if err := s.ensureUnion844(ctx); err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `UPDATE guild_unions SET crest = NULL, crest_rev = 0 WHERE id = $1`, unionID)
	if err != nil {
		return fmt.Errorf("guild: deleting the union crest: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoSuchUnion
	}
	return nil
}

// UnionCrest implements UnionCrestStore.
func (s *SQLStore) UnionCrest(ctx context.Context, unionID int64) (uint32, []byte, error) {
	if err := s.ensureUnion844(ctx); err != nil {
		return 0, nil, err
	}
	var rev int64
	var pixels []byte
	err := s.db.QueryRowContext(ctx, `SELECT crest_rev, crest FROM guild_unions WHERE id = $1`, unionID).Scan(&rev, &pixels)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil, ErrNoSuchUnion
	}
	if err != nil {
		return 0, nil, fmt.Errorf("guild: reading the union crest: %w", err)
	}
	if rev == 0 {
		return 0, nil, nil
	}
	return uint32(rev), pixels, nil
}
