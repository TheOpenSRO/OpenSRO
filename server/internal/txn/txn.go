// Package txn makes one game action one database transaction (round 743, the
// architecture spec's migration M1: docs/protocol/server_architecture.md,
// 4.8 "How the economy transactions must look").
//
// Before round 743 every store opened its own pool and ran its own short
// transactions, so a trade was six or more separate commits across two pools
// and a failure between them destroyed or duplicated value
// (docs/rounds/r743.md has the tests that proved both). The stores keep their
// interfaces; what changes is that a transaction can travel in the context:
//
//   - Runner.Run begins one transaction and hands fn a context carrying it.
//     Every SQL store method reaches the database through Conn(ctx, db) or
//     Begin(ctx, db), which use the context's transaction when there is one --
//     Begin as a SAVEPOINT inside it, so a store's own all-or-nothing step
//     stays all-or-nothing inside the larger one. fn's error rolls the whole
//     action back; there is no compensation code.
//   - The in-memory stores (the -no-postgres server and most tests) register
//     an undo for every change with OnRollback, which Run replays in reverse
//     when fn fails. Without a database, Run also serialises actions on one
//     process-wide mutex, so a check and the write it guards cannot interleave
//     with another action's.
//
// The context's transaction wins over a store's own pool: the stores of one
// process point at one database, and a store that ignored the transaction
// would block on the very row locks the transaction holds.
package txn

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// Querier is what *sql.DB, *sql.Tx and *Tx have in common: what a store
// method needs to run its statements.
type Querier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// sqlState is one top-level SQL transaction, shared by everything nested in
// it.
type sqlState struct {
	tx   *sql.Tx
	next atomic.Int64 // savepoint names
}

type sqlKey struct{}

func sqlFrom(ctx context.Context) *sqlState {
	st, _ := ctx.Value(sqlKey{}).(*sqlState)
	return st
}

// InSQL reports whether ctx carries a SQL transaction.
func InSQL(ctx context.Context) bool { return sqlFrom(ctx) != nil }

// Conn is where a store's statement runs: the context's transaction when it
// carries one, else the store's own pool.
func Conn(ctx context.Context, db *sql.DB) Querier {
	if st := sqlFrom(ctx); st != nil {
		return st.tx
	}
	return db
}

// Tx is a store's own transaction: a real one when the context carries none,
// a SAVEPOINT inside the context's otherwise. Ctx is the context to hand to
// any store call made inside it, so those join it too.
type Tx struct {
	tx  *sql.Tx
	sp  string // "" for a top-level transaction
	end bool
	Ctx context.Context
}

// Begin starts a store's transaction on db, or a savepoint inside the
// context's.
func Begin(ctx context.Context, db *sql.DB) (*Tx, error) {
	if st := sqlFrom(ctx); st != nil {
		name := fmt.Sprintf("sp%d", st.next.Add(1))
		if _, err := st.tx.ExecContext(ctx, "SAVEPOINT "+name); err != nil {
			return nil, fmt.Errorf("txn: savepoint: %w", err)
		}
		return &Tx{tx: st.tx, sp: name, Ctx: ctx}, nil
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("txn: beginning transaction: %w", err)
	}
	return &Tx{tx: tx, Ctx: context.WithValue(ctx, sqlKey{}, &sqlState{tx: tx})}, nil
}

// ExecContext implements Querier.
func (t *Tx) ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error) {
	return t.tx.ExecContext(ctx, q, args...)
}

// QueryContext implements Querier.
func (t *Tx) QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error) {
	return t.tx.QueryContext(ctx, q, args...)
}

// QueryRowContext implements Querier.
func (t *Tx) QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row {
	return t.tx.QueryRowContext(ctx, q, args...)
}

// Commit commits a top-level transaction, or releases a savepoint (its
// writes then stand or fall with the enclosing transaction).
func (t *Tx) Commit() error {
	if t.end {
		return sql.ErrTxDone
	}
	t.end = true
	if t.sp == "" {
		return t.tx.Commit()
	}
	_, err := t.tx.ExecContext(t.Ctx, "RELEASE SAVEPOINT "+t.sp)
	return err
}

// Rollback undoes everything since Begin. A no-op after Commit, so it can be
// deferred.
func (t *Tx) Rollback() error {
	if t.end {
		return nil
	}
	t.end = true
	if t.sp == "" {
		return t.tx.Rollback()
	}
	// The context may be the one that failed; the savepoint must still go.
	ctx := context.WithoutCancel(t.Ctx)
	if _, err := t.tx.ExecContext(ctx, "ROLLBACK TO SAVEPOINT "+t.sp); err != nil {
		return err
	}
	_, err := t.tx.ExecContext(ctx, "RELEASE SAVEPOINT "+t.sp)
	return err
}

// memState is one action's undo journal.
type memState struct {
	mu   sync.Mutex
	undo []func()
}

type memKey struct{}

func memFrom(ctx context.Context) *memState {
	st, _ := ctx.Value(memKey{}).(*memState)
	return st
}

func (m *memState) mark() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.undo)
}

// rollbackTo replays, newest first, every undo registered after mark.
func (m *memState) rollbackTo(mark int) {
	m.mu.Lock()
	undo := m.undo[mark:]
	m.undo = m.undo[:mark]
	m.mu.Unlock()
	for i := len(undo) - 1; i >= 0; i-- {
		undo[i]()
	}
}

// OnRollback registers undo to run if the action ctx belongs to fails. An
// in-memory store calls it after each change it makes; outside an action it
// does nothing.
func OnRollback(ctx context.Context, undo func()) {
	if st := memFrom(ctx); st != nil {
		st.mu.Lock()
		st.undo = append(st.undo, undo)
		st.mu.Unlock()
	}
}

// InAction reports whether ctx belongs to a Runner.Run.
func InAction(ctx context.Context) bool { return memFrom(ctx) != nil }

// memActions serialises actions that have no database to do it.
var memActions sync.Mutex

// Runner runs one game action as one transaction. DB nil runs it on the
// in-memory journal alone.
type Runner struct {
	DB *sql.DB
}

// TxDBer is a store that can say which database it writes: every SQL store
// implements it, so For can find the database an action's stores share.
type TxDBer interface {
	TxDB() *sql.DB
}

// For is the Runner for an action over these stores: on the first SQL
// store's database, or in memory when none is a SQL store. A nil or
// non-store argument is skipped.
func For(stores ...any) Runner {
	for _, s := range stores {
		if d, ok := s.(TxDBer); ok && d != nil {
			if db := d.TxDB(); db != nil {
				return Runner{DB: db}
			}
		}
	}
	return Runner{}
}

// maxAttempts bounds Run's retries of a deadlocked or serialisation-failed
// transaction (Postgres aborts one side; the action is safe to run again
// because nothing of the aborted attempt survives).
const maxAttempts = 4

// afterCommit is the test hook: an error it returns is answered AFTER a
// successful commit, which is what a timeout between the commit and its
// acknowledgement looks like to the caller.
var afterCommit atomic.Pointer[func(context.Context) error]

// SetAfterCommitHookForTest installs the hook and returns its removal. Not
// for production use.
func SetAfterCommitHookForTest(f func(context.Context) error) (restore func()) {
	afterCommit.Store(&f)
	return func() { afterCommit.Store(nil) }
}

// Run runs fn as one transaction. fn gets the context to pass to every store
// call; its error, or a failed commit, undoes everything fn did, in the
// database and in the in-memory stores alike. Nested inside another Run (the
// context already carries one), it is a savepoint of that one.
//
// fn must only touch stores: it may run more than once (a deadlock is
// retried), and anything it does outside them is not undone.
func (r Runner) Run(ctx context.Context, fn func(ctx context.Context) error) error {
	if outer := memFrom(ctx); outer != nil {
		return r.nested(ctx, outer, fn)
	}
	if r.DB == nil && !InSQL(ctx) {
		memActions.Lock()
		defer memActions.Unlock()
	}
	attempts := maxAttempts
	if InSQL(ctx) {
		attempts = 1 // the enclosing transaction decides whether to run again
	} else {
		// The action's deadline (round 743's review, F6): a database that
		// stops answering fails the action instead of holding its locks --
		// and a trade's latch -- for good.
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, ActionTimeout)
		defer cancel()
	}
	var err error
	for attempt := 1; ; attempt++ {
		err = r.once(ctx, fn)
		if err == nil || !Retryable(err) || attempt >= attempts {
			break
		}
		// A short, growing, jittered pause before the retry (the review's
		// F4), so two actions that just deadlocked do not collide again.
		if !backoff(ctx, attempt) {
			break
		}
	}
	if err == nil {
		if h := afterCommit.Load(); h != nil && *h != nil {
			return (*h)(ctx)
		}
	}
	return err
}

// ActionTimeout bounds one action, every retry included. OURS: far above an
// action's normal few milliseconds (round 742's pgbench: about 1 ms a commit),
// short enough that a stuck database frees a trade's two players within a
// quarter of a minute.
// A variable only so a test can shorten it.
var ActionTimeout = 15 * time.Second

// backoff sleeps before retry attempt+1: attempt x 10 ms plus up to 10 ms of
// jitter (OURS). It answers false when ctx ended first.
func backoff(ctx context.Context, attempt int) bool {
	d := time.Duration(attempt)*10*time.Millisecond + time.Duration(rand.Int64N(int64(10*time.Millisecond)))
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

func (r Runner) once(ctx context.Context, fn func(ctx context.Context) error) error {
	st := &memState{}
	ctx = context.WithValue(ctx, memKey{}, st)
	if r.DB == nil && !InSQL(ctx) {
		if err := fn(ctx); err != nil {
			st.rollbackTo(0)
			return err
		}
		return nil
	}
	tx, err := Begin(ctx, r.DB) // a savepoint when ctx already carries a transaction
	if err != nil {
		return err
	}
	if err := fn(tx.Ctx); err != nil {
		tx.Rollback()
		st.rollbackTo(0)
		return err
	}
	if err := tx.Commit(); err != nil {
		st.rollbackTo(0)
		return fmt.Errorf("txn: commit: %w", err)
	}
	return nil
}

func (r Runner) nested(ctx context.Context, outer *memState, fn func(ctx context.Context) error) error {
	mark := outer.mark()
	if !InSQL(ctx) {
		if err := fn(ctx); err != nil {
			outer.rollbackTo(mark)
			return err
		}
		return nil
	}
	tx, err := Begin(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx.Ctx); err != nil {
		tx.Rollback()
		outer.rollbackTo(mark)
		return err
	}
	if err := tx.Commit(); err != nil {
		outer.rollbackTo(mark)
		return err
	}
	return nil
}

// Retryable reports a deadlock (40P01) or a serialisation failure (40001):
// Postgres aborted the transaction, and running it again is safe.
func Retryable(err error) bool {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		return pg.Code == "40P01" || pg.Code == "40001"
	}
	return false
}
