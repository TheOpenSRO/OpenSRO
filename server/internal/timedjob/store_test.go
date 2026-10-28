package timedjob

import (
	"context"
	"database/sql"
	"os"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// Round 838: the store keeps a row per (character, type, sub, ref), replaces
// it on a second put, lists a character's own rows and deletes one. Both
// stores, the SQL one on the local test database (as the character store's
// tests reach it).
func TestStores(t *testing.T) {
	ctx := context.Background()
	check := func(t *testing.T, s Store) {
		start := time.Unix(1_800_000_000, 0).UTC()
		gold := Job{CharID: 7, Type: TypePremium, Ref: 9278, Key: 9278, Start: start, V1: 28, V2: 10800, V4: 0}
		bfi := Job{CharID: 7, Type: TypeComposite, Sub: "BFI1", Ref: 3847, Key: 35567, Start: start, End: start.Add(2419200 * time.Second)}
		other := Job{CharID: 8, Type: TypeComposite, Sub: "UIL1", Ref: 3769, Key: 35567, Start: start, End: start.Add(86400 * time.Second), V1: 3, V2: 3}
		for _, j := range []Job{gold, bfi, other} {
			if err := s.Put(ctx, j); err != nil {
				t.Fatal(err)
			}
		}
		gold.V2 = 100<<16 | 10700
		if err := s.Put(ctx, gold); err != nil {
			t.Fatal(err)
		}
		got, err := s.List(ctx, 7)
		if err != nil || len(got) != 2 {
			t.Fatalf("list 7: %v %+v", err, got)
		}
		if got[0].Type != TypePremium || got[0].V2 != 100<<16|10700 || !got[0].End.IsZero() || !got[0].Start.Equal(start) {
			t.Errorf("premium row %+v", got[0])
		}
		if got[1].Sub != "BFI1" || !got[1].End.Equal(bfi.End) {
			t.Errorf("BFI1 row %+v", got[1])
		}
		if err := s.Delete(ctx, 7, TypeComposite, "BFI1", 3847); err != nil {
			t.Fatal(err)
		}
		if got, _ := s.List(ctx, 7); len(got) != 1 {
			t.Errorf("after delete %+v", got)
		}
		if got, _ := s.List(ctx, 8); len(got) != 1 || got[0].V1 != 3 {
			t.Errorf("character 8 %+v", got)
		}
	}
	t.Run("mem", func(t *testing.T) { check(t, NewMemStore()) })
	t.Run("sql", func(t *testing.T) {
		dsn := os.Getenv("OPENSRO_TEST_POSTGRES_DSN")
		if dsn == "" {
			dsn = "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
		}
		release := testdb.Lock(dsn)
		defer release()
		db, err := sql.Open("pgx", dsn)
		if err != nil {
			t.Skip(err)
		}
		defer db.Close()
		if err := db.PingContext(ctx); err != nil {
			t.Skipf("no test database: %v", err)
		}
		s, err := NewSQLStore(db)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`TRUNCATE TABLE char_timed_job`); err != nil {
			t.Fatal(err)
		}
		check(t, s)
	})
}
