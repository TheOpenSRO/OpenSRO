package testdb

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Round 743: helpers that make a database race deterministic. A test holds a
// row lock in its own transaction (HoldRow), starts the racing operations,
// waits until Postgres reports them all blocked on a lock (WaitLockWaiters),
// and only then lets them go. Every racer has then read whatever it reads
// before any of them writes -- the interleaving a race needs, every run.

// HoldRow opens a transaction on db and runs lockQuery in it (a
// `SELECT ... FOR UPDATE` naming the row the racers will write), returning
// the transaction. Commit it to release the racers.
func HoldRow(ctx context.Context, db *sql.DB, lockQuery string, args ...any) (*sql.Tx, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	rows, err := tx.QueryContext(ctx, lockQuery, args...)
	if err != nil {
		tx.Rollback()
		return nil, err
	}
	for rows.Next() {
	}
	rows.Close()
	return tx, nil
}

// LockWaiters counts the backends of this database waiting on a lock (a row
// lock, a transaction id or an advisory lock).
func LockWaiters(ctx context.Context, db *sql.DB) (int, error) {
	var n int
	err := db.QueryRowContext(ctx, `SELECT count(*) FROM pg_stat_activity
		WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()`).Scan(&n)
	return n, err
}

// WaitLockWaiters polls until at least n backends wait on a lock, or until
// done is closed (the racers finished without blocking: the fixed code may
// refuse before it reaches the lock), or until timeout. It answers how many
// were waiting when it stopped.
func WaitLockWaiters(ctx context.Context, db *sql.DB, n int, done <-chan struct{}, timeout time.Duration) (int, error) {
	deadline := time.Now().Add(timeout)
	for {
		got, err := LockWaiters(ctx, db)
		if err != nil {
			return got, fmt.Errorf("testdb: counting lock waiters: %w", err)
		}
		if got >= n {
			return got, nil
		}
		select {
		case <-done:
			return got, nil
		default:
		}
		if time.Now().After(deadline) {
			return got, nil
		}
		time.Sleep(10 * time.Millisecond)
	}
}
