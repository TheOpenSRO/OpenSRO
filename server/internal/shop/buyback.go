package shop

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Buy back (round 728, reworked by its review onto the retail rules).
//
// READ in SR_GameServer.exe (docs/rounds/r728_review.md):
//   - The book is a vector on the PC object (0xE8-byte entries), appended by
//     GObjPC 0x42af00 and read by the buy back 0x42aae0; it is serialized only
//     by CGObjPC vslot 291/292 (0x42aa80 / 0x42a9f0), capped at 5 there too.
//     There is no DB table for the book: AQ_StorageUpdater::RestoreSoldItem
//     (0x45bb60) writes the RESTORED item's row during a buy back. Ours is in
//     memory per character; that it survives a relog is OURS (whether the
//     vslot 291/292 stream crosses a logout was not read).
//   - The sell (0x6194e0) books a sale unless the item is in the never-booked
//     set (0x61b820, filled by ReferenceData 0x6b2950; NeverBooked below), and
//     its result carries the book's new size, 1..5, or 0xFF when not booked.
//   - 0x42af00 drops the FRONT (oldest) entry when 5 are held and appends the
//     new one at the back, so index 0 is the oldest.
//   - An entry's price is max(the gold actually paid, SellPrice x count)
//     (0x6194e0: uVar7 = max(local_74, ref+0xb0 x count)).
//   - The buy back (0x42aae0): an index past the book refuses 0x18d3; no
//     empty bag slot (CGStorage::FindFirstEmptySlot) refuses 0x1807 before
//     any gold moves; short of gold 0x180f; the item goes into that slot by
//     SetItem -- never merged; the item not creatable 0x1842, the DB post
//     failing 0x1811. The whole entry comes back (the request carries no
//     count).

// BuybackSlots is how many sales the book keeps (READ: 0x42af00 `== 5`, the
// client's 0x78d900 `4 < size`).
const BuybackSlots = 5

// NotBooked is the sell result's book byte for a sale that was not booked.
const NotBooked byte = 0xFF

var (
	// ErrNoSuchBuyback: an index past the book (0x18d3).
	ErrNoSuchBuyback = errors.New("shop: nothing to buy back there")
	// ErrBagFull: no empty bag slot for the bought-back item (0x1807).
	ErrBagFull = errors.New("shop: no empty bag slot")
	// ErrBuybackCreate: the item could not be placed (0x1842).
	ErrBuybackCreate = errors.New("shop: the bought-back item could not be created")
)

// Sold is one booked sale.
type Sold struct {
	ItemID   int64
	Quantity int
	// Price is what buying it back costs: max(the gold the sale paid,
	// SellPrice x Quantity) (READ, see above).
	Price int64
	// Inst is the instance that was sold, so the same item comes back.
	Inst inventory.Instance
}

// neverBookedPrefixes are the CodeName prefixes ReferenceData 0x6b2950 puts in
// the never-booked set (READ, r728_review.md F5).
var neverBookedPrefixes = []string{"ITEM_QNO", "ITEM_QTUTORIAL", "ITEM_QSP", "ITEM_QCX", "ITEM_ETC_E", "SN_ITEM_EVENT"}

// NeverBooked reports whether a sale of item is never booked for buy back
// (gs:0x61b820, filled by ReferenceData 0x6b2950): TypeID 3/3/8 (unless
// bionic -- itemdata's Bionic is not carried in refdata, so not tested
// here), any 3/2/x, 3/1/13, or a CodeName starting with one of
// neverBookedPrefixes or equal to SN_ITEM_ETC_TAIWAN_50000_GOLD.
func NeverBooked(item *refdata.Item) bool {
	if item == nil {
		return false
	}
	if item.TypeID1 == 3 {
		switch {
		case item.TypeID2 == 3 && item.TypeID3 == 8,
			item.TypeID2 == 2,
			item.TypeID2 == 1 && item.TypeID3 == 13:
			return true
		}
	}
	if item.CodeName == "SN_ITEM_ETC_TAIWAN_50000_GOLD" {
		return true
	}
	for _, p := range neverBookedPrefixes {
		if strings.HasPrefix(item.CodeName, p) {
			return true
		}
	}
	return false
}

// recordSold books e at the back, dropping the oldest when the book is full,
// and returns the book's new size.
func (s *Service) recordSold(characterID int64, e Sold) byte {
	s.soldMu.Lock()
	defer s.soldMu.Unlock()
	if s.sold == nil {
		s.sold = make(map[int64][]Sold)
	}
	book := s.sold[characterID]
	if len(book) >= BuybackSlots {
		book = book[len(book)-BuybackSlots+1:]
	}
	book = append(append([]Sold(nil), book...), e)
	s.sold[characterID] = book
	return byte(len(book))
}

// soldList returns characterID's book, oldest first (a copy).
func (s *Service) soldList(characterID int64) []Sold {
	s.soldMu.Lock()
	defer s.soldMu.Unlock()
	return append([]Sold(nil), s.sold[characterID]...)
}

// Bought is a buy back's outcome: where the item went and what it cost.
type Bought struct {
	Slot     int
	Quantity int
	Paid     int64
}

// Buyback buys entry index (0 = the oldest) of characterID's book back, in
// the retail order: the index, the first empty bag slot, the gold, then the
// item into that slot. Every refusal leaves the gold and the book as they
// were.
func (s *Service) Buyback(ctx context.Context, characterID int64, index int) (Bought, error) {
	s.soldMu.Lock()
	book := s.sold[characterID]
	if index < 0 || index >= len(book) {
		s.soldMu.Unlock()
		return Bought{}, ErrNoSuchBuyback
	}
	e := book[index]
	// Out of the book under the lock, so two requests cannot both buy the same
	// entry; put back below if the purchase fails.
	s.sold[characterID] = append(append([]Sold(nil), book[:index]...), book[index+1:]...)
	s.soldMu.Unlock()

	putBack := func() {
		s.soldMu.Lock()
		defer s.soldMu.Unlock()
		cur := s.sold[characterID]
		at := index
		if at > len(cur) {
			at = len(cur)
		}
		restored := append(append(append([]Sold(nil), cur[:at]...), e), cur[at:]...)
		if len(restored) > BuybackSlots {
			restored = restored[len(restored)-BuybackSlots:]
		}
		s.sold[characterID] = restored
	}

	placer, ok := s.Inv.(inventory.Placer)
	if !ok {
		putBack()
		return Bought{}, ErrBuybackCreate
	}
	slot, err := inventory.FirstEmptySlot(ctx, s.Inv, placer, characterID)
	if err != nil {
		putBack()
		return Bought{}, fmt.Errorf("shop: reading the bag: %w", err)
	}
	if slot < 0 {
		putBack()
		return Bought{}, ErrBagFull
	}
	if err := s.Gold.DeductGold(ctx, characterID, e.Price); err != nil {
		putBack()
		if errors.Is(err, character.ErrInsufficientGold) {
			return Bought{}, err
		}
		return Bought{}, fmt.Errorf("shop: %w", err)
	}
	if err := placer.PlaceItemInstance(ctx, characterID, slot, e.ItemID, e.Quantity, e.Inst); err != nil {
		putBack()
		if refundErr := s.Gold.AddGold(ctx, characterID, e.Price); refundErr != nil {
			return Bought{}, fmt.Errorf("shop: buy back failed (%w) AND refund failed (%v)", err, refundErr)
		}
		return Bought{}, fmt.Errorf("%w: %v", ErrBuybackCreate, err)
	}
	return Bought{Slot: slot, Quantity: e.Quantity, Paid: e.Price}, nil
}
