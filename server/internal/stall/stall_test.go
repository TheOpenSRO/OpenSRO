package stall

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"

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

// The hub's bookkeeping: one stall an owner, the modes (4 owner, 2 visitor),
// seven visitors at most (CheckHasRoom's 8, s:0x4734e0), the leave and the
// close freeing everyone.
func TestHub(t *testing.T) {
	h := NewHub()
	if _, err := h.Open(Member{CharacterID: 1}, "shop", 3847); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Open(Member{CharacterID: 1}, "again", 0); !errors.Is(err, ErrHasStall) {
		t.Fatalf("a second stall: %v", err)
	}
	if h.Mode(1) != ModeOwner || h.Mode(2) != ModeNone || h.StallOf(1) != 1 {
		t.Fatal("the owner's mode")
	}
	for id := int64(2); id <= MaxParticipants; id++ {
		before, s, err := h.Join(1, Member{CharacterID: id})
		if err != nil {
			t.Fatalf("visitor %d: %v", id, err)
		}
		if len(before) != int(id-1) || before[0].CharacterID != 1 || len(s.Visitors) != int(id-1) {
			t.Fatalf("visitor %d: before %d, visitors %d", id, len(before), len(s.Visitors))
		}
	}
	if _, _, err := h.Join(1, Member{CharacterID: 99}); !errors.Is(err, ErrFull) {
		t.Fatalf("an eighth visitor: %v", err)
	}
	if _, _, err := h.Join(1, Member{CharacterID: 2}); !errors.Is(err, ErrInside) {
		t.Fatalf("a visitor twice: %v", err)
	}
	if _, _, err := h.Join(1, Member{CharacterID: 1}); !errors.Is(err, ErrInside) {
		t.Fatalf("the owner as a visitor: %v", err)
	}
	if _, _, err := h.Join(42, Member{CharacterID: 50}); !errors.Is(err, ErrNoStall) {
		t.Fatalf("no stall: %v", err)
	}
	if h.Mode(2) != ModeVisitor || h.StallOf(2) != 1 {
		t.Fatal("a visitor's mode")
	}
	owner, rest, ok := h.Leave(2)
	if !ok || owner != 1 || len(rest) != MaxParticipants-1 || rest[0].CharacterID != 1 {
		t.Fatalf("leave: %d %d %v", owner, len(rest), ok)
	}
	if _, _, ok := h.Leave(2); ok {
		t.Fatal("a second leave")
	}
	s, ok := h.Close(1)
	if !ok || len(s.Visitors) != MaxParticipants-2 || s.Decoration != 3847 {
		t.Fatalf("close: %+v", s)
	}
	for id := int64(1); id <= MaxParticipants; id++ {
		if h.Mode(id) != ModeNone {
			t.Fatalf("%d still in a closed stall", id)
		}
	}
	var nilHub *Hub
	if nilHub.Mode(1) != ModeNone || nilHub.StallOf(1) != 0 || nilHub.Do(1, func(*Stall) {}) {
		t.Fatal("a nil hub holds stalls")
	}
}

func TestStallHelpers(t *testing.T) {
	var s Stall
	if s.FirstFree() != 0 {
		t.Fatal("first free of an empty stall")
	}
	for i := range s.Slots {
		s.Slots[i] = Listing{Used: true, BagSlot: i + 4}
	}
	if s.FirstFree() != -1 || !s.ListedBagSlot(7) || s.ListedBagSlot(2) {
		t.Fatal("a full stall's helpers")
	}
}

// Both stores keep a sale, list it for seller and buyer, and drop it when
// the action it belongs to rolls back.
func TestSaleStores(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	sqlStore, err := NewSQLStore(db)
	if err != nil {
		t.Fatalf("NewSQLStore: %v (is postgres running?)", err)
	}
	// The schema is idempotent.
	if _, err := NewSQLStore(db); err != nil {
		t.Fatalf("a second migration: %v", err)
	}
	if err := sqlStore.TruncateForTest(ctx); err != nil {
		t.Fatal(err)
	}
	for name, s := range map[string]SaleStore{"mem": NewMemStore(), "sql": sqlStore} {
		run := txn.For(s)
		if err := run.Run(ctx, func(ctx context.Context) error {
			return s.RecordSale(ctx, Sale{SellerID: 1, BuyerID: 2, ItemID: 100, Quantity: 1, Price: 50, Slot: 3, BagSlot: 4, ToSlot: 5})
		}); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		boom := errors.New("rolled back")
		if err := run.Run(ctx, func(ctx context.Context) error {
			if err := s.RecordSale(ctx, Sale{SellerID: 1, BuyerID: 3, ItemID: 200, Quantity: 2, Price: 9}); err != nil {
				return err
			}
			return boom
		}); !errors.Is(err, boom) {
			t.Fatalf("%s: %v", name, err)
		}
		for _, who := range []int64{1, 2} {
			got, err := s.Sales(ctx, who, 0)
			if err != nil || len(got) != 1 || got[0].ItemID != 100 || got[0].Price != 50 || got[0].Slot != 3 ||
				got[0].BagSlot != 4 || got[0].ToSlot != 5 || got[0].SoldAt.IsZero() {
				t.Fatalf("%s: %d's sales %+v %v", name, who, got, err)
			}
		}
		if got, _ := s.Sales(ctx, 3, 0); len(got) != 0 {
			t.Fatalf("%s: the rolled-back sale stayed: %+v", name, got)
		}
	}
}
