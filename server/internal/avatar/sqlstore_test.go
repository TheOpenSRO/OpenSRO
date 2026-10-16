package avatar

import (
	"context"
	"database/sql"
	"os"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/testdb"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

// The Postgres avatar inventory makes its own table (the bag's columns,
// serial included), holds five slots and keeps an item's whole instance and
// serial (round 789).
func TestSQLStore(t *testing.T) {
	release := testdb.Lock(testDSN())
	defer release()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	st, err := OpenSQL(db, nil)
	if err != nil {
		t.Fatalf("OpenSQL: %v (is postgres running? see testDSN)", err)
	}
	if _, err := OpenSQL(db, nil); err != nil {
		t.Fatalf("a second open (the migration again): %v", err)
	}
	if _, err := db.Exec(`TRUNCATE TABLE ` + Table); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	inst := inventory.Instance{Variance: 0x1f, Durability: 1_900_000_000, OptLevel: 4,
		MagParams: []uint64{inventory.MagParam(246, 1)}, AdvElixir: 2, Serial: 987654321}
	if err := st.PlaceItemInstance(ctx, 7, 4, 501, 1, inst); err != nil {
		t.Fatal(err)
	}
	if err := st.PlaceItemInstance(ctx, 7, 5, 502, 1, inventory.Instance{}); err == nil {
		t.Fatal("placed in slot 5")
	}
	held, err := st.List(ctx, 7)
	if err != nil || len(held) != 1 || held[0].Index != 4 || !held[0].Instance().Equal(func() inventory.Instance { i := inst; i.Serial = 0; return i }()) {
		t.Fatalf("List = %+v, %v", held, err)
	}
	id, got, err := st.TakeItem(ctx, 7, 4, 1, 501)
	if err != nil || id != 501 || got.Serial != inst.Serial || got.Durability != inst.Durability {
		t.Fatalf("TakeItem = %d %+v, %v", id, got, err)
	}
}
