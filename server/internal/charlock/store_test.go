package charlock

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// Round 788 (lane P): the account PIN's two stores hold to one contract.
// NEGATIVE: before round 788 the package does not exist.

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

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		t.Fatalf("postgres: %v (see testDSN)", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	db := openTestDB(t)
	s, err := NewSQLStore(db)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`TRUNCATE TABLE character_locks, character_lock_devices`); err != nil {
		t.Fatal(err)
	}
	return s
}

// eachStore runs f against a fresh MemStore and a fresh SQLStore.
func eachStore(t *testing.T, f func(t *testing.T, s Store)) {
	t.Run("mem", func(t *testing.T) { f(t, NewMemStore()) })
	t.Run("sql", func(t *testing.T) { f(t, openTestSQLStore(t)) })
}

var t0 = time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)

func TestStoreSetGetClear(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		rec, err := s.Get(ctx, 7)
		if err != nil || rec.HasPin() || rec.Failures != 0 || !rec.LockedUntil.IsZero() || len(rec.Devices) != 0 {
			t.Fatalf("fresh account: %+v %v, want the zero record", rec, err)
		}
		hash, _ := HashPin("1234")
		if err := s.SetPin(ctx, 7, hash); err != nil {
			t.Fatal(err)
		}
		if err := s.SetPin(ctx, 7, hash); !errors.Is(err, ErrPinExists) {
			t.Fatalf("second SetPin: %v, want ErrPinExists", err)
		}
		rec, _ = s.Get(ctx, 7)
		if !rec.HasPin() || !PinMatches(rec.PinHash, "1234") || PinMatches(rec.PinHash, "1235") {
			t.Fatalf("stored hash does not test as 1234: %+v", rec)
		}
		if other, _ := s.Get(ctx, 8); other.HasPin() {
			t.Fatal("another account sees the PIN")
		}
		if err := s.ClearPin(ctx, 7); err != nil {
			t.Fatal(err)
		}
		if err := s.ClearPin(ctx, 7); !errors.Is(err, ErrNoPin) {
			t.Fatalf("second ClearPin: %v, want ErrNoPin", err)
		}
		if rec, _ := s.Get(ctx, 7); rec.HasPin() {
			t.Fatal("PIN still there after ClearPin")
		}
	})
}

func TestStoreFailuresLockAtMax(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		if _, _, err := s.RecordFailure(ctx, 7, MaxFailures, t0); !errors.Is(err, ErrNoPin) {
			t.Fatalf("failure without a PIN: %v, want ErrNoPin", err)
		}
		hash, _ := HashPin("0000")
		s.SetPin(ctx, 7, hash)
		until := t0.Add(LockFor)
		for i := 1; i < MaxFailures; i++ {
			n, lu, err := s.RecordFailure(ctx, 7, MaxFailures, until)
			if err != nil || n != i || !lu.IsZero() {
				t.Fatalf("failure %d: count %d lock %v err %v", i, n, lu, err)
			}
		}
		n, lu, err := s.RecordFailure(ctx, 7, MaxFailures, until)
		if err != nil || n != 0 || !lu.Equal(until) {
			t.Fatalf("failure %d: count %d lock %v err %v, want 0 and %v", MaxFailures, n, lu, err, until)
		}
		rec, _ := s.Get(ctx, 7)
		if !rec.LockedUntil.Equal(until) || rec.Failures != 0 || !rec.Locked(t0) || rec.Locked(until) {
			t.Fatalf("after the lock: %+v", rec)
		}
		// Reset after a right entry.
		s.RecordFailure(ctx, 7, MaxFailures, until)
		if err := s.ResetFailures(ctx, 7); err != nil {
			t.Fatal(err)
		}
		if rec, _ := s.Get(ctx, 7); rec.Failures != 0 {
			t.Fatalf("failures %d after reset", rec.Failures)
		}
	})
}

func TestStoreDevicesForgottenWithPin(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		hash, _ := HashPin("4321")
		s.SetPin(ctx, 7, hash)
		a, b := HashToken("token-a-0123456789"), HashToken("token-b-0123456789")
		s.RememberDevice(ctx, 7, a, t0)
		s.RememberDevice(ctx, 7, a, t0.Add(time.Second)) // twice: kept once
		s.RememberDevice(ctx, 7, b, t0.Add(2*time.Second))
		rec, _ := s.Get(ctx, 7)
		if len(rec.Devices) != 2 || !rec.Remembers(a) || !rec.Remembers(b) || rec.Remembers(HashToken("other-token-01234")) {
			t.Fatalf("devices %d, want a and b", len(rec.Devices))
		}
		// Removing the PIN forgets them; a new PIN starts with none.
		s.ClearPin(ctx, 7)
		s.SetPin(ctx, 7, hash)
		if rec, _ := s.Get(ctx, 7); len(rec.Devices) != 0 {
			t.Fatalf("%d devices survived the PIN's removal", len(rec.Devices))
		}
	})
}

func TestStoreDevicesKeepTheNewest(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		hash, _ := HashPin("4321")
		s.SetPin(ctx, 7, hash)
		for i := 0; i < MaxDevices+3; i++ {
			s.RememberDevice(ctx, 7, HashToken(fmt.Sprintf("token-%02d-0123456789", i)), t0.Add(time.Duration(i)*time.Second))
		}
		rec, _ := s.Get(ctx, 7)
		if len(rec.Devices) != MaxDevices {
			t.Fatalf("%d devices, want %d", len(rec.Devices), MaxDevices)
		}
		if rec.Remembers(HashToken("token-00-0123456789")) || rec.Remembers(HashToken("token-02-0123456789")) {
			t.Error("an oldest device was kept")
		}
		if !rec.Remembers(HashToken(fmt.Sprintf("token-%02d-0123456789", MaxDevices+2))) {
			t.Error("the newest device was dropped")
		}
	})
}

// The lock is in the database: a second store on the same database (a
// restarted server) reads it.
func TestSQLStoreLockSurvivesARestart(t *testing.T) {
	s := openTestSQLStore(t)
	ctx := context.Background()
	hash, _ := HashPin("2468")
	s.SetPin(ctx, 9, hash)
	until := t0.Add(LockFor)
	for i := 0; i < MaxFailures; i++ {
		s.RecordFailure(ctx, 9, MaxFailures, until)
	}
	again, err := NewSQLStore(openTestDB(t))
	if err != nil {
		t.Fatal(err)
	}
	rec, err := again.Get(ctx, 9)
	if err != nil || !rec.Locked(t0.Add(29*time.Minute)) || !rec.LockedUntil.Equal(until) {
		t.Fatalf("after a restart: %+v %v, want locked until %v", rec, err, until)
	}
}
