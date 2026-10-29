package stall

import (
	"context"
	"database/sql"
	"testing"
)

// Round 840: the network sale's columns come back from both stores, the
// migration adds them to a table made before them, and the hub's network
// snapshot holds only open, registered stalls.
func TestSaleStoresNetworkColumns(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	// A table from before round 840: the columns are added to it.
	if _, err := db.ExecContext(ctx, `DROP TABLE IF EXISTS stall_sales`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `CREATE TABLE stall_sales (
		id BIGSERIAL PRIMARY KEY, seller_id BIGINT NOT NULL, buyer_id BIGINT NOT NULL, item_id BIGINT NOT NULL,
		quantity INT NOT NULL, serial BIGINT NOT NULL DEFAULT 0, price BIGINT NOT NULL,
		slot SMALLINT NOT NULL DEFAULT 0, bag_slot SMALLINT NOT NULL DEFAULT 0, to_slot SMALLINT NOT NULL DEFAULT 0,
		sold_at TIMESTAMPTZ NOT NULL DEFAULT now())`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO stall_sales (seller_id, buyer_id, item_id, quantity, price) VALUES (7, 8, 1, 1, 5)`); err != nil {
		t.Fatal(err)
	}
	sqlStore, err := NewSQLStore(db)
	if err != nil {
		t.Fatalf("NewSQLStore over an old table: %v", err)
	}
	if old, err := sqlStore.Sales(ctx, 7, 0); err != nil || len(old) != 1 || old[0].Network || old[0].Commission != 0 {
		t.Fatalf("the old row %+v %v", old, err)
	}
	if err := sqlStore.TruncateForTest(ctx); err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]SaleStore{"mem": NewMemStore(), "sql": sqlStore} {
		if err := s.RecordSale(ctx, Sale{SellerID: 1, BuyerID: 2, ItemID: 100, Quantity: 1, Price: 1000, Network: true, Commission: 9}); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		got, err := s.Sales(ctx, 1, 0)
		if err != nil || len(got) != 1 || !got[0].Network || got[0].Commission != 9 {
			t.Fatalf("%s: %+v %v", name, got, err)
		}
	}
	h := NewHub()
	for i, st := range []struct{ open, network bool }{{true, true}, {true, false}, {false, true}} {
		owner := int64(10 + i)
		if _, err := h.Open(Member{CharacterID: owner}, "s", 0); err != nil {
			t.Fatal(err)
		}
		h.Do(owner, func(s *Stall) { s.Open, s.Network = st.open, st.network })
	}
	if got := h.Network(); len(got) != 1 || got[0].Owner.CharacterID != 10 {
		t.Fatalf("the network snapshot %+v", got)
	}
	if a, b := h.NextSeq(), h.NextSeq(); b <= a || a == 0 {
		t.Fatalf("NextSeq %d then %d", a, b)
	}
}
