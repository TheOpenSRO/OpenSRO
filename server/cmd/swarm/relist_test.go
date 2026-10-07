package main

import (
	"bufio"
	"context"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// matchServer is the real login, world, party and party-match handlers over
// memory stores, with the Matcher's clock in the test's hands.
type matchServer struct {
	addr    string
	m       *party.Matcher
	parties *party.Hub
	ids     map[string]int64
	mu      sync.Mutex
	now     time.Time
}

func (s *matchServer) clock() time.Time { s.mu.Lock(); defer s.mu.Unlock(); return s.now }
func (s *matchServer) advance(d time.Duration) time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.now = s.now.Add(d)
	return s.now
}

func newMatchServer(t *testing.T, names ...string) *matchServer {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	hub := world.NewHub()
	s := &matchServer{parties: party.NewHub(), ids: map[string]int64{}, now: time.Unix(1_800_000_000, 0)}
	for i, n := range names {
		accounts.Add(n, "pw")
		c, err := chars.Create(ctx, int64(i+1), n)
		if err != nil {
			t.Fatal(err)
		}
		chars.SetLeveling(ctx, c.ID, 10, 0, 0, character.StartingStr, character.StartingInt)
		s.ids[n] = c.ID
	}
	deps := session.PartyDeps{Chars: chars, Hub: hub, Parties: s.parties, Guilds: guild.NewMemStore(), Skills: skill.NewMemStore()}
	s.m = party.NewMatcher(s.parties)
	s.m.Now = s.clock
	md := session.PartyMatchDeps{PartyDeps: deps, Match: s.m}
	handle := gateway.Chain(session.LoginHandler(accounts), session.WorldHandler(chars, nil, hub), session.PartyHandler(deps), session.PartyMatchHandler(md))
	worldGone, partyGone, matchGone := session.WorldDisconnectHandler(hub, nil), session.PartyDisconnectHandler(deps), session.PartyMatchDisconnectHandler(md)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s.addr = ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: s.addr, Handle: handle, OnDisconnect: func(x *gateway.Session) { partyGone(x); matchGone(x); worldGone(x) }}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	return s
}

// enter logs name in and into the world on a swarm conn.
func (s *matchServer) enter(t *testing.T, name string) *conn {
	t.Helper()
	var nc net.Conn
	var err error
	for i := 0; i < 50; i++ {
		if nc, err = net.DialTimeout("tcp", s.addr, 100*time.Millisecond); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { nc.Close() })
	c := &conn{c: nc, r: bufio.NewReader(nc), st: &stats{}}
	if err := login(c, name, "pw"); err != nil {
		t.Fatal(err)
	}
	if err := c.send(session.OpEnterWorld, (&session.EnterWorldRequest{CharacterName: name}).Encode()); err != nil {
		t.Fatal(err)
	}
	data, err := c.await(session.OpEnterWorldResult, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if er, err := session.DecodeEnterWorldResult(data); err != nil || !er.OK {
		t.Fatalf("%s enter: %v %+v", name, err, er)
	}
	return c
}

// waitFor polls cond for up to 5 s.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 500; i++ {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// TestListerRelistsAfterExpiry drives a bot's lister against the real
// party-match handlers: the entry is listed, renewed by the check (the
// sweep then leaves it), expires when the check does not come in time (the
// server says nothing), and is listed again at the next check, which learns
// it is gone from the change's 0x2c1c; and a dissolved party's dropped entry
// is listed again a moment after the 0x3864 kind 1.
func TestListerRelistsAfterExpiry(t *testing.T) {
	s := newMatchServer(t, "Aria", "Bram")
	c := s.enter(t, "Aria")
	st := &stats{}
	aria := s.ids["Aria"]
	l := newLister(c, st, party.Entry{Flags: party.FlagExpShare, Purpose: party.PurposeHunting, MinLevel: 1, MaxLevel: 140, Title: "Party up!"}, party.JIDOf(aria), 1)
	l.every = func() time.Duration { return time.Hour } // the test calls check itself, or kicks
	l.settle = 10 * time.Millisecond

	// The bot's reader: the lister's messages, and every join request
	// confirmed as partyMessage does.
	var readErr atomic.Pointer[error]
	go func() {
		for {
			op, data, err := c.next(nil)
			if err != nil {
				readErr.Store(&err)
				return
			}
			switch op {
			case party.OpMatchRegAck, party.OpMatchChgAck, party.OpEvent:
				_ = l.handle(op, data)
			case party.OpMatchJoin:
				if j, err := party.DecodeJoinRequest(data); err == nil {
					_ = c.send(party.OpMatchAnswer, party.EncodeJoinAnswer(j.JobID, j.Requester, party.AnswerConfirm))
				}
			}
		}
	}()
	entry := func() (uint32, bool) { n, _, ok := s.parties.Listing(aria); return n, ok }
	known := func() uint32 { l.mu.Lock(); defer l.mu.Unlock(); return l.num }

	if err := l.register(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the first listing", func() bool { n, ok := entry(); return ok && known() == n })
	first, _ := entry()

	// A check inside the hour renews the entry's time: an hour after the
	// registration the sweep leaves it.
	s.advance(50 * time.Minute)
	if err := l.check(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the renewal", func() bool { return st.renewed.Load() == 1 })
	if gone := s.m.Sweep(s.advance(15 * time.Minute)); len(gone) != 0 {
		t.Fatalf("a renewed entry expired: %v", gone)
	}

	// No check for over an hour: the sweep takes it, and nothing is sent.
	if gone := s.m.Sweep(s.advance(47 * time.Minute)); len(gone) != 1 || gone[0] != first {
		t.Fatalf("sweep took %v, want [%d]", gone, first)
	}
	if _, ok := entry(); ok {
		t.Fatal("the swept entry is still recorded")
	}
	time.Sleep(50 * time.Millisecond)
	if st.relisted.Load() != 0 || known() != first {
		t.Fatalf("the bot reacted to an expiry it was not told about: relisted %d, num %d", st.relisted.Load(), known())
	}

	// The next check learns it is gone and lists again.
	if err := l.check(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the relisting", func() bool { n, ok := entry(); return ok && n != first && known() == n })
	if st.relisted.Load() != 1 || st.listed.Load() != 2 {
		t.Fatalf("relisted %d listed %d, want 1 and 2", st.relisted.Load(), st.listed.Load())
	}
	second, _ := entry()

	// A party formed on the entry and dissolved drops it (the Hub's rule);
	// the 0x3864 kind 1 brings a check a moment later, which lists again.
	done := make(chan struct{})
	defer close(done)
	go l.loop(context.Background(), done)
	b := s.enter(t, "Bram")
	if err := b.send(party.OpMatchJoin, party.EncodeTarget(second)); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the party", func() bool { _, in := s.parties.Get(aria); return in })
	if err := b.send(party.OpLeave, nil); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the dissolution", func() bool { _, in := s.parties.Get(aria); return !in })
	waitFor(t, "the relisting after the dissolution", func() bool { n, ok := entry(); return ok && n != second && known() == n })
	if st.relisted.Load() != 2 {
		t.Fatalf("relisted %d, want 2", st.relisted.Load())
	}
	if p := readErr.Load(); p != nil {
		t.Fatalf("the bot's connection failed: %v", *p)
	}
}

// TestRelistWaitBeatsTheSweep: every wait is 52..58 minutes, so a check
// always comes before an entry can be swept (more than 60 whole minutes).
func TestRelistWaitBeatsTheSweep(t *testing.T) {
	l := newLister(nil, &stats{}, party.Entry{}, 1, 7)
	lo, hi := time.Duration(1<<62), time.Duration(0)
	for i := 0; i < 10000; i++ {
		d := l.relistWait()
		lo, hi = min(lo, d), max(hi, d)
	}
	if lo < 52*time.Minute || hi > 58*time.Minute {
		t.Fatalf("waits span %s..%s, want within 52m..58m", lo, hi)
	}
	if hi >= time.Duration(party.ExpireAfterMinutes+1)*time.Minute {
		t.Fatalf("the longest wait %s reaches the sweep's %d minutes", hi, party.ExpireAfterMinutes+1)
	}
	if hi-lo < 5*time.Minute {
		t.Fatalf("waits span only %s: no jitter", hi-lo)
	}
}
