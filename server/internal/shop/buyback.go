package shop

import (
	"context"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// Buy back (round 728): the store's "Buy back" row.
//
// What is READ, in the client (sro_client.exe):
//   - The row is the RENEWAL store's five slots under `UIIT_STT_RE_BUY_OBJECT`
//     (ifstore.txt's RESTORE_SOLDITEM_INSHOP branch, which config\define.txt
//     turns on; docs/protocol/npc_gui.md).
//   - Buying one back opens MsgBoxStoreConfirm purpose 0x14 (the fill
//     `FUN_006b0520`), whose price is the item reference's 64-bit price at
//     +0xb8 times the slot's count -- the SAME field the sell box (0x6b07d0)
//     prices a sale with (0x6b05a9 / 0x6b0859). So a buy back costs what the
//     sale paid, unit for unit. The fortress tax adjustment (0x6fc910, under
//     0x703fc0) is not modelled: OpenSRO's tax is 0.
//
// What is OURS (the server's own buy-back bookkeeping was not read; the
// GameServer's `AQ_StorageUpdater::RestoreSoldItem` 0x45bb60 shows retail keeps
// it in the DATABASE, through the _STRG_RESTORE_SOLDITEM_* procedures):
//   - the book is kept in memory: it survives a relog or a zone change, but
//     not a server restart;
//   - BuybackSlots entries, newest first, the oldest dropped -- five because the
//     row has five slots (INFERRED);
//   - an entry is a whole sale (the count sold, one slot);
//   - every sale is booked; the client asks before a sale that cannot be
//     bought back (UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL, round 726) by its own
//     table, which the server does not consult.

// BuybackSlots is how many recent sales the book keeps: the store's buy-back
// row holds five (INFERRED from the row, see above).
const BuybackSlots = 5

// ErrNoSuchBuyback is returned by Buyback for an index past the book.
var ErrNoSuchBuyback = errors.New("shop: nothing to buy back there")

// Sold is one booked sale.
type Sold struct {
	ItemID   int64
	Quantity int
	// Unit is the gold one unit sold for (SellValue at the time of sale);
	// buying it back costs Unit x Quantity.
	Unit int64
	// Inst is the instance that was sold, so the same item comes back.
	Inst inventory.Instance
}

// Cost is what buying this entry back costs.
func (e Sold) Cost() int64 { return e.Unit * int64(e.Quantity) }

func (s *Service) recordSold(characterID int64, e Sold) {
	s.soldMu.Lock()
	defer s.soldMu.Unlock()
	if s.sold == nil {
		s.sold = make(map[int64][]Sold)
	}
	book := append([]Sold{e}, s.sold[characterID]...)
	if len(book) > BuybackSlots {
		book = book[:BuybackSlots]
	}
	s.sold[characterID] = book
}

// SoldList returns characterID's book, newest first (a copy).
func (s *Service) SoldList(characterID int64) []Sold {
	s.soldMu.Lock()
	defer s.soldMu.Unlock()
	return append([]Sold(nil), s.sold[characterID]...)
}

// Buyback buys entry index of characterID's book back: the gold (Unit x
// Quantity) is taken first, the same instance is added to the bag, and the
// entry leaves the book. A full bag refunds the gold and keeps the entry.
// Returns the gold paid.
func (s *Service) Buyback(ctx context.Context, characterID int64, index int) (int64, error) {
	s.soldMu.Lock()
	book := s.sold[characterID]
	if index < 0 || index >= len(book) {
		s.soldMu.Unlock()
		return 0, ErrNoSuchBuyback
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
			restored = restored[:BuybackSlots]
		}
		s.sold[characterID] = restored
	}

	cost := e.Cost()
	if err := s.Gold.DeductGold(ctx, characterID, cost); err != nil {
		putBack()
		return 0, fmt.Errorf("shop: %w", err)
	}
	if err := s.Inv.AddItemInstance(ctx, characterID, e.ItemID, e.Quantity, e.Inst); err != nil {
		putBack()
		if refundErr := s.Gold.AddGold(ctx, characterID, cost); refundErr != nil {
			return 0, fmt.Errorf("shop: buy back failed (%w) AND refund failed (%v)", err, refundErr)
		}
		return 0, fmt.Errorf("shop: adding the bought-back item: %w", err)
	}
	return cost, nil
}
