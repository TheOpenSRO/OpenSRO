package shop

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Round 728: every sale is booked newest first, the book holds BuybackSlots,
// and buying back costs what the sale paid (unit x count) and returns the item.
func TestSellBooksTheSaleAndBuybackReturnsItAtTheSalePrice(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100, SellPrice: 210, CanSell: true}, 200: {ID: 200, SellPrice: 427, CanSell: true}}
	svc, chars, characterID := newTestService(t, items)

	if err := svc.Inv.AddItem(ctx, characterID, 100, 5); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Sell(ctx, characterID, 0, 3); err != nil {
		t.Fatalf("Sell: %v", err)
	}
	book := svc.SoldList(characterID)
	if len(book) != 1 || book[0].ItemID != 100 || book[0].Quantity != 3 || book[0].Unit != 210 || book[0].Cost() != 630 {
		t.Fatalf("book %+v, want one entry 3x item 100 at 210 (630)", book)
	}
	before, _ := chars.GetByID(ctx, characterID)
	paid, err := svc.Buyback(ctx, characterID, 0)
	if err != nil || paid != 630 {
		t.Fatalf("Buyback = %d, %v; want 630", paid, err)
	}
	after, _ := chars.GetByID(ctx, characterID)
	if before.Gold-after.Gold != 630 {
		t.Fatalf("gold went %d -> %d, want -630", before.Gold, after.Gold)
	}
	if len(svc.SoldList(characterID)) != 0 {
		t.Fatal("a bought-back entry should leave the book")
	}
	inv, _ := svc.Inv.List(ctx, characterID)
	total := 0
	for _, sl := range inv {
		if sl.ItemID == 100 {
			total += sl.Quantity
		}
	}
	if total != 5 {
		t.Fatalf("bag holds %d of item 100 after the buy back, want 5", total)
	}
}

func TestBuybackBookKeepsTheNewestFive(t *testing.T) {
	ctx := context.Background()
	items := stubItems{}
	for id := int64(1); id <= 7; id++ {
		items[id] = &refdata.Item{ID: id, SellPrice: id * 10, CanSell: true}
	}
	svc, _, characterID := newTestService(t, items)
	for id := int64(1); id <= 7; id++ {
		if err := svc.Inv.AddItem(ctx, characterID, id, 1); err != nil {
			t.Fatal(err)
		}
		inv, _ := svc.Inv.List(ctx, characterID)
		slot := -1
		for _, sl := range inv {
			if sl.ItemID == id {
				slot = sl.Index
			}
		}
		if _, err := svc.Sell(ctx, characterID, slot, 1); err != nil {
			t.Fatalf("selling %d: %v", id, err)
		}
	}
	book := svc.SoldList(characterID)
	if len(book) != BuybackSlots {
		t.Fatalf("book holds %d, want %d", len(book), BuybackSlots)
	}
	for i, want := range []int64{7, 6, 5, 4, 3} {
		if book[i].ItemID != want {
			t.Fatalf("book[%d] = item %d, want %d (newest first)", i, book[i].ItemID, want)
		}
	}
}

func TestBuybackRefusals(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100, SellPrice: 1_000_000, CanSell: true}}
	svc, chars, characterID := newTestService(t, items)
	if _, err := svc.Buyback(ctx, characterID, 0); !errors.Is(err, ErrNoSuchBuyback) {
		t.Fatalf("empty book: %v, want ErrNoSuchBuyback", err)
	}
	if err := svc.Inv.AddItem(ctx, characterID, 100, 10); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Sell(ctx, characterID, 0, 10); err != nil {
		t.Fatal(err)
	}
	// Spend the proceeds, so the 10,000,000 buy back cannot be afforded.
	c, _ := chars.GetByID(ctx, characterID)
	if err := chars.DeductGold(ctx, characterID, c.Gold); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Buyback(ctx, characterID, 0); !errors.Is(err, character.ErrInsufficientGold) {
		t.Fatalf("short of gold: %v, want ErrInsufficientGold", err)
	}
	if len(svc.SoldList(characterID)) != 1 {
		t.Fatal("a refused buy back must keep its entry")
	}
}
