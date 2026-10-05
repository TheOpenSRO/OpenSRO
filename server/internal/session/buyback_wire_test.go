package session

import "testing"

// Round 728's messages round-trip, and the move request's count is optional:
// an older client's 3-field request still decodes as a whole-stack move.
func TestBuybackAndSplitWire(t *testing.T) {
	list := &ShopBuybackListResult{Entries: []ShopBuybackEntry{{ItemID: 7, Quantity: 3, Unit: 210}, {ItemID: 9, Quantity: 1, Unit: 427}}}
	got, err := DecodeShopBuybackListResult(list.Encode())
	if err != nil || len(got.Entries) != 2 || got.Entries[0] != list.Entries[0] || got.Entries[1] != list.Entries[1] {
		t.Fatalf("list round trip: %+v, %v", got, err)
	}
	req, err := DecodeShopBuybackRequest((&ShopBuybackRequest{CharacterName: "Aria", Index: 4}).Encode())
	if err != nil || req.CharacterName != "Aria" || req.Index != 4 {
		t.Fatalf("request round trip: %+v, %v", req, err)
	}
	res, err := DecodeShopBuybackResult((&ShopBuybackResult{OK: true, GoldPaid: 630}).Encode())
	if err != nil || !res.OK || res.GoldPaid != 630 {
		t.Fatalf("result round trip: %+v, %v", res, err)
	}

	move, err := DecodeInventoryMoveRequest((&InventoryMoveRequest{CharacterName: "Aria", From: 2, To: 9, Count: 1}).Encode())
	if err != nil || move.From != 2 || move.To != 9 || move.Count != 1 {
		t.Fatalf("move with a count: %+v, %v", move, err)
	}
	whole, err := DecodeInventoryMoveRequest((&InventoryMoveRequest{CharacterName: "Aria", From: 2, To: 9}).Encode())
	if err != nil || whole.Count != 0 {
		t.Fatalf("move without a count: %+v, %v", whole, err)
	}
}
