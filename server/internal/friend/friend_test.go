package friend

import (
	"context"
	"errors"
	"testing"
)

// TestMaxFriendsMatchesTheEngine pins the recovered cap and the strictness of
// its comparison. The engine's check is `jb` on 0x14 -- strictly fewer than 20
// may add -- so 20 is a full list, not a permitted one.
func TestMaxFriendsMatchesTheEngine(t *testing.T) {
	if MaxFriends != 0x14 {
		t.Errorf("MaxFriends = %d, want 0x14 = 20 (the `cmp [esi+0x14],0x14` at 005d7746)", MaxFriends)
	}
}

// TestFriendListFillsToTheCap walks a character to MaxFriends and checks the
// refusal lands exactly there, on both the accepting and the requesting side.
func TestFriendListFillsToTheCap(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()

	// Fill character 1's list to the cap.
	for i := int64(2); i <= MaxFriends+1; i++ {
		if err := m.SendRequest(ctx, i, "R", 1); err != nil {
			t.Fatalf("request from %d: %v", i, err)
		}
		if err := m.AcceptRequest(ctx, 1, "Host", i); err != nil {
			t.Fatalf("accept %d of %d: %v", i-1, MaxFriends, err)
		}
	}

	// One more request may still be sent by a character with room...
	const extra = int64(9000)
	if err := m.SendRequest(ctx, extra, "Late", 1); err != nil {
		t.Fatalf("SendRequest from a character with room: %v", err)
	}
	// ...but accepting it would push character 1 past the cap.
	if err := m.AcceptRequest(ctx, 1, "Host", extra); !errors.Is(err, ErrListFull) {
		t.Errorf("accepting past the cap: got %v, want ErrListFull", err)
	}
	// And the request must survive the refusal rather than being consumed.
	pending, err := m.ListPendingRequests(ctx, 1)
	if err != nil {
		t.Fatalf("ListPendingRequests: %v", err)
	}
	found := false
	for _, r := range pending {
		if r.RequesterID == extra {
			found = true
		}
	}
	if !found {
		t.Error("a refused acceptance must leave the pending request intact")
	}

	// A full character cannot send a request either -- the engine refuses at
	// request time, not only at acceptance.
	if err := m.SendRequest(ctx, 1, "Host", 9001); !errors.Is(err, ErrListFull) {
		t.Errorf("SendRequest from a full list: got %v, want ErrListFull", err)
	}
}
