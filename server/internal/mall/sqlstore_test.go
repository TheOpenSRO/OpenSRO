package mall

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

// TestMain holds the shared test-database lock (internal/testdb).
func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	s, err := NewSQLStore(db)
	if err != nil {
		t.Fatalf("NewSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSQLStoreChestAndLog(t *testing.T) {
	ctx := context.Background()
	s := openTestSQLStore(t)
	now := time.Now().Truncate(time.Second)
	a, err := s.AddToChest(ctx, ChestEntry{Owner: 1, ItemID: 501, Quantity: 5, OptLevel: 3, Variance: 99,
		Data: 12, MagParams: []uint64{7, 8}, From: FromItemMall, At: now})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := s.AddToChest(ctx, ChestEntry{Owner: 1, ItemID: 502, Quantity: 1, From: FromItemMall, At: now})
	es, err := s.Chest(ctx, 1)
	if err != nil || len(es) != 2 || es[0].ID != a || es[0].Variance != 99 || len(es[0].MagParams) != 2 || es[0].Data != 12 {
		t.Fatalf("chest %+v %v", es, err)
	}
	boom := errors.New("boom")
	err = txn.For(s).Run(ctx, func(ctx context.Context) error {
		if _, err := s.TakeFromChest(ctx, 1, a, now); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatal(err)
	}
	if es, _ := s.Chest(ctx, 1); len(es) != 2 {
		t.Fatal("a rolled-back take removed the entry")
	}
	if _, err := s.TakeFromChest(ctx, 2, a, now); !errors.Is(err, ErrNoSuchEntry) {
		t.Fatal("another character took the entry")
	}
	if got, err := s.TakeFromChest(ctx, 1, a, now); err != nil || got.OptLevel != 3 || got.MagParams[1] != 8 {
		t.Fatal(got, err)
	}
	if _, err := s.TakeFromChest(ctx, 1, a, now); !errors.Is(err, ErrNoSuchEntry) {
		t.Fatal("taken twice")
	}
	s.TakeFromChest(ctx, 1, b, now.Add(time.Minute))
	l, err := s.TakeLog(ctx, 1, now.Add(-time.Hour))
	if err != nil || len(l) != 2 || l[0].ItemID != 502 || !l[1].At.Equal(now) {
		t.Fatalf("log %+v %v", l, err)
	}
	if n, _ := s.PruneTakeLog(ctx, now.Add(30*time.Second)); n != 1 {
		t.Fatalf("pruned %d", n)
	}
	s.RecordPurchase(ctx, Purchase{AccountID: 3, PackageCode: "P", Pay: Payment{Own: 5, Gift: 7}, At: now.Add(-48 * time.Hour)})
	s.RecordPurchase(ctx, Purchase{AccountID: 3, PackageCode: "P", Pay: Payment{Point: 2}, At: now})
	if rows, _ := s.Purchases(ctx, 3, now.Add(-72*time.Hour)); len(rows) != 2 || rows[0].Offset != 12 || rows[1].Offset != 2 {
		t.Fatalf("purchases %+v", rows)
	}
}
