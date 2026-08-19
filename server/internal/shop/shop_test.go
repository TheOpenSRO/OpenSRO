package shop

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

func testDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

// stubItems is a fixed-answer ItemLookup for tests.
type stubItems map[int64]*refdata.Item

func (s stubItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	item, ok := s[id]
	if !ok {
		return nil, errors.New("no such item")
	}
	return item, nil
}

func TestPriceIsDeterministicAndScalesWithStats(t *testing.T) {
	cheap := &refdata.Item{ID: 1}
	strong := &refdata.Item{ID: 2, PhysAttackMax: 50, PhysDefenseMax: 20}

	if Price(cheap) != basePrice {
		t.Fatalf("a stat-less item should cost exactly basePrice, got %d", Price(cheap))
	}
	if Price(strong) <= Price(cheap) {
		t.Fatalf("an item with higher stats should cost more: cheap=%d strong=%d", Price(cheap), Price(strong))
	}
	// Deterministic: same input, same output.
	if Price(strong) != Price(strong) {
		t.Fatal("Price should be a pure function of the item's stats")
	}
}

func newTestService(t *testing.T, items stubItems) (*Service, character.Store, int64) {
	t.Helper()
	ctx := context.Background()

	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	inv, err := inventory.OpenSQLStore(testDSN(), stubMaxStacksFor(items))
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	t.Cleanup(func() { inv.Close() })

	return &Service{Gold: chars, Inv: inv, Items: items}, chars, c.ID
}

// stubMaxStacksFor derives an inventory.MaxStackLookup from the same item
// catalog, defaulting to a generous stack size since shop tests care about
// pricing/gold, not stacking behavior.
type stubMaxStacksFor stubItems

func (s stubMaxStacksFor) GetMaxStack(ctx context.Context, itemID int64) (int, error) {
	if _, err := stubItems(s).GetItem(ctx, itemID); err != nil {
		return 0, err
	}
	return 100, nil
}

func TestBuyDeductsGoldAndAddsItem(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100}} // costs basePrice = 100
	svc, chars, characterID := newTestService(t, items)

	if err := svc.Buy(ctx, characterID, 100, 1); err != nil {
		t.Fatalf("Buy: %v", err)
	}

	list, _ := chars.ListByAccount(ctx, 1)
	if list[0].Gold != character.StartingGold-basePrice {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, character.StartingGold-basePrice)
	}

	invList, err := svc.Inv.List(ctx, characterID)
	if err != nil {
		t.Fatalf("Inv.List: %v", err)
	}
	if len(invList) != 1 || invList[0].ItemID != 100 || invList[0].Quantity != 1 {
		t.Fatalf("got %+v, want a single slot with 1x item 100", invList)
	}
}

func TestBuyMultipleQuantity(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100}}
	svc, chars, characterID := newTestService(t, items)

	if err := svc.Buy(ctx, characterID, 100, 3); err != nil {
		t.Fatalf("Buy: %v", err)
	}

	list, _ := chars.ListByAccount(ctx, 1)
	wantGold := int64(character.StartingGold) - basePrice*3
	if list[0].Gold != wantGold {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, wantGold)
	}
}

func TestBuyInsufficientGoldDoesNotAddItem(t *testing.T) {
	ctx := context.Background()
	// An expensive item the starting gold can't cover.
	items := stubItems{100: {ID: 100, PhysAttackMax: 100000}}
	svc, chars, characterID := newTestService(t, items)

	err := svc.Buy(ctx, characterID, 100, 1)
	if !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("got %v, want wrapped ErrInsufficientGold", err)
	}

	list, _ := chars.ListByAccount(ctx, 1)
	if list[0].Gold != character.StartingGold {
		t.Fatalf("gold should be unchanged on failed purchase, got %d", list[0].Gold)
	}
	invList, _ := svc.Inv.List(ctx, characterID)
	if len(invList) != 0 {
		t.Fatalf("no item should have been added on failed purchase, got %+v", invList)
	}
}

func TestBuyNonexistentItem(t *testing.T) {
	ctx := context.Background()
	svc, _, characterID := newTestService(t, stubItems{})

	err := svc.Buy(ctx, characterID, 999, 1)
	if !errors.Is(err, ErrItemNotFound) {
		t.Fatalf("got %v, want ErrItemNotFound", err)
	}
}
