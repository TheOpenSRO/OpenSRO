package txn

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"sync"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}

func openDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := OpenPool(testDSN(), 8)
	if err != nil {
		t.Fatalf("OpenPool: %v (is postgres running?)", err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(Schema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	if _, err := db.Exec(`DROP TABLE IF EXISTS txn_probe; CREATE TABLE txn_probe (k TEXT PRIMARY KEY, v INT NOT NULL)`); err != nil {
		t.Fatalf("probe table: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating the ledger: %v", err)
	}
	return db
}

var errBoom = errors.New("boom")

// The in-memory journal: a failed action replays its undos, newest first; a
// nested action's failure undoes only its own part.
func TestMemRunRollsBack(t *testing.T) {
	ctx := context.Background()
	var log []string
	change := func(ctx context.Context, name string) {
		log = append(log, "+"+name)
		OnRollback(ctx, func() { log = append(log, "-"+name) })
	}
	err := Runner{}.Run(ctx, func(ctx context.Context) error {
		change(ctx, "a")
		if err := (Runner{}).Run(ctx, func(ctx context.Context) error {
			change(ctx, "b")
			return errBoom
		}); !errors.Is(err, errBoom) {
			t.Fatalf("nested: %v", err)
		}
		change(ctx, "c")
		return errBoom
	})
	if !errors.Is(err, errBoom) {
		t.Fatalf("Run: %v", err)
	}
	want := []string{"+a", "+b", "-b", "+c", "-c", "-a"}
	if len(log) != len(want) {
		t.Fatalf("journal %v, want %v", log, want)
	}
	for i := range want {
		if log[i] != want[i] {
			t.Fatalf("journal %v, want %v", log, want)
		}
	}
}

// A store's own transaction inside an action is a savepoint: its failure
// undoes its own writes and leaves the action usable; the action's failure
// undoes everything.
func TestSQLRunSavepoints(t *testing.T) {
	db := openDB(t)
	ctx := context.Background()
	write := func(ctx context.Context, k string, fail bool) error {
		tx, err := Begin(ctx, db)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err := tx.ExecContext(ctx, `INSERT INTO txn_probe (k, v) VALUES ($1, 1)`, k); err != nil {
			return err
		}
		if fail {
			// A statement error aborts the transaction; the savepoint must
			// recover it.
			tx.ExecContext(ctx, `SELECT 1/0`)
			return errBoom
		}
		return tx.Commit()
	}
	err := Runner{DB: db}.Run(ctx, func(ctx context.Context) error {
		if err := write(ctx, "kept", false); err != nil {
			return err
		}
		if err := write(ctx, "undone", true); !errors.Is(err, errBoom) {
			return err
		}
		return write(ctx, "after", false)
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	var n int
	db.QueryRow(`SELECT count(*) FROM txn_probe WHERE k IN ('kept', 'after')`).Scan(&n)
	var undone int
	db.QueryRow(`SELECT count(*) FROM txn_probe WHERE k = 'undone'`).Scan(&undone)
	if n != 2 || undone != 0 {
		t.Fatalf("kept+after %d (want 2), undone %d (want 0)", n, undone)
	}

	err = Runner{DB: db}.Run(ctx, func(ctx context.Context) error {
		if err := write(ctx, "rolled", false); err != nil {
			return err
		}
		return errBoom
	})
	db.QueryRow(`SELECT count(*) FROM txn_probe WHERE k = 'rolled'`).Scan(&n)
	if !errors.Is(err, errBoom) || n != 0 {
		t.Fatalf("a failed action left its write: err %v, rows %d", err, n)
	}
}

// Two actions claiming one key at once: exactly one applies.
func TestClaimRacedAppliesOnce(t *testing.T) {
	db := openDB(t)
	ctx := context.Background()
	for _, r := range []Runner{{DB: db}, {}} {
		var wg sync.WaitGroup
		errs := make([]error, 8)
		for i := range errs {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				errs[i] = r.Run(ctx, func(ctx context.Context) error { return Claim(ctx, "probe:"+BootID) })
			}(i)
		}
		wg.Wait()
		ok, dup := 0, 0
		for _, err := range errs {
			switch {
			case err == nil:
				ok++
			case errors.Is(err, ErrAlreadyApplied):
				dup++
			default:
				t.Fatalf("db=%v: %v", r.DB != nil, err)
			}
		}
		if ok != 1 || dup != len(errs)-1 {
			t.Fatalf("db=%v: %d applied, %d refused; want 1 and %d", r.DB != nil, ok, dup, len(errs)-1)
		}
		if done, err := r.Applied(ctx, "probe:"+BootID); err != nil || !done {
			t.Fatalf("db=%v: Applied = %v, %v", r.DB != nil, done, err)
		}
	}
}

// A rolled-back claim is not a claim.
func TestClaimRolledBackIsFree(t *testing.T) {
	db := openDB(t)
	ctx := context.Background()
	key := "probe-rollback:" + BootID
	err := Runner{DB: db}.Run(ctx, func(ctx context.Context) error {
		if err := Claim(ctx, key); err != nil {
			return err
		}
		return errBoom
	})
	if !errors.Is(err, errBoom) {
		t.Fatalf("Run: %v", err)
	}
	if err := (Runner{DB: db}).Run(ctx, func(ctx context.Context) error { return Claim(ctx, key) }); err != nil {
		t.Fatalf("claiming after a rollback: %v", err)
	}
}

func TestSerialsAreUnique(t *testing.T) {
	db := openDB(t)
	ctx := context.Background()
	for _, s := range []*Serials{{DB: db}, {}} {
		seen := map[int64]bool{}
		var mu sync.Mutex
		var wg sync.WaitGroup
		for g := 0; g < 4; g++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := 0; i < 300; i++ {
					v, err := s.Next(ctx)
					if err != nil {
						t.Errorf("Next: %v", err)
						return
					}
					mu.Lock()
					if seen[v] {
						t.Errorf("serial %d handed out twice", v)
					}
					seen[v] = true
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
	}
}

func TestPoolSizes(t *testing.T) {
	for _, c := range []struct {
		env        string
		stores, rf int
	}{{"", 32, 8}, {"junk", 32, 8}, {"3", 32, 8}, {"10", 8, 2}, {"90", 72, 18}} {
		t.Setenv(MaxConnsEnv, c.env)
		if s, r := PoolSizes(); s != c.stores || r != c.rf {
			t.Errorf("%s=%q: %d + %d, want %d + %d", MaxConnsEnv, c.env, s, r, c.stores, c.rf)
		}
	}
}

// The pool is capped: more concurrent transactions than connections wait
// for one rather than opening more.
func TestOpenPoolIsCapped(t *testing.T) {
	db, err := OpenPool(testDSN(), 3)
	if err != nil {
		t.Fatalf("OpenPool: %v", err)
	}
	defer db.Close()
	if got := db.Stats().MaxOpenConnections; got != 3 {
		t.Fatalf("MaxOpenConnections = %d, want 3", got)
	}
}
