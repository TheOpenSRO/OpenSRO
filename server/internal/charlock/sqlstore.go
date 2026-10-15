package charlock

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/txn"
)

// schema is OURS (the feature is). Two tables, keyed by account id: the PIN
// with its failure count and lock end, and the remembered PCs. No foreign key
// to accounts: this store is opened after the account store but must not
// depend on its migration order; an account's rows go with ClearPin.
const schema = `
CREATE TABLE IF NOT EXISTS character_locks (
	account_id   BIGINT PRIMARY KEY,
	pin_hash     BYTEA NOT NULL,
	failures     INTEGER NOT NULL DEFAULT 0,
	locked_until TIMESTAMPTZ
);
CREATE TABLE IF NOT EXISTS character_lock_devices (
	account_id BIGINT NOT NULL,
	token_hash BYTEA NOT NULL,
	added_at   TIMESTAMPTZ NOT NULL,
	PRIMARY KEY (account_id, token_hash)
);
`

// SQLStore is a Store on PostgreSQL.
type SQLStore struct {
	db *sql.DB
}

// NewSQLStore opens the store on a pool the caller owns, creating its tables
// when they are missing.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("charlock: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TxDB implements txn.TxDBer.
func (s *SQLStore) TxDB() *sql.DB { return s.db }

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, accountID int64) (Record, error) {
	var r Record
	var until sql.NullTime
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT pin_hash, failures, locked_until FROM character_locks WHERE account_id = $1`, accountID).
		Scan(&r.PinHash, &r.Failures, &until)
	if errors.Is(err, sql.ErrNoRows) {
		return Record{}, nil
	}
	if err != nil {
		return Record{}, fmt.Errorf("charlock: reading the lock: %w", err)
	}
	if until.Valid {
		r.LockedUntil = until.Time
	}
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx,
		`SELECT token_hash FROM character_lock_devices WHERE account_id = $1 ORDER BY added_at, token_hash`, accountID)
	if err != nil {
		return Record{}, fmt.Errorf("charlock: reading the remembered PCs: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var h []byte
		if err := rows.Scan(&h); err != nil {
			return Record{}, fmt.Errorf("charlock: reading a remembered PC: %w", err)
		}
		r.Devices = append(r.Devices, h)
	}
	return r, rows.Err()
}

// SetPin implements Store. The insert refuses a second PIN by its key, so two
// creates cannot both pass.
func (s *SQLStore) SetPin(ctx context.Context, accountID int64, hash []byte) error {
	return s.inTx(ctx, func(q txn.Querier) error {
		res, err := q.ExecContext(ctx,
			`INSERT INTO character_locks (account_id, pin_hash) VALUES ($1, $2) ON CONFLICT (account_id) DO NOTHING`,
			accountID, hash)
		if err != nil {
			return fmt.Errorf("charlock: storing the PIN: %w", err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrPinExists
		}
		if _, err := q.ExecContext(ctx,
			`DELETE FROM character_lock_devices WHERE account_id = $1`, accountID); err != nil {
			return fmt.Errorf("charlock: forgetting the remembered PCs: %w", err)
		}
		return nil
	})
}

// ClearPin implements Store.
func (s *SQLStore) ClearPin(ctx context.Context, accountID int64) error {
	return s.inTx(ctx, func(q txn.Querier) error {
		res, err := q.ExecContext(ctx, `DELETE FROM character_locks WHERE account_id = $1`, accountID)
		if err != nil {
			return fmt.Errorf("charlock: removing the PIN: %w", err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrNoPin
		}
		if _, err := q.ExecContext(ctx,
			`DELETE FROM character_lock_devices WHERE account_id = $1`, accountID); err != nil {
			return fmt.Errorf("charlock: forgetting the remembered PCs: %w", err)
		}
		return nil
	})
}

// RecordFailure implements Store in one statement, so two sessions' wrong
// entries cannot both read the same count.
func (s *SQLStore) RecordFailure(ctx context.Context, accountID int64, max int, until time.Time) (int, time.Time, error) {
	var failures int
	var locked sql.NullTime
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`UPDATE character_locks SET
			failures = CASE WHEN failures + 1 >= $2 THEN 0 ELSE failures + 1 END,
			locked_until = CASE WHEN failures + 1 >= $2 THEN $3 ELSE locked_until END
		 WHERE account_id = $1 RETURNING failures, locked_until`, accountID, max, until).Scan(&failures, &locked)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, time.Time{}, ErrNoPin
	}
	if err != nil {
		return 0, time.Time{}, fmt.Errorf("charlock: counting a wrong PIN: %w", err)
	}
	if locked.Valid {
		return failures, locked.Time, nil
	}
	return failures, time.Time{}, nil
}

// ResetFailures implements Store.
func (s *SQLStore) ResetFailures(ctx context.Context, accountID int64) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE character_locks SET failures = 0 WHERE account_id = $1`, accountID); err != nil {
		return fmt.Errorf("charlock: resetting the failures: %w", err)
	}
	return nil
}

// RememberDevice implements Store.
func (s *SQLStore) RememberDevice(ctx context.Context, accountID int64, tokenHash []byte, now time.Time) error {
	return s.inTx(ctx, func(q txn.Querier) error {
		if _, err := q.ExecContext(ctx,
			`INSERT INTO character_lock_devices (account_id, token_hash, added_at) VALUES ($1, $2, $3)
			 ON CONFLICT (account_id, token_hash) DO NOTHING`, accountID, tokenHash, now); err != nil {
			return fmt.Errorf("charlock: remembering a PC: %w", err)
		}
		// Keep the newest MaxDevices.
		if _, err := q.ExecContext(ctx,
			`DELETE FROM character_lock_devices WHERE account_id = $1 AND token_hash NOT IN (
				SELECT token_hash FROM character_lock_devices WHERE account_id = $1
				ORDER BY added_at DESC, token_hash DESC LIMIT $2)`, accountID, MaxDevices); err != nil {
			return fmt.Errorf("charlock: trimming the remembered PCs: %w", err)
		}
		return nil
	})
}

// inTx runs fn in the store's own transaction (a savepoint inside the
// context's, when it carries one).
func (s *SQLStore) inTx(ctx context.Context, fn func(q txn.Querier) error) error {
	tx, err := txn.Begin(ctx, s.db)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}
