package party

import (
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

func member(id int64) Member {
	return Member{Session: gateway.NewTestSession(uint64(1000 + id)), CharacterID: id, Name: "m", Level: 10}
}

func code(t *testing.T, err error) uint16 {
	t.Helper()
	c, ok := Refusal(err)
	if !ok {
		t.Fatalf("error %v is not a party refusal", err)
	}
	return c
}

func TestCapByTheExpBit(t *testing.T) {
	cases := []struct {
		f    Flags
		cap  int
		full uint16
	}{
		{0, 4, CodeFullNotShared},
		{FlagItemShare, 4, CodeFullNotShared},
		{FlagAnyoneInvite | FlagItemShare, 4, CodeFullNotShared},
		{FlagExpShare, 8, CodeFullExpShared},
		{FlagExpShare | FlagItemShare | FlagAnyoneInvite, 8, CodeFullExpShared},
	}
	for _, c := range cases {
		if c.f.Cap() != c.cap || c.f.FullCode() != c.full {
			t.Errorf("flags %#x: cap %d code %#x, want %d %#x", c.f, c.f.Cap(), c.f.FullCode(), c.cap, c.full)
		}
	}
}

func TestFormMakesAPartyOfTwoLedByTheInviter(t *testing.T) {
	h := NewHub()
	p, err := h.Form(member(1), member(2), FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	if p.ID != 1 || p.LeaderID != 1 || len(p.Members) != 2 || p.Members[0].CharacterID != 1 || p.Flags != FlagExpShare {
		t.Fatalf("party %+v", p)
	}
	if h.State(1) != StateInParty || h.State(2) != StateInParty {
		t.Fatal("members not in state 2")
	}
	if c, ok := h.CharacterOfSession(1002); !ok || c != 2 {
		t.Fatal("session lookup")
	}
}

func TestFormRefusalsInTheShardManagersOrder(t *testing.T) {
	h := NewHub()
	if _, err := h.Form(member(1), member(2), 0); err != nil {
		t.Fatal(err)
	}
	if c := code(t, firstErr(h.Form(member(1), member(3), 0))); c != CodeCreateBusy {
		t.Fatalf("inviter in a party: %#x", c)
	}
	if c := code(t, firstErr(h.Form(member(3), member(2), 0))); c != CodeOtherParty {
		t.Fatalf("invitee in a party: %#x", c)
	}
	thief := member(4)
	thief.Job = JobThief
	if c := code(t, firstErr(h.Form(member(3), thief, 0))); c != CodeUserMismatch {
		t.Fatalf("no job with a thief: %#x", c)
	}
	h.SetListing(5, 12, FlagExpShare)
	if c := code(t, firstErr(h.Form(member(5), member(6), 0))); c != CodeEntryFlags {
		t.Fatalf("listing with other flags: %#x", c)
	}
	if _, err := h.Form(member(5), member(6), FlagExpShare); err != nil {
		t.Fatalf("listing with the same flags: %v", err)
	}
}

func firstErr(_ *Party, err error) error { return err }

func TestJobTable(t *testing.T) {
	// READ, SM 0x44ed20: trader and hunter together, thief with thief, no
	// job with no job; 0 with nobody.
	want := map[[2]uint8]bool{}
	for _, a := range []uint8{0, 1, 2, 3, 4} {
		for _, b := range []uint8{0, 1, 2, 3, 4} {
			want[[2]uint8{a, b}] = false
		}
	}
	for _, ok := range [][2]uint8{{1, 1}, {1, 3}, {3, 1}, {3, 3}, {2, 2}, {4, 4}} {
		want[ok] = true
	}
	for pair, ok := range want {
		if JobsMatch(pair[0], pair[1]) != ok {
			t.Errorf("JobsMatch(%d, %d) = %v, want %v", pair[0], pair[1], !ok, ok)
		}
	}
	purpose := map[[2]uint8]bool{
		{JobTrader, PurposeTrade}: true, {JobHunter, PurposeTrade}: true, {JobThief, PurposeThief}: true,
		{JobNone, PurposeHunting}: true, {JobNone, PurposeQuest}: true,
	}
	for _, job := range []uint8{0, 1, 2, 3, 4} {
		for p := uint8(0); p < 4; p++ {
			if JobFitsPurpose(job, p) != purpose[[2]uint8{job, p}] {
				t.Errorf("JobFitsPurpose(%d, %d) = %v", job, p, !purpose[[2]uint8{job, p}])
			}
		}
	}
}

func TestAddRefusalsAndTheCaps(t *testing.T) {
	for _, c := range []struct {
		flags Flags
		cap   int
	}{{FlagExpShare, 8}, {FlagItemShare, 4}} {
		h := NewHub()
		p, _ := h.Form(member(1), member(2), c.flags)
		for id := int64(3); id <= int64(c.cap); id++ {
			if _, err := h.Add(p.ID, member(id)); err != nil {
				t.Fatalf("flags %#x member %d: %v", c.flags, id, err)
			}
		}
		if got := code(t, firstErr(h.Add(p.ID, member(99)))); got != c.flags.FullCode() {
			t.Fatalf("flags %#x full: %#x", c.flags, got)
		}
	}
	h := NewHub()
	p, _ := h.Form(member(1), member(2), FlagExpShare)
	if c := code(t, firstErr(h.Add(p.ID+1, member(3)))); c != CodeCantFindParty {
		t.Fatalf("no party: %#x", c)
	}
	hunter := member(3)
	hunter.Job = JobHunter
	if c := code(t, firstErr(h.Add(p.ID, hunter))); c != CodeUserMismatch {
		t.Fatalf("hunter into a no-job party: %#x", c)
	}
	h.SetListing(4, 9, 0)
	if c := code(t, firstErr(h.Add(p.ID, member(4)))); c != CodeListed {
		t.Fatalf("listed: %#x", c)
	}
	if c := code(t, firstErr(h.Add(p.ID, member(2)))); c != CodeExistingMember {
		t.Fatalf("already a member: %#x", c)
	}
}

func TestATwoMemberPartyDissolvesWhenOneLeaves(t *testing.T) {
	h := NewHub()
	h.Form(member(1), member(2), FlagExpShare)
	h.SetListing(1, 12, FlagExpShare)
	r, err := h.Remove(2, ReasonLeave)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Dissolved || r.After != nil || len(r.Before.Members) != 2 {
		t.Fatalf("removal %+v", r)
	}
	for _, id := range []int64{1, 2} {
		if _, in := h.Get(id); in {
			t.Fatalf("%d still in a party", id)
		}
	}
	if _, _, ok := h.Listing(1); ok {
		t.Fatal("the dissolved party's leader kept its listing (SM 0x44eb30 deletes it)")
	}
	if _, err := h.Remove(1, ReasonLeave); err != ErrNotInParty {
		t.Fatalf("second removal: %v", err)
	}
}

func TestLeadershipPassesToTheLongestStandingMember(t *testing.T) {
	h := NewHub()
	p, _ := h.Form(member(1), member(2), FlagExpShare)
	h.Add(p.ID, member(3))
	h.Add(p.ID, member(4))
	h.SetListing(1, 12, FlagExpShare)
	r, err := h.Remove(1, ReasonLeave)
	if err != nil {
		t.Fatal(err)
	}
	if r.Dissolved || r.NewLeader != 2 || r.After.LeaderID != 2 || r.After.Members[0].CharacterID != 2 {
		t.Fatalf("removal %+v", r)
	}
	if e, _, ok := h.Listing(2); !ok || e != 12 {
		t.Fatal("the listing did not follow the leadership (SM 0x44e1a0)")
	}
	r, _ = h.Remove(3, ReasonKicked)
	if r.NewLeader != 0 || r.After.LeaderID != 2 || len(r.After.Members) != 2 {
		t.Fatalf("a non-leader's removal: %+v", r)
	}
}

type fakeTimer struct {
	f       func()
	stopped bool
}

func (t *fakeTimer) Stop() bool { t.stopped = true; return true }

func fakeHub() (*Hub, *[]*fakeTimer) {
	h := NewHub()
	var timers []*fakeTimer
	h.afterFunc = func(d time.Duration, f func()) stopper {
		if d != InviteTimeout {
			panic("unexpected timeout")
		}
		ft := &fakeTimer{f: f}
		timers = append(timers, ft)
		return ft
	}
	return h, &timers
}

func TestInviteTimesOutAfterThirtySeconds(t *testing.T) {
	h, timers := fakeHub()
	var timedOut []Invite
	inv := Invite{Kind: InviteForm, Inviter: member(1), Target: member(2), Flags: FlagExpShare}
	if err := h.Invite(inv, func(i Invite) { timedOut = append(timedOut, i) }); err != nil {
		t.Fatal(err)
	}
	if h.State(2) != StatePending || h.State(1) != StatePending {
		t.Fatalf("states %d/%d, want 1/1", h.State(1), h.State(2))
	}
	if err := h.Invite(Invite{Kind: InviteJoin, Inviter: member(3), Target: member(2)}, nil); err != ErrInvitePending {
		t.Fatalf("second invite to a pending target: %v", err)
	}
	(*timers)[0].f()
	if len(timedOut) != 1 || timedOut[0].Target.CharacterID != 2 {
		t.Fatalf("timed out %+v", timedOut)
	}
	if _, ok := h.TakeInvite(2); ok {
		t.Fatal("an answer after the timeout found the invitation")
	}
	if h.State(1) != StateFree || h.State(2) != StateFree {
		t.Fatal("states not reset after the timeout")
	}
}

func TestAnAnswerBeforeTheTimeoutStopsIt(t *testing.T) {
	h, timers := fakeHub()
	fired := false
	h.Invite(Invite{Kind: InviteForm, Inviter: member(1), Target: member(2)}, func(Invite) { fired = true })
	inv, ok := h.TakeInvite(2)
	if !ok || inv.Inviter.CharacterID != 1 || !(*timers)[0].stopped {
		t.Fatalf("take: %+v %v", inv, ok)
	}
	(*timers)[0].f() // a timer that fires anyway, racing the stop
	if fired {
		t.Fatal("the timeout ran after the answer")
	}
	// A later invitation to the same target is a new one; the stale timer
	// must not drop it.
	h.Invite(Invite{Kind: InviteForm, Inviter: member(3), Target: member(2)}, func(Invite) { fired = true })
	(*timers)[0].f()
	if fired {
		t.Fatal("the first invitation's timer dropped the second")
	}
	if inv, ok := h.TakeInvite(2); !ok || inv.Inviter.CharacterID != 3 {
		t.Fatal("the second invitation is gone")
	}
}

func TestListedStates(t *testing.T) {
	h, _ := fakeHub()
	h.SetListing(1, 12, 0)
	if h.State(1) != StateListed {
		t.Fatal("listed")
	}
	h.Invite(Invite{Kind: InviteForm, Inviter: member(1), Target: member(2)}, nil)
	if h.State(1) != StateListedInviting {
		t.Fatalf("listed and inviting: %d", h.State(1))
	}
	h.TakeInvite(2)
	if h.State(1) != StateListed || h.State(2) != StateFree {
		t.Fatal("after the answer")
	}
	h.ClearListing(1)
	if h.State(1) != StateFree {
		t.Fatal("cleared")
	}
}

func TestPartyIDsSkipZero(t *testing.T) {
	h := NewHub()
	h.nextID = ^uint32(0)
	p, _ := h.Form(member(1), member(2), 0)
	if p.ID != 1 {
		t.Fatalf("id after wrap %d, want 1", p.ID)
	}
}

func TestHubIsSafeForConcurrentUse(t *testing.T) {
	h := NewHub()
	var wg sync.WaitGroup
	for i := int64(0); i < 50; i++ {
		wg.Add(1)
		go func(i int64) {
			defer wg.Done()
			p, err := h.Form(member(i*3+1), member(i*3+2), FlagExpShare)
			if err != nil {
				t.Error(err)
				return
			}
			h.Add(p.ID, member(i*3+3))
			h.Remove(i*3+1, ReasonLeave)
			h.Get(i*3 + 2)
			h.All()
		}(i)
	}
	wg.Wait()
}

func TestJIDIsTheLowWordOfTheCharacterID(t *testing.T) {
	if JIDOf(101) != 101 || JIDOf(0x1_0000_0065) != 0x65 {
		t.Fatal("JIDOf")
	}
	if (Member{CharacterID: 7}).JID() != 7 {
		t.Fatal("Member.JID")
	}
}
