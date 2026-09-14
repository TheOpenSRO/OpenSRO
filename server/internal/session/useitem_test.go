package session

import "testing"

// The wire format must survive a round trip, and an older/empty tail must not
// blow up the decoder.
func TestUseItemRoundTrip(t *testing.T) {
	req := &UseItemRequest{CharacterName: "Aria", InventorySlot: 7}
	gotReq, err := DecodeUseItemRequest(req.Encode())
	if err != nil {
		t.Fatalf("DecodeUseItemRequest: %v", err)
	}
	if gotReq.CharacterName != "Aria" || gotReq.InventorySlot != 7 {
		t.Fatalf("got %+v, want Aria/7", gotReq)
	}

	res := &UseItemResult{HP: 180, MaxHP: 220, MP: 90, MaxMP: 104, RestoredHP: 120, RestoredMP: 0, Remaining: 4}
	gotRes, err := DecodeUseItemResult(res.Encode())
	if err != nil {
		t.Fatalf("DecodeUseItemResult: %v", err)
	}
	if *gotRes != *res {
		t.Fatalf("got %+v, want %+v", gotRes, res)
	}

	fail := &UseItemResult{Error: "that cannot be used"}
	gotFail, err := DecodeUseItemResult(fail.Encode())
	if err != nil || gotFail.Error != "that cannot be used" {
		t.Fatalf("got %+v (err %v), want the error preserved", gotFail, err)
	}
}
