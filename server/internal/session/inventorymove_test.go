package session

import "testing"

// The move request must survive a round trip (name plus two slot indices),
// and a truncated one must fail cleanly rather than read past the end.
func TestInventoryMoveRequestRoundTrip(t *testing.T) {
	req := &InventoryMoveRequest{CharacterName: "Aria", From: 3, To: 27}
	got, err := DecodeInventoryMoveRequest(req.Encode())
	if err != nil {
		t.Fatalf("DecodeInventoryMoveRequest: %v", err)
	}
	if got.CharacterName != "Aria" || got.From != 3 || got.To != 27 {
		t.Fatalf("got %+v, want Aria/3/27", got)
	}

	// A negative index is carried as-is; refusing it is the store's job
	// (ErrInvalidSlot), not the decoder's.
	neg := &InventoryMoveRequest{CharacterName: "Aria", From: -1, To: 0}
	gotNeg, err := DecodeInventoryMoveRequest(neg.Encode())
	if err != nil || gotNeg.From != -1 {
		t.Fatalf("got %+v (err %v), want From -1 preserved", gotNeg, err)
	}

	full := req.Encode()
	if _, err := DecodeInventoryMoveRequest(full[:len(full)-8]); err == nil {
		t.Fatalf("a request missing its To field decoded without error")
	}
	if _, err := DecodeInventoryMoveRequest(full[:2]); err == nil {
		t.Fatalf("a request with only a length prefix decoded without error")
	}
}

// The reply is an InventoryListResult, so the client's existing list decoder
// reads it: check the shape this handler actually sends.
func TestInventoryMoveResultIsAListResult(t *testing.T) {
	res := &InventoryListResult{Slots: []InventorySlotSnapshot{{Slot: 9, ItemID: 3639, Quantity: 1}}}
	got, err := DecodeInventoryListResult(res.Encode())
	if err != nil {
		t.Fatalf("DecodeInventoryListResult: %v", err)
	}
	if got.Error != "" || len(got.Slots) != 1 || got.Slots[0] != res.Slots[0] {
		t.Fatalf("got %+v, want %+v", got, res)
	}
	fail := &InventoryListResult{Error: "slot is empty"}
	gotFail, err := DecodeInventoryListResult(fail.Encode())
	if err != nil || gotFail.Error != "slot is empty" || len(gotFail.Slots) != 0 {
		t.Fatalf("got %+v (err %v), want the error preserved and no slots", gotFail, err)
	}
}
