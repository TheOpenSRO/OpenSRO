package party

import (
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

func member(id uint64, characterID int64, name string) Member {
	return Member{Session: gateway.NewTestSession(id), CharacterID: characterID, Name: name}
}

func TestCreateParty(t *testing.T) {
	h := NewHub()
	p, err := h.Create(member(1, 100, "Aria"))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if p.LeaderID != 100 || len(p.Members) != 1 {
		t.Fatalf("got %+v, want leader=100 with 1 member", p)
	}
}

func TestCreateAlreadyInParty(t *testing.T) {
	h := NewHub()
	m := member(1, 100, "Aria")
	h.Create(m)

	_, err := h.Create(m)
	if !errors.Is(err, ErrAlreadyInParty) {
		t.Fatalf("got %v, want ErrAlreadyInParty", err)
	}
}

func TestJoinParty(t *testing.T) {
	h := NewHub()
	p, _ := h.Create(member(1, 100, "Aria"))

	joined, err := h.Join(p.ID, member(2, 200, "Bram"))
	if err != nil {
		t.Fatalf("Join: %v", err)
	}
	if len(joined.Members) != 2 {
		t.Fatalf("got %+v, want 2 members", joined)
	}
}

func TestJoinNonexistentParty(t *testing.T) {
	h := NewHub()
	_, err := h.Join(999, member(1, 100, "Aria"))
	if !errors.Is(err, ErrPartyNotFound) {
		t.Fatalf("got %v, want ErrPartyNotFound", err)
	}
}

func TestJoinAlreadyInParty(t *testing.T) {
	h := NewHub()
	p1, _ := h.Create(member(1, 100, "Aria"))
	p2, _ := h.Create(member(2, 200, "Bram"))

	_, err := h.Join(p2.ID, member(1, 100, "Aria"))
	if !errors.Is(err, ErrAlreadyInParty) {
		t.Fatalf("got %v, want ErrAlreadyInParty", err)
	}
	_ = p1
}

func TestJoinFullParty(t *testing.T) {
	h := NewHub()
	p, _ := h.Create(member(1, 100, "Leader"))
	for i := int64(1); i < MaxSize; i++ {
		if _, err := h.Join(p.ID, member(uint64(i)+1, 100+i, "Member")); err != nil {
			t.Fatalf("Join #%d: %v", i, err)
		}
	}

	_, err := h.Join(p.ID, member(999, 999, "OneTooMany"))
	if !errors.Is(err, ErrPartyFull) {
		t.Fatalf("got %v, want ErrPartyFull", err)
	}
}

func TestLeavePartyPromotesNextLeader(t *testing.T) {
	h := NewHub()
	p, _ := h.Create(member(1, 100, "Aria"))
	h.Join(p.ID, member(2, 200, "Bram"))

	_, remaining, err := h.Leave(100)
	if err != nil {
		t.Fatalf("Leave: %v", err)
	}
	if remaining == nil || remaining.LeaderID != 200 {
		t.Fatalf("got %+v, want leadership passed to 200", remaining)
	}
}

func TestLeaveLastMemberDisbands(t *testing.T) {
	h := NewHub()
	h.Create(member(1, 100, "Aria"))

	_, remaining, err := h.Leave(100)
	if err != nil {
		t.Fatalf("Leave: %v", err)
	}
	if remaining != nil {
		t.Fatalf("expected the party to be disbanded, got %+v", remaining)
	}

	if _, in := h.Get(100); in {
		t.Fatal("character should no longer be in any party")
	}
}

func TestLeaveNotInParty(t *testing.T) {
	h := NewHub()
	_, _, err := h.Leave(999)
	if !errors.Is(err, ErrNotInParty) {
		t.Fatalf("got %v, want ErrNotInParty", err)
	}
}

func TestLeaveThenRejoin(t *testing.T) {
	h := NewHub()
	p, _ := h.Create(member(1, 100, "Aria"))
	h.Leave(100)

	// Should be able to create/join again after leaving.
	p2, err := h.Create(member(1, 100, "Aria"))
	if err != nil {
		t.Fatalf("re-Create after Leave: %v", err)
	}
	if p2.ID == p.ID {
		t.Fatal("expected a fresh party, not reuse of the disbanded one's ID semantics") // IDs may coincidentally differ; just checking no error path issue
	}
}

func TestGetReturnsCurrentParty(t *testing.T) {
	h := NewHub()
	p, _ := h.Create(member(1, 100, "Aria"))

	got, in := h.Get(100)
	if !in || got.ID != p.ID {
		t.Fatalf("got %+v in=%v, want party %d", got, in, p.ID)
	}
}

func TestGetNotInParty(t *testing.T) {
	h := NewHub()
	if _, in := h.Get(999); in {
		t.Fatal("expected in=false for a character not in any party")
	}
}

func TestLeaveBySession(t *testing.T) {
	h := NewHub()
	h.Create(member(1, 100, "Aria"))
	h.Join(1, member(2, 200, "Bram")) // party ID 1 since it's the hub's first

	cid, pid, remaining, ok, err := h.LeaveBySession(2)
	if err != nil {
		t.Fatalf("LeaveBySession: %v", err)
	}
	if !ok || cid != 200 || pid != 1 {
		t.Fatalf("got cid=%d pid=%d ok=%v, want cid=200 pid=1 ok=true", cid, pid, ok)
	}
	if remaining == nil || len(remaining.Members) != 1 {
		t.Fatalf("got %+v, want 1 member remaining", remaining)
	}

	if _, in := h.Get(200); in {
		t.Fatal("character 200 should no longer be in a party")
	}
}

func TestLeaveBySessionNotInAnyParty(t *testing.T) {
	h := NewHub()
	_, _, _, ok, err := h.LeaveBySession(999)
	if err != nil {
		t.Fatalf("LeaveBySession: %v", err)
	}
	if ok {
		t.Fatal("expected ok=false for a session not in any party")
	}
}

// TestMaxSizeMatchesTheEngine pins the recovered join-time caps. The engine has
// two, selected by bit 0 of the party's flags -- the exp-sharing bit, named by
// the errors each branch raises (MEMBER_FULL_EXP_SHARED_PARTY at 8,
// MEMBER_FULL_NONEEXP_SHARED_PARTY at 4). srrevamp's parties always share
// experience, so 8 is the one that applies.
func TestMaxSizeMatchesTheEngine(t *testing.T) {
	if MaxSize != 8 {
		t.Errorf("MaxSize = %d, want 8 -- the `cmp [ecx+0x1c],0x8` at 005145d4", MaxSize)
	}
	if MaxSizeNotShared != 4 {
		t.Errorf("MaxSizeNotShared = %d, want 4 -- edx at 005145af", MaxSizeNotShared)
	}
	// Collapsing the two would lose a distinction the engine makes at the
	// join-time check.
	if MaxSize == MaxSizeNotShared {
		t.Error("the two caps are different numbers in the engine")
	}
}

// TestPartyFillsToTheRecoveredCap walks a party up to MaxSize and checks the
// refusal lands exactly at the cap, so a change to the constant cannot silently
// leave the join check disagreeing with it.
func TestPartyFillsToTheRecoveredCap(t *testing.T) {
	h := NewHub()
	p, err := h.Create(Member{CharacterID: 1, Session: &gateway.Session{}})
	if err != nil {
		t.Fatalf("creating the party: %v", err)
	}
	for i := 2; i <= MaxSize; i++ {
		m := Member{CharacterID: int64(i), Session: &gateway.Session{}}
		if _, err := h.Join(p.ID, m); err != nil {
			t.Fatalf("member %d of %d: %v", i, MaxSize, err)
		}
	}
	over := Member{CharacterID: int64(MaxSize + 1), Session: &gateway.Session{}}
	if _, err := h.Join(p.ID, over); !errors.Is(err, ErrPartyFull) {
		t.Errorf("member %d: got %v, want ErrPartyFull", MaxSize+1, err)
	}
}
