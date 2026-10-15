package gm

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
)

// fakeSessions records the kicks; online are the in-world characters.
type fakeSessions struct {
	online     map[string]bool
	onlineAcct map[int64]bool
	kicked     []string
	kickedAcct []int64
}

func (f *fakeSessions) KickCharacter(name string) (string, bool) {
	for n := range f.online {
		if strings.EqualFold(n, name) {
			f.kicked = append(f.kicked, n)
			return n, true
		}
	}
	return "", false
}

func (f *fakeSessions) KickAccount(id int64) bool {
	f.kickedAcct = append(f.kickedAcct, id)
	return f.onlineAcct[id]
}

type acct788 struct {
	ctx   context.Context
	deps  *Deps
	store *account.MemStore
	ses   *fakeSessions
	gm    Actor
	now   time.Time
}

// newAcct788: accounts alice (character Aria, online), bob (character Bo,
// offline) and boss (a GM, character Chief); the GM runs as boss/Chief.
func newAcct788(t *testing.T) *acct788 {
	t.Helper()
	f := &acct788{ctx: context.Background(), store: account.NewMemStore(),
		now: time.Date(2026, 10, 15, 12, 0, 0, 0, time.Local)}
	f.store.Now = func() time.Time { return f.now }
	chars := character.NewMemStore()
	for _, a := range []struct{ user, char string }{{"alice", "Aria"}, {"bob", "Bo"}, {"boss", "Chief"}} {
		acc, err := f.store.Add(a.user, "pw")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := chars.Create(f.ctx, acc.ID, a.char); err != nil {
			t.Fatal(err)
		}
	}
	f.ses = &fakeSessions{online: map[string]bool{"Aria": true}, onlineAcct: map[int64]bool{1: true}}
	f.deps = &Deps{Chars: chars, Punishments: f.store, AccountLookup: f.store, Sessions: f.ses,
		IsGMAccount: func(u string) bool { return u == "boss" }, Now: func() time.Time { return f.now }}
	f.gm = Actor{Account: "boss", Name: "Chief"}
	return f
}

func (f *acct788) run(line string) Result { return f.deps.Run(f.ctx, f.gm, line) }

// /ban is retail's Ban: a kick of an online character by name, nothing stored.
func TestGMBanIsAKick(t *testing.T) {
	f := newAcct788(t)
	r := f.run("/ban aria")
	if r.Refused || !strings.Contains(r.Text, "kicked Aria") || !strings.Contains(r.Text, "nothing is stored") {
		t.Fatalf("/ban aria: %+v", r)
	}
	if len(f.ses.kicked) != 1 || f.ses.kicked[0] != "Aria" {
		t.Fatalf("kicked %v", f.ses.kicked)
	}
	if ps, _ := f.store.Punishments(f.ctx, 1); len(ps) != 0 {
		t.Fatalf("/ban stored %+v", ps)
	}
	if r := f.run("/ban Bo"); !r.Refused || !strings.Contains(r.Text, "no character named Bo is in the world") {
		t.Fatalf("/ban of an offline character: %+v", r)
	}
	for _, line := range []string{"/ban", "/ban a b"} {
		if r := f.run(line); !r.Refused || !strings.HasPrefix(r.Text, "usage: /ban") {
			t.Fatalf("%s: %+v", line, r)
		}
	}
	f.deps.Sessions = nil
	if r := f.run("/ban Aria"); !r.Refused {
		t.Fatalf("/ban without session control: %+v", r)
	}
}

// /block: a type-1 punishment for the duration, the reason as typed, the
// GM's account the executor; the account is kicked when connected.
func TestGMBlock(t *testing.T) {
	f := newAcct788(t)
	r := f.run("/block Aria 12h  gold   selling, see #4")
	if r.Refused || !strings.Contains(r.Text, "blocked account alice (character Aria) until") || !strings.Contains(r.Text, "disconnected") {
		t.Fatalf("/block: %+v", r)
	}
	ps, _ := f.store.Punishments(f.ctx, 1)
	if len(ps) != 1 {
		t.Fatalf("punishments %+v", ps)
	}
	p := ps[0]
	if p.Type != account.PunishLogin || p.Executor != "boss" || p.Guide != "gold   selling, see #4" ||
		!p.BeginAt.Equal(f.now) || !p.EndAt.Equal(f.now.Add(12*time.Hour)) || !strings.Contains(p.Description, "Chief") {
		t.Fatalf("the block: %+v", p)
	}
	if len(f.ses.kickedAcct) != 1 || f.ses.kickedAcct[0] != 1 {
		t.Fatalf("kicked accounts %v", f.ses.kickedAcct)
	}
	if _, err := f.store.Authenticate(f.ctx, "alice", "pw"); err == nil {
		t.Fatal("alice can log in")
	}
	// Already blocked: refused, nothing added.
	if r := f.run("/block @alice 1d"); !r.Refused || !strings.Contains(r.Text, "already blocked") {
		t.Fatalf("a second block: %+v", r)
	}
	// An offline account by @name, forever, the default reason; not connected.
	r = f.run("/block @bob forever")
	if r.Refused || !strings.Contains(r.Text, "account bob forever") || !strings.Contains(r.Text, "not connected") {
		t.Fatalf("/block @bob forever: %+v", r)
	}
	ps, _ = f.store.Punishments(f.ctx, 2)
	if len(ps) != 1 || !ps[0].Infinite() || ps[0].Guide != defaultBlockGuide {
		t.Fatalf("bob's block: %+v", ps)
	}
	// Refusals.
	for line, want := range map[string]string{
		"/block Chief 1h":   "is a GM account",
		"/block @boss 1h":   "is a GM account",
		"/block Nobody 1h":  "no character named Nobody",
		"/block @nobody 1h": "no account named nobody",
		"/block @ 1h":       "name an account after @",
		"/block Aria":       "usage: /block",
		"/block Aria 0h":    "usage: /block",
		"/block Aria 12":    "usage: /block",
		"/block Aria 3651d": "usage: /block",
		"/block Aria 2w":    "usage: /block",
		"/block Aria -5m":   "usage: /block",
	} {
		if r := f.run(line); !r.Refused || !strings.Contains(r.Text, want) {
			t.Errorf("%s: %+v, want %q", line, r, want)
		}
	}
	// A reason past the gateway's field is cut.
	f.run("/unblock Aria")
	f.run("/block Aria 30m " + strings.Repeat("é", 400))
	ps, _ = f.store.Punishments(f.ctx, 1)
	if len(ps[0].Guide) > maxGuideBytes || !strings.HasPrefix(ps[0].Guide, "éé") || !strings.HasSuffix(ps[0].Guide, "é") {
		t.Fatalf("a long reason: %d bytes", len(ps[0].Guide))
	}
}

// /unblock ends the login blocks; /blockinfo lists every type.
func TestGMUnblockAndBlockInfo(t *testing.T) {
	f := newAcct788(t)
	if r := f.run("/unblock Bo"); !r.Refused || !strings.Contains(r.Text, "is not blocked") {
		t.Fatalf("/unblock of an unblocked account: %+v", r)
	}
	if r := f.run("/blockinfo Bo"); r.Refused || !strings.Contains(r.Text, "no punishments") {
		t.Fatalf("/blockinfo of a clean account: %+v", r)
	}
	f.store.AddPunishment(f.ctx, account.Punishment{AccountID: 2, Type: account.PunishChat, Executor: "smc", Guide: "flood",
		BeginAt: f.now.Add(-time.Hour), EndAt: f.now.Add(-time.Minute)})
	f.run("/block bo 7d cheating")
	r := f.run("/blockinfo @bob")
	if r.Refused || !strings.Contains(r.Text, "2 punishment(s)") || !strings.Contains(r.Text, "block login, ACTIVE until") ||
		!strings.Contains(r.Text, "by boss: cheating") || !strings.Contains(r.Text, "block chat, ended") {
		t.Fatalf("/blockinfo: %+v", r)
	}
	f.now = f.now.Add(time.Hour)
	if r := f.run("/unblock bo"); r.Refused || !strings.Contains(r.Text, "unblocked account bob (character Bo) (1 block(s) ended)") {
		t.Fatalf("/unblock: %+v", r)
	}
	if _, err := f.store.Authenticate(f.ctx, "bob", "pw"); err != nil {
		t.Fatalf("bob after /unblock: %v", err)
	}
	// A GM's own account may be listed and unblocked (only /block refuses).
	if r := f.run("/blockinfo Chief"); r.Refused {
		t.Fatalf("/blockinfo of a GM: %+v", r)
	}
	f.deps.Punishments = nil
	if r := f.run("/blockinfo Bo"); !r.Refused || !strings.Contains(r.Text, "no account store") {
		t.Fatalf("without a store: %+v", r)
	}
}

func TestParseBlockDuration(t *testing.T) {
	for in, want := range map[string]time.Duration{"30m": 30 * time.Minute, "12h": 12 * time.Hour, "7D": 7 * 24 * time.Hour, "3650d": 3650 * 24 * time.Hour} {
		if d, inf, ok := parseBlockDuration(in); !ok || inf || d != want {
			t.Errorf("%s: %v %v %v", in, d, inf, ok)
		}
	}
	for _, in := range []string{"forever", "Infinite", "perm"} {
		if _, inf, ok := parseBlockDuration(in); !ok || !inf {
			t.Errorf("%s not infinite", in)
		}
	}
	if got := restAfter("  /block  Aria   1h   a  b ", 3); got != "a  b" {
		t.Errorf("restAfter = %q", got)
	}
}
