package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// LobbyStore is what the character lobby needs beyond Store (round 682,
// docs/protocol/charselect.md): a create that takes the body, scale and start
// spawn the player chose, a name lookup for the name check, and the 7-day soft
// delete with its restore and purge. Both MemStore and SQLStore implement it.
type LobbyStore interface {
	// CreateCharacter adds nc to accountID. ErrNameTaken and ErrAccountFull
	// as Store.Create; the count includes characters pending deletion (they
	// are still on the account, as the select screen shows).
	CreateCharacter(ctx context.Context, accountID int64, nc NewCharacter) (*Character, error)
	// NameTaken reports whether any character, on any account and pending
	// deletion or not, already has name (compared without case). READ round
	// 692: `_IsExistingCharName` looks the name up in `_CharNameList` (every
	// character's name, pending ones included) and in `_CharNickNameList`
	// with `=`; whether that `=` ignores case is the database collation's,
	// not exported (OPEN; INFERRED case-insensitive, SQL Server's default --
	// "without case" is OURS until then). OpenSRO has no nicknames.
	NameTaken(ctx context.Context, name string) (bool, error)
	// MarkDeleted starts characterID's deletion at at. ErrNotFound when the
	// account has no such character, ErrAlreadyDeleting when it is already
	// pending.
	MarkDeleted(ctx context.Context, accountID, characterID int64, at time.Time) error
	// Restore ends a pending deletion. ErrNotFound, or ErrNotDeleting when the
	// character is not pending.
	Restore(ctx context.Context, accountID, characterID int64) error
	// PurgeDeleted removes every character whose deletion started at or
	// before cutoff, returning their ids.
	PurgeDeleted(ctx context.Context, cutoff time.Time) ([]int64, error)
}

// NewCharacter is what CreateCharacter makes a character from.
type NewCharacter struct {
	Name     string
	RefObjID int64
	Scale    int
	Gender   string
	// The start spawn (Character.StartZone).
	StartZone              string
	StartX, StartY, StartZ float64
}

// ErrAlreadyDeleting and ErrNotDeleting are the soft delete's refusals.
var (
	ErrAlreadyDeleting = errors.New("character: already pending deletion")
	ErrNotDeleting     = errors.New("character: not pending deletion")
)

func newCharacterRow(id, accountID int64, nc NewCharacter) *Character {
	return &Character{ID: id, AccountID: accountID, Name: nc.Name, Gold: StartingGold, HP: StartingMaxHP,
		Gender: nc.Gender, Level: StartingLevel, Str: StartingStr, Int: StartingInt,
		RefObjID: nc.RefObjID, Scale: nc.Scale,
		StartZone: nc.StartZone, StartX: nc.StartX, StartY: nc.StartY, StartZ: nc.StartZ}
}

// --- MemStore ---------------------------------------------------------------

// CreateCharacter implements LobbyStore.
func (m *MemStore) CreateCharacter(_ context.Context, accountID int64, nc NewCharacter) (*Character, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := normalizeName(nc.Name)
	if m.namesTaken[key] {
		return nil, ErrNameTaken
	}
	count := 0
	for _, c := range m.byID {
		if c.AccountID == accountID {
			count++
		}
	}
	if count >= MaxPerAccount {
		return nil, ErrAccountFull
	}
	m.nextID++
	c := newCharacterRow(m.nextID, accountID, nc)
	m.byID[c.ID] = c
	m.namesTaken[key] = true
	cp := *c
	return &cp, nil
}

// NameTaken implements LobbyStore.
func (m *MemStore) NameTaken(_ context.Context, name string) (bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.namesTaken[normalizeName(name)], nil
}

// MarkDeleted implements LobbyStore.
func (m *MemStore) MarkDeleted(_ context.Context, accountID, characterID int64, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.byID[characterID]
	if !ok || c.AccountID != accountID {
		return ErrNotFound
	}
	if !c.DeletedAt.IsZero() {
		return ErrAlreadyDeleting
	}
	c.DeletedAt = at
	return nil
}

// Restore implements LobbyStore.
func (m *MemStore) Restore(_ context.Context, accountID, characterID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.byID[characterID]
	if !ok || c.AccountID != accountID {
		return ErrNotFound
	}
	if c.DeletedAt.IsZero() {
		return ErrNotDeleting
	}
	c.DeletedAt = time.Time{}
	return nil
}

// PurgeDeleted implements LobbyStore.
func (m *MemStore) PurgeDeleted(_ context.Context, cutoff time.Time) ([]int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []int64
	for id, c := range m.byID {
		if !c.DeletedAt.IsZero() && !c.DeletedAt.After(cutoff) {
			out = append(out, id)
			delete(m.byID, id)
			delete(m.namesTaken, normalizeName(c.Name))
		}
	}
	return out, nil
}

// --- SQLStore ---------------------------------------------------------------

// characterColumns is every column a Character is read from, in scanCharacter's
// order.
const characterColumns = `id, account_id, name, gold, hp, gender, level, exp, stat_points, str, intel, storage_gold, hwan_count, latest_zone, latest_frame, pos_x, pos_y, pos_z, ref_obj_id, scale, deleted_at, start_zone, start_x, start_y, start_z`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanCharacter(r rowScanner) (*Character, error) {
	var c Character
	var deleted sql.NullTime
	if err := r.Scan(&c.ID, &c.AccountID, &c.Name, &c.Gold, &c.HP, &c.Gender, &c.Level, &c.Exp, &c.StatPoints, &c.Str, &c.Int, &c.StorageGold, &c.HwanCount,
		&c.Zone, &c.Frame, &c.PosX, &c.PosY, &c.PosZ,
		&c.RefObjID, &c.Scale, &deleted, &c.StartZone, &c.StartX, &c.StartY, &c.StartZ); err != nil {
		return nil, err
	}
	if deleted.Valid {
		c.DeletedAt = deleted.Time
	}
	return &c, nil
}

// CreateCharacter implements LobbyStore. The count and the insert run in one
// transaction under a per-account advisory lock, so two creates on one account
// cannot both pass the limit.
func (s *SQLStore) CreateCharacter(ctx context.Context, accountID int64, nc NewCharacter) (*Character, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("character: beginning create: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock($1)`, lobbyLockKey(accountID)); err != nil {
		return nil, fmt.Errorf("character: locking account: %w", err)
	}
	var count int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM characters WHERE account_id = $1`, accountID).Scan(&count); err != nil {
		return nil, fmt.Errorf("character: counting existing characters: %w", err)
	}
	if count >= MaxPerAccount {
		return nil, ErrAccountFull
	}
	var id int64
	err = tx.QueryRowContext(ctx,
		`INSERT INTO characters (account_id, name, gold, hp, gender, level, str, intel, ref_obj_id, scale, start_zone, start_x, start_y, start_z)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) RETURNING id`,
		accountID, nc.Name, StartingGold, StartingMaxHP, nc.Gender, StartingLevel, StartingStr, StartingInt,
		nc.RefObjID, nc.Scale, nc.StartZone, nc.StartX, nc.StartY, nc.StartZ).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("character: inserting character: %w", err)
	}
	if err := tx.Commit(); err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("character: committing create: %w", err)
	}
	return newCharacterRow(id, accountID, nc), nil
}

// lobbyLockKey is the advisory lock key for an account's creates: a constant
// tag in the high half so it cannot meet another package's account-id lock.
func lobbyLockKey(accountID int64) int64 { return 0x6c6f6262<<32 | (accountID & 0xffffffff) }

// NameTaken implements LobbyStore.
func (s *SQLStore) NameTaken(ctx context.Context, name string) (bool, error) {
	var taken bool
	if err := s.db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM characters WHERE LOWER(name) = LOWER($1))`, name).Scan(&taken); err != nil {
		return false, fmt.Errorf("character: checking name: %w", err)
	}
	return taken, nil
}

// MarkDeleted implements LobbyStore.
func (s *SQLStore) MarkDeleted(ctx context.Context, accountID, characterID int64, at time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET deleted_at = $3 WHERE id = $1 AND account_id = $2 AND deleted_at IS NULL`,
		characterID, accountID, at)
	if err != nil {
		return fmt.Errorf("character: marking deleted: %w", err)
	}
	return s.lobbyOutcome(ctx, res, accountID, characterID, ErrAlreadyDeleting)
}

// Restore implements LobbyStore.
func (s *SQLStore) Restore(ctx context.Context, accountID, characterID int64) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE characters SET deleted_at = NULL WHERE id = $1 AND account_id = $2 AND deleted_at IS NOT NULL`,
		characterID, accountID)
	if err != nil {
		return fmt.Errorf("character: restoring: %w", err)
	}
	return s.lobbyOutcome(ctx, res, accountID, characterID, ErrNotDeleting)
}

// lobbyOutcome tells an UPDATE that touched no row apart: no such character on
// the account (ErrNotFound) or one in the wrong state (wrongState).
func (s *SQLStore) lobbyOutcome(ctx context.Context, res sql.Result, accountID, characterID int64, wrongState error) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n > 0 {
		return nil
	}
	var exists bool
	if err := s.db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM characters WHERE id = $1 AND account_id = $2)`,
		characterID, accountID).Scan(&exists); err != nil {
		return fmt.Errorf("character: checking existence: %w", err)
	}
	if !exists {
		return ErrNotFound
	}
	return wrongState
}

// PurgeDeleted implements LobbyStore.
func (s *SQLStore) PurgeDeleted(ctx context.Context, cutoff time.Time) ([]int64, error) {
	rows, err := s.db.QueryContext(ctx,
		`DELETE FROM characters WHERE deleted_at IS NOT NULL AND deleted_at <= $1 RETURNING id`, cutoff)
	if err != nil {
		return nil, fmt.Errorf("character: purging: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
