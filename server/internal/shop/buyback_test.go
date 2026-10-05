package shop

import (
	"context"
	"errors"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Round 728 (review): a sale is booked at the back, the sell answers the
// book's size, and the buy back costs max(paid, SellPrice x count), lands the
// same instance in the FIRST EMPTY slot unmerged, and leaves the book.
func TestSellBooksTheSaleAndBuybackReturnsItAtTheSalePrice(t *testing.T) {
	ctx := context.Background()
	items := stubItems{100: {ID: 100, SellPrice: 210, CanSell: true, MaxStack: 50}, 200: {ID: 200, SellPrice: 427, CanSell: true}}
	svc, chars, characterID := newTestService(t, items)

	if err := svc.Inv.AddItem(ctx, characterID, 100, 5); err != nil {
		t.Fatal(err)
	}
	_, size, err := svc.SellBooked(ctx, characterID, 0, 3)
	if err != nil || size != 1 {
		t.Fatalf("SellBooked: size %d, %v; want 1", size, err)
	}
	book := svc.soldList(characterID)
	if len(book) != 1 || book[0].ItemID != 100 || book[0].Quantity != 3 || book[0].Price != 630 {
		t.Fatalf("book %+v, want one entry 3x item 100 for 630", book)
	}
	before, _ := chars.GetByID(ctx, characterID)
	got, err := svc.Buyback(ctx, characterID, 0)
	if err != nil || got.Paid != 630 || got.Quantity != 3 || got.Slot != 1 {
		t.Fatalf("Buyback = %+v, %v; want 630 paid, 3 into slot 1 (the first empty)", got, err)
	}
	after, _ := chars.GetByID(ctx, characterID)
	if before.Gold-after.Gold != 630 {
		t.Fatalf("gold went %d -> %d, want -630", before.Gold, after.Gold)
	}
	if len(svc.soldList(characterID)) != 0 {
		t.Fatal("a bought-back entry should leave the book")
	}
	inv, _ := svc.Inv.List(ctx, characterID)
	at := map[int]int{}
	for _, sl := range inv {
		at[sl.Index] = sl.Quantity
	}
	if at[0] != 2 || at[1] != 3 {
		t.Fatalf("bag %v, want 2 in slot 0 and the 3 unmerged in slot 1", at)
	}
}

// The never-booked set (gs:0x6b2950): sold, not booked, byte 0xFF.
func TestNeverBookedItemsAreSoldButNotBooked(t *testing.T) {
	ctx := context.Background()
	items := stubItems{
		300: {ID: 300, SellPrice: 5, CanSell: true, TypeID1: 3, TypeID2: 3, TypeID3: 8},
		301: {ID: 301, SellPrice: 5, CanSell: true, CodeName: "ITEM_QSP_X"},
	}
	svc, _, characterID := newTestService(t, items)
	for _, id := range []int64{300, 301} {
		if err := svc.Inv.AddItem(ctx, characterID, id, 1); err != nil {
			t.Fatal(err)
		}
		inv, _ := svc.Inv.List(ctx, characterID)
		_, size, err := svc.SellBooked(ctx, characterID, inv[0].Index, 1)
		if err != nil || size != NotBooked {
			t.Fatalf("item %d: size %#x, %v; want 0xFF", id, size, err)
		}
	}
	if len(svc.soldList(characterID)) != 0 {
		t.Fatal("never-booked sales must not reach the book")
	}
	for _, c := range []struct {
		it   refdata.Item
		want bool
	}{
		{refdata.Item{TypeID1: 3, TypeID2: 2, TypeID3: 1}, true},
		{refdata.Item{TypeID1: 3, TypeID2: 1, TypeID3: 13}, true},
		{refdata.Item{TypeID1: 3, TypeID2: 1, TypeID3: 6}, false},
		{refdata.Item{TypeID1: 3, TypeID2: 3, TypeID3: 1, CodeName: "ITEM_ETC_HP_POTION_05"}, false},
		{refdata.Item{CodeName: "ITEM_ETC_E060227_X"}, true},
		{refdata.Item{CodeName: "SN_ITEM_ETC_TAIWAN_50000_GOLD"}, true},
	} {
		if got := NeverBooked(&c.it); got != c.want {
			t.Errorf("NeverBooked(%+v) = %v, want %v", c.it, got, c.want)
		}
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
	book := svc.soldList(characterID)
	if len(book) != BuybackSlots {
		t.Fatalf("book holds %d, want %d", len(book), BuybackSlots)
	}
	for i, want := range []int64{3, 4, 5, 6, 7} {
		if book[i].ItemID != want {
			t.Fatalf("book[%d] = item %d, want %d (oldest first)", i, book[i].ItemID, want)
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
	if len(svc.soldList(characterID)) != 1 {
		t.Fatal("a refused buy back must keep its entry")
	}
	// A full bag refuses before any gold moves (0x1807).
	if err := chars.AddGold(ctx, characterID, 20_000_000); err != nil {
		t.Fatal(err)
	}
	svc.Inv.(interface{ SetCapacity(int) }).SetCapacity(1)
	if err := svc.Inv.AddItem(ctx, characterID, 100, 1); err != nil {
		t.Fatal(err)
	}
	c, _ = chars.GetByID(ctx, characterID)
	if _, err := svc.Buyback(ctx, characterID, 0); !errors.Is(err, ErrBagFull) {
		t.Fatalf("full bag: %v, want ErrBagFull", err)
	}
	if c2, _ := chars.GetByID(ctx, characterID); c2.Gold != c.Gold || len(svc.soldList(characterID)) != 1 {
		t.Fatal("a full-bag refusal must move no gold and keep the entry")
	}
}
