package party

import (
	"fmt"
	"testing"
	"time"
)

func fakeMatcher(h *Hub) (*Matcher, *[]*fakeTimer) {
	m := NewMatcher(h)
	m.Now = func() time.Time { return time.Unix(1_700_000_000, 0) }
	var timers []*fakeTimer
	m.afterFunc = func(d time.Duration, f func()) stopper {
		if d != JoinTimeout {
			panic("unexpected join timeout")
		}
		ft := &fakeTimer{f: f}
		timers = append(timers, ft)
		return ft
	}
	return m, &timers
}

func entry(purpose, lo, hi uint8, flags Flags) Entry {
	return Entry{Flags: flags, Purpose: purpose, MinLevel: lo, MaxLevel: hi, Title: "t"}
}

// everyone is online and named after their id; race 0.
func allOnline(owner int64) (string, uint8, bool) { return fmt.Sprintf("c%d", owner), 0, true }
func online(int64) bool                           { return true }
func noJob(int64) uint8                           { return JobNone }

// TestRegisterNumbersOnlyGrow: entry numbers come from a counter that skips 0
// and is never reused (SM 0x451290); the listing takes the entry's flags when
// party-less and the Hub records it.
func TestRegisterNumbersOnlyGrow(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	m.counter = 0xffffffff
	l, err := m.Register(1, entry(PurposeHunting, 1, 110, FlagItemShare))
	if err != nil || l.Number != 1 || l.Flags != FlagItemShare || l.Time != 1_700_000_000 {
		t.Fatalf("first listing %+v %v", l, err)
	}
	if n, f, ok := h.Listing(1); !ok || n != 1 || f != FlagItemShare {
		t.Fatalf("hub listing %d %#x %v", n, f, ok)
	}
	if h.State(1) != StateListed {
		t.Fatalf("state %d, want 4", h.State(1))
	}
	if err := m.Delete(1, 1); err != nil {
		t.Fatal(err)
	}
	l2, _ := m.Register(1, entry(PurposeQuest, 1, 110, 0))
	if l2.Number != 2 {
		t.Fatalf("number reused: %d", l2.Number)
	}
}

// TestRegisterRefusalsInTheShardManagersOrder (SM 0x450680 -> 0x451110):
// 0x2c1b already listed; in a party 0x2c20 flags not the party's, 0x2c1d not
// the leader, 0x2c08 full; the listing takes the party's flags.
func TestRegisterRefusalsInTheShardManagersOrder(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	if _, err := m.Register(9, entry(0, 1, 110, 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Register(9, entry(0, 1, 110, 0)); code(t, err) != CodeRecordAgain {
		t.Fatalf("again: %v", err)
	}
	h.Form(member(1), member(2), 0) // cap 4
	if _, err := m.Register(1, entry(0, 1, 110, FlagExpShare)); code(t, err) != CodeEntryFlags {
		t.Fatalf("flags: %v", err)
	}
	// Flags are tested before leadership: a member with the wrong flags is
	// refused 0x2c20, with the right ones 0x2c1d.
	if _, err := m.Register(2, entry(0, 1, 110, FlagExpShare)); code(t, err) != CodeEntryFlags {
		t.Fatalf("member, wrong flags: %v", err)
	}
	if _, err := m.Register(2, entry(0, 1, 110, 0)); code(t, err) != CodeNotLeader {
		t.Fatalf("member: %v", err)
	}
	pid := mustParty(t, h, 1)
	h.Add(pid, member(3))
	h.Add(pid, member(4))
	if _, err := m.Register(1, entry(0, 1, 110, 0)); code(t, err) != CodeMatchFull {
		t.Fatalf("full: %v", err)
	}
	h.Remove(4, ReasonLeave)
	l, err := m.Register(1, entry(0, 1, 110, 0))
	if err != nil || l.Flags != 0 {
		t.Fatalf("leader: %+v %v", l, err)
	}
	if h.State(1) != StateInParty {
		t.Fatalf("a listed member's state %d, want 2", h.State(1))
	}
}

func mustParty(t *testing.T, h *Hub, c int64) uint32 {
	t.Helper()
	p, ok := h.Get(c)
	if !ok {
		t.Fatalf("%d in no party", c)
	}
	return p.ID
}

// TestChangeAndDelete (SM 0x4513c0, 0x451490): change needs an entry
// (0x2c1c), keeps the flags (5) and renews the time; delete refuses an
// unknown number (0x2c1c) and someone else's (0x2c1d).
func TestChangeAndDelete(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	if _, err := m.Change(1, entry(0, 1, 110, 0)); code(t, err) != CodeNoEntry {
		t.Fatalf("change without entry: %v", err)
	}
	l, _ := m.Register(1, entry(0, 1, 110, FlagItemShare))
	m.Register(2, entry(0, 1, 110, 0))
	if _, err := m.Change(1, entry(1, 5, 50, 0)); code(t, err) != CodeFlagsChanged {
		t.Fatalf("flags change: %v", err)
	}
	m.Now = func() time.Time { return time.Unix(1_700_000_100, 0) }
	n, err := m.Change(1, Entry{Flags: FlagItemShare, Purpose: PurposeQuest, MinLevel: 5, MaxLevel: 50, Title: "new"})
	if err != nil || n != l.Number {
		t.Fatalf("change: %d %v", n, err)
	}
	got, owner, _ := m.Get(l.Number)
	if got.Purpose != PurposeQuest || got.MinLevel != 5 || got.MaxLevel != 50 || got.Title != "new" || got.Time != 1_700_000_100 || owner != 1 {
		t.Fatalf("after change %+v owner %d", got, owner)
	}
	if err := m.Delete(1, 99); code(t, err) != CodeNoEntry {
		t.Fatalf("delete unknown: %v", err)
	}
	if err := m.Delete(2, l.Number); code(t, err) != CodeNotLeader {
		t.Fatalf("delete someone else's: %v", err)
	}
	if err := m.Delete(1, l.Number); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := h.Listing(1); ok || h.State(1) != StateFree {
		t.Fatal("listing kept after delete")
	}
}

// TestPagesOf23WithTheRequesterFirst (SM 0x451630, 0x450d20): 50 listings
// make pages of 23, 23 and 4 in number order; a page past the end is page 0;
// the requester's own entry -- or its party leader's -- heads every page and
// counts one more.
func TestPagesOf23WithTheRequesterFirst(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	if pages, at, rows, err := m.Page(1, 0, allOnline); err != nil || pages != 0 || at != 0 || len(rows) != 0 {
		t.Fatalf("empty: %d %d %d %v", pages, at, len(rows), err)
	}
	for c := int64(100); c < 150; c++ {
		m.Register(c, entry(0, 1, 110, 0))
	}
	pages, at, rows, err := m.Page(1, 0, allOnline)
	if err != nil || pages != 3 || at != 0 || len(rows) != 23 || rows[0].Number != 1 || rows[22].Number != 23 {
		t.Fatalf("page 0: %d %d %d %v", pages, at, len(rows), err)
	}
	if _, at, rows, _ = m.Page(1, 2, allOnline); at != 2 || len(rows) != 4 || rows[0].Number != 47 {
		t.Fatalf("page 2: at %d rows %d", at, len(rows))
	}
	if _, at, rows, _ = m.Page(1, 3, allOnline); at != 0 || rows[0].Number != 1 {
		t.Fatalf("past the end: at %d first %d", at, rows[0].Number)
	}
	// Character 140 (entry 41) sees its own entry first on page 0 (24 rows).
	if _, _, rows, _ = m.Page(140, 0, allOnline); len(rows) != 24 || rows[0].Number != 41 || rows[1].Number != 1 {
		t.Fatalf("own entry first: %d rows, first %d", len(rows), rows[0].Number)
	}
	// A member of 140's party sees the leader's entry first; the count shows
	// the party size, the name and race the owner's.
	h.Form(member(140), member(7), 0)
	_, _, rows, _ = m.Page(7, 0, allOnline)
	if rows[0].Number != 41 || rows[0].Count != 2 || rows[0].Name != "c140" || rows[1].Count != 1 {
		t.Fatalf("party member: %+v / %+v", rows[0], rows[1])
	}
}

// TestPageDropsAnOwnerGone: an entry whose owner is not in the world is
// deleted by the page builder (SM 0x451630 on 0x44f640 returning 0).
func TestPageDropsAnOwnerGone(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	m.Register(1, entry(0, 1, 110, 0))
	m.Register(2, entry(0, 1, 110, 0))
	gone := func(owner int64) (string, uint8, bool) { return "x", 0, owner != 1 }
	_, _, rows, _ := m.Page(3, 0, gone)
	if len(rows) != 1 || rows[0].Number != 2 {
		t.Fatalf("rows %+v", rows)
	}
	if _, _, ok := m.Get(1); ok {
		t.Fatal("entry of an owner gone kept")
	}
	if _, _, ok := h.Listing(1); ok {
		t.Fatal("hub listing of an owner gone kept")
	}
}

// TestListingFollowsTheLeaderAndVanishesWithItsParty (SM 0x44e1a0, 0x44eb30,
// through the Hub).
func TestListingFollowsTheLeaderAndVanishesWithItsParty(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	h.Form(member(1), member(2), FlagExpShare)
	pid := mustParty(t, h, 1)
	h.Add(pid, member(3))
	l, err := m.Register(1, entry(0, 1, 110, FlagExpShare))
	if err != nil {
		t.Fatal(err)
	}
	h.Remove(1, ReasonLeave)
	if _, owner, ok := m.Get(l.Number); !ok || owner != 2 {
		t.Fatalf("owner after the leader left: %d %v", owner, ok)
	}
	if _, _, rows, _ := m.Page(3, 0, allOnline); len(rows) != 2 || rows[0].Name != "c2" {
		t.Fatalf("rows %+v", rows)
	}
	h.Remove(3, ReasonLeave) // two left: dissolved
	if _, _, ok := m.Get(l.Number); ok {
		t.Fatal("listing survived its party's dissolution")
	}
	if pages, _, _, _ := m.Page(2, 0, allOnline); pages != 0 {
		t.Fatalf("%d pages after the dissolution", pages)
	}
}

// TestJoinRequestLadder (SM 0x44f850), each refusal in the engine's order.
func TestJoinRequestLadder(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	j := func(c int64, lvl uint8) Joiner { return Joiner{CharacterID: c, Level: lvl, Job: JobNone} }
	req := func(jn Joiner, n uint32) uint16 {
		_, err := m.Request(jn, n, noJob, online, nil)
		if err == nil {
			return 1
		}
		return code(t, err)
	}
	// Party 1+2 (non-shared, cap 4) lists entry 1 for levels 10..20.
	h.Form(member(1), member(2), 0)
	l, _ := m.Register(1, entry(PurposeHunting, 10, 20, 0))
	if c := req(j(2, 15), l.Number); c != CodeOtherParty {
		t.Fatalf("in a party: %#x", c)
	}
	own, _ := m.Register(5, entry(PurposeHunting, 1, 110, 0))
	if c := req(j(5, 15), l.Number); c != CodeListed {
		t.Fatalf("holds an entry: %#x", c)
	}
	m.Delete(5, own.Number)
	if c := req(j(5, 15), 999); c != CodeNoEntry {
		t.Fatalf("no entry: %#x", c)
	}
	pid := mustParty(t, h, 1)
	h.Add(pid, member(3))
	h.Add(pid, member(4))
	if c := req(j(5, 15), l.Number); c != CodeFullNotShared {
		t.Fatalf("full: %#x", c)
	}
	h.Remove(4, ReasonLeave)
	if _, err := m.Request(j(5, 15), l.Number, func(int64) uint8 { return JobThief }, online, nil); code(t, err) != CodeUserMismatch {
		t.Fatalf("leader's job: %v", err)
	}
	if c := req(Joiner{CharacterID: 5, Level: 15, Job: JobTrader}, l.Number); c != CodeUserMismatch {
		t.Fatalf("purpose: %#x", c)
	}
	if c := req(j(5, 9), l.Number); c != CodeJoinLevel {
		t.Fatalf("level 9: %#x", c)
	}
	if c := req(j(5, 21), l.Number); c != CodeJoinLevel {
		t.Fatalf("level 21: %#x", c)
	}
	if _, err := m.Request(j(5, 10), l.Number, noJob, func(int64) bool { return false }, nil); code(t, err) != CodeCantFindCreator {
		t.Fatalf("leader offline: %v", err)
	}
	job, err := m.Request(j(5, 20), l.Number, noJob, online, nil)
	if err != nil || job.Leader != 1 || job.Requester != 5 || job.Entry != l.Number || job.ID == 0 {
		t.Fatalf("request: %+v %v", job, err)
	}
	if h.State(5) != StatePending {
		t.Fatalf("requester state %d, want 1", h.State(5))
	}
	if c := req(j(6, 15), l.Number); c != CodeDuplicate {
		t.Fatalf("second request: %#x", c)
	}
}

// TestJoinBackstopAnswersNoReply: the 15 s job expires into the onTimeout
// callback, the entry's pending mark and the requester's state clear, and a
// late TakeJob finds nothing.
func TestJoinBackstopAnswersNoReply(t *testing.T) {
	h := NewHub()
	m, timers := fakeMatcher(h)
	l, _ := m.Register(1, entry(PurposeHunting, 1, 110, FlagExpShare))
	var expired []JoinJob
	job, err := m.Request(Joiner{CharacterID: 2, Level: 5, Job: JobNone}, l.Number, noJob, online, func(j JoinJob) { expired = append(expired, j) })
	if err != nil || len(*timers) != 1 {
		t.Fatalf("request %v, %d timers", err, len(*timers))
	}
	(*timers)[0].f()
	if len(expired) != 1 || expired[0].ID != job.ID {
		t.Fatalf("expired %+v", expired)
	}
	if got, _, _ := m.Get(l.Number); got.Pending {
		t.Fatal("entry still pending")
	}
	if h.State(2) != StateFree {
		t.Fatalf("requester state %d", h.State(2))
	}
	if _, ok := m.TakeJob(job.ID); ok {
		t.Fatal("job taken twice")
	}
}

// TestTakeJobStopsTheBackstop: an answer ends the job and its timer.
func TestTakeJobStopsTheBackstop(t *testing.T) {
	h := NewHub()
	m, timers := fakeMatcher(h)
	l, _ := m.Register(1, entry(PurposeQuest, 1, 110, 0))
	job, _ := m.Request(Joiner{CharacterID: 2, Level: 5, Job: JobNone}, l.Number, noJob, online, nil)
	if !m.IsLeaderOf(job.ID, 1) || m.IsLeaderOf(job.ID, 2) {
		t.Fatal("IsLeaderOf")
	}
	if _, ok := m.TakeJob(job.ID); !ok || !(*timers)[0].stopped {
		t.Fatal("take")
	}
	// The entry takes a new request at once.
	if _, err := m.Request(Joiner{CharacterID: 3, Level: 5, Job: JobNone}, l.Number, noJob, online, nil); err != nil {
		t.Fatal(err)
	}
}

// TestWithdrawDropsOnlyAPartylessOwnersEntry (SM 0x4296f0 -> 0x451590).
func TestWithdrawDropsOnlyAPartylessOwnersEntry(t *testing.T) {
	h := NewHub()
	m, _ := fakeMatcher(h)
	l, _ := m.Register(1, entry(0, 1, 110, 0))
	h.Form(member(2), member(3), 0)
	l2, _ := m.Register(2, entry(0, 1, 110, 0))
	m.Withdraw(1)
	m.Withdraw(2)
	if _, _, ok := m.Get(l.Number); ok {
		t.Fatal("party-less owner's entry kept")
	}
	if _, _, ok := m.Get(l2.Number); !ok {
		t.Fatal("party leader's entry dropped by Withdraw")
	}
}
