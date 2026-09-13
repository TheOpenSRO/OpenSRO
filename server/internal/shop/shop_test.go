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

func (s stubItems) ListAll(_ context.Context) ([]*refdata.Item, error) {
	out := make([]*refdata.Item, 0, len(s))
	for _, item := range s {
		out = append(out, item)
	}
	return out, nil
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

func TestSellCreditsGoldAndRemovesItem(t *testing.T) {
	ctx := context.Background()
	// Buys at 200, sells back at its real SellPrice 80.
	items := stubItems{100: {ID: 100, Price: 200, SellPrice: 80}}
	svc, chars, characterID := newTestService(t, items)

	if err := svc.Buy(ctx, characterID, 100, 2); err != nil {
		t.Fatalf("Buy: %v", err)
	}
	invList, _ := svc.Inv.List(ctx, characterID)
	if len(invList) != 1 {
		t.Fatalf("expected one stacked slot after buying, got %+v", invList)
	}
	slot := invList[0].Index

	gold, err := svc.Sell(ctx, characterID, slot, 1)
	if err != nil {
		t.Fatalf("Sell: %v", err)
	}
	if gold != 80 {
		t.Fatalf("Sell credited %d, want the real SellPrice 80", gold)
	}
	list, _ := chars.ListByAccount(ctx, 1)
	// Started, spent 2*200 buying, got 80 back selling one.
	wantGold := int64(character.StartingGold) - 400 + 80
	if list[0].Gold != wantGold {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, wantGold)
	}
	after, _ := svc.Inv.List(ctx, characterID)
	if len(after) != 1 || after[0].Quantity != 1 {
		t.Fatalf("expected 1 left in the slot after selling one, got %+v", after)
	}
}

func TestSellEmptySlotFails(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100, SellPrice: 80}}
	svc, _, characterID := newTestService(t, items)

	if _, err := svc.Sell(ctx, characterID, 5, 1); !errors.Is(err, ErrSlotEmpty) {
		t.Fatalf("Sell of an empty slot: got %v, want ErrSlotEmpty", err)
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

func TestCatalogListsEveryItemWithComputedPrice(t *testing.T) {
	ctx := context.Background()
	items := stubItems{
		100: {ID: 100, PhysAttackMax: 30},
		200: {ID: 200, PhysDefenseMax: 20},
	}
	svc, _, _ := newTestService(t, items)

	entries, err := svc.Catalog(ctx)
	if err != nil {
		t.Fatalf("Catalog: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2", len(entries))
	}

	byID := make(map[int64]CatalogEntry, len(entries))
	for _, e := range entries {
		byID[e.ItemID] = e
	}
	if byID[100].Price != Price(items[100]) || byID[100].PhysAttackMax != 30 {
		t.Fatalf("unexpected entry for item 100: %+v", byID[100])
	}
	if byID[200].Price != Price(items[200]) || byID[200].PhysDefenseMax != 20 {
		t.Fatalf("unexpected entry for item 200: %+v", byID[200])
	}
}

func TestPricePrefersRealPriceOverFormula(t *testing.T) {
	// A stat-carrying item whose real price is set uses the real price, not
	// the stat formula.
	real := &refdata.Item{ID: 1, PhysAttackMax: 50, Price: 890}
	if Price(real) != 890 {
		t.Fatalf("Price = %d, want the real 890", Price(real))
	}
	// With no real price, it falls back to the formula.
	noPrice := &refdata.Item{ID: 2, PhysAttackMax: 50}
	if Price(noPrice) != basePrice+int64(50*statMultiplier) {
		t.Fatalf("Price = %d, want the formula fallback", Price(noPrice))
	}
}

func TestSellValueUsesRealSellPriceElseFraction(t *testing.T) {
	real := &refdata.Item{ID: 1, Price: 890, SellPrice: 427}
	if SellValue(real) != 427 {
		t.Fatalf("SellValue = %d, want the real 427", SellValue(real))
	}
	// No real sell price: a disclosed fraction of the buy price.
	noSell := &refdata.Item{ID: 2, Price: 890}
	if SellValue(noSell) != 890/sellFallbackDivisor {
		t.Fatalf("SellValue = %d, want the fallback fraction", SellValue(noSell))
	}
}

func TestCatalogForReturnsOnlyRequestedResolvableItems(t *testing.T) {
	ctx := context.Background()
	items := stubItems{
		100: {ID: 100, PhysAttackMax: 30},
		200: {ID: 200, PhysDefenseMax: 20},
		300: {ID: 300},
	}
	svc, _, _ := newTestService(t, items)

	// Ask for two real ids and one that doesn't exist; the missing one is
	// skipped, not an error.
	entries, err := svc.CatalogFor(ctx, []int64{100, 999, 300})
	if err != nil {
		t.Fatalf("CatalogFor: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2 (100 and 300; 999 skipped)", len(entries))
	}
	if entries[0].ItemID != 100 || entries[0].Price != Price(items[100]) {
		t.Fatalf("first entry should be item 100 at its price, got %+v", entries[0])
	}
	if entries[1].ItemID != 300 {
		t.Fatalf("second entry should be item 300, got %+v", entries[1])
	}
	// An empty request returns nothing (never the whole catalogue).
	empty, err := svc.CatalogFor(ctx, nil)
	if err != nil || len(empty) != 0 {
		t.Fatalf("CatalogFor(nil) = (%+v, %v), want empty", empty, err)
	}
}
