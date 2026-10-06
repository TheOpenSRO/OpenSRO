package txn

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/fnv"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// Schema is what the economy's transactions need besides the stores' own
// tables, created idempotently by the stores at start (inventory and
// character run it), the way every store already creates its tables:
//
//   - item_serial_seq numbers item rows (the bag's and the warehouse's
//     `serial` column, inventory.schemaFor) and ground items (Serials);
//   - economy_ops is the idempotency ledger: one row per applied one-shot
//     action (a trade, a pick-up), keyed by the action's own identity, written
//     in the action's transaction. A retried or duplicated action finds its
//     key and changes nothing (Claim). PruneLedger keeps it small.
const Schema = `
CREATE SEQUENCE IF NOT EXISTS item_serial_seq;
CREATE TABLE IF NOT EXISTS economy_ops (
	op_key     TEXT PRIMARY KEY,
	created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS economy_ops_created_at ON economy_ops (created_at);
`

// migrationLock is the advisory-lock key every store's boot-time schema runs
// under (Migrate). OURS: any constant no other code uses.
const migrationLock = 743_000_001

// Migrate runs a store's boot-time schema statements under one
// session-level advisory lock (round 743's review, F7), so two processes
// starting at once take turns: `CREATE ... IF NOT EXISTS` is not safe
// against itself, and the loser of that race failed with a duplicate key on
// pg_class and exited. Each statement string may hold several statements.
func Migrate(db *sql.DB, stmts ...string) error {
	ctx := context.Background()
	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("txn: a connection for the schema: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `SELECT pg_advisory_lock($1)`, int64(migrationLock)); err != nil {
		return fmt.Errorf("txn: locking the schema: %w", err)
	}
	defer conn.ExecContext(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, int64(migrationLock))
	for _, st := range stmts {
		if _, err := conn.ExecContext(ctx, st); err != nil {
			return err
		}
	}
	return nil
}

// ErrAlreadyApplied is Claim's answer for a key already in the ledger: the
// action happened once already, and must not happen again.
var ErrAlreadyApplied = errors.New("txn: this action was already applied")

// memLedger is the ledger of a process without a database.
var memLedger = struct {
	sync.Mutex
	keys map[string]bool
}{keys: map[string]bool{}}

// Claim records key in the ledger, inside the context's transaction, and
// answers ErrAlreadyApplied when it is already there. Called first in an
// action, it makes the whole action happen at most once per key: a second
// attempt -- a resent request, a retry after an answer was lost, another
// process -- rolls back without touching anything.
func Claim(ctx context.Context, key string) error {
	if st := sqlFrom(ctx); st != nil {
		res, err := st.tx.ExecContext(ctx, `INSERT INTO economy_ops (op_key) VALUES ($1) ON CONFLICT (op_key) DO NOTHING`, key)
		if err != nil {
			return fmt.Errorf("txn: claiming %q: %w", key, err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrAlreadyApplied
		}
		return nil
	}
	memLedger.Lock()
	defer memLedger.Unlock()
	if memLedger.keys[key] {
		return ErrAlreadyApplied
	}
	memLedger.keys[key] = true
	OnRollback(ctx, func() {
		memLedger.Lock()
		delete(memLedger.keys, key)
		memLedger.Unlock()
	})
	return nil
}

// Applied reports whether key is in the ledger: whether an action whose
// answer was an error (a timeout after the commit, say) committed after all.
func (r Runner) Applied(ctx context.Context, key string) (bool, error) {
	if r.DB == nil {
		memLedger.Lock()
		defer memLedger.Unlock()
		return memLedger.keys[key], nil
	}
	var ok bool
	err := r.DB.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM economy_ops WHERE op_key = $1)`, key).Scan(&ok)
	return ok, err
}

// PruneLedger deletes ledger rows older than age. A key only has to outlive
// the retries of its own action (a ground item lives minutes, a trade id one
// process), so a day is generous.
func PruneLedger(ctx context.Context, db *sql.DB, age time.Duration) (int64, error) {
	res, err := db.ExecContext(ctx, `DELETE FROM economy_ops WHERE created_at < now() - $1::interval`,
		fmt.Sprintf("%d seconds", int64(age/time.Second)))
	if err != nil {
		return 0, fmt.Errorf("txn: pruning the ledger: %w", err)
	}
	return res.RowsAffected()
}

// BootID names this process's run: ledger keys built from per-process
// counters (a trade's id) carry it, so a restart's counters cannot collide
// with keys an earlier run left.
var BootID = func() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b[:])
}()

// LockOwner takes a transaction-scoped advisory lock on one owner of one
// container (class: the table), so every write to that owner's slots runs
// one at a time: the slot a placement picked is still free when it inserts,
// and a quantity read is still the quantity when it is changed. Outside a
// transaction it is held for the one statement, which is harmless.
//
// The owner is folded to 32 bits; two owners sharing a key only wait for
// each other.
func LockOwner(ctx context.Context, q Querier, class string, owner int64) error {
	h := fnv.New32a()
	h.Write([]byte(class))
	if _, err := q.ExecContext(ctx, `SELECT pg_advisory_xact_lock($1::int, $2::int)`,
		int32(h.Sum32()), int32(uint32(owner))); err != nil {
		return fmt.Errorf("txn: locking %s %d: %w", class, owner, err)
	}
	return nil
}

// Serials hands out item serials from item_serial_seq, a block at a time so
// a drop does not pay a round trip. Without a database it counts in memory.
type Serials struct {
	DB *sql.DB

	mu   sync.Mutex
	buf  []int64
	mem  atomic.Int64
	once sync.Once
}

// serialBlock is how many serials one round trip reserves.
const serialBlock = 256

// Next answers a serial no other item row or ground item has had.
func (s *Serials) Next(ctx context.Context) (int64, error) {
	if s == nil || s.DB == nil {
		if s == nil {
			return 0, errors.New("txn: no serial source")
		}
		// In memory: high enough that it never meets a sequence value a test
		// database handed out.
		s.once.Do(func() { s.mem.Store(1 << 52) })
		return s.mem.Add(1), nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.buf) == 0 {
		rows, err := s.DB.QueryContext(ctx, `SELECT nextval('item_serial_seq') FROM generate_series(1, $1)`, serialBlock)
		if err != nil {
			return 0, fmt.Errorf("txn: reserving serials: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var v int64
			if err := rows.Scan(&v); err != nil {
				return 0, fmt.Errorf("txn: reading serials: %w", err)
			}
			s.buf = append(s.buf, v)
		}
		if err := rows.Err(); err != nil {
			return 0, err
		}
		if len(s.buf) == 0 {
			return 0, errors.New("txn: the sequence gave no serials")
		}
	}
	v := s.buf[0]
	s.buf = s.buf[1:]
	return v, nil
}

// MaxConnsEnv names the process's Postgres connection budget.
const MaxConnsEnv = "OPENSRO_PG_MAX_CONNS"

// DefaultMaxConns is the budget without the variable: under half of a
// default Postgres's max_connections (100), so two processes (a rolling
// restart, a tool) still fit beside the superuser's reserve.
const DefaultMaxConns = 40

// PoolSizes splits the budget: the reference data's own pool gets a fifth
// (at least 2) and the stores' shared pool the rest (at least 2). The
// reference data has its own pool on purpose: an economy transaction holds a
// connection of the shared pool while it asks the reference data for an
// item's stack size, and that ask must never wait for a connection of the
// pool it is holding one of. The budget is read from MaxConnsEnv; an unset,
// unparsable or too-small value falls back to DefaultMaxConns.
func PoolSizes() (stores, refdata int) {
	n := DefaultMaxConns
	if v, err := strconv.Atoi(os.Getenv(MaxConnsEnv)); err == nil && v >= 4 {
		n = v
	}
	refdata = n / 5
	if refdata < 2 {
		refdata = 2
	}
	return n - refdata, refdata
}

// OpenPool opens one capped pool on dsn and checks it answers.
func OpenPool(dsn string, maxConns int) (*sql.DB, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("txn: opening postgres: %w", err)
	}
	db.SetMaxOpenConns(maxConns)
	idle := maxConns / 2
	if idle < 2 {
		idle = 2
	}
	db.SetMaxIdleConns(idle)
	db.SetConnMaxIdleTime(5 * time.Minute)
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("txn: connecting to postgres: %w", err)
	}
	return db, nil
}
