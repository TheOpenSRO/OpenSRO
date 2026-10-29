package gm

import (
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
)

// fakeRestrictions records the cache drops and keeps quest blocks by name.
type fakeRestrictions struct {
	changed []int64
	blocks  map[string]uint32
}

func (f *fakeRestrictions) RestrictionsChanged(id int64) { f.changed = append(f.changed, id) }

func (f *fakeRestrictions) QuestBlock(name string, mask uint32, clear bool) (uint32, string, bool) {
	for n := range f.blocks {
		if strings.EqualFold(n, name) {
			if clear {
				f.blocks[n] &^= mask
			} else {
				f.blocks[n] |= mask
			}
			return f.blocks[n], n, true
		}
	}
	return 0, "", false
}

// Round 840: /chatban and /tradeban store punishments of types 4 and 3, drop
// the session cache, and are refused while one holds; the un- forms end them.
func TestGMChatAndTradeBans(t *testing.T) {
	f := newAcct788(t)
	fr := &fakeRestrictions{blocks: map[string]uint32{"Aria": 0}}
	f.deps.Restrictions = fr

	r := f.run("/chatban Aria 30m spamming the market")
	if r.Refused || !strings.Contains(r.Text, "chat-banned account alice (character Aria)") || !strings.Contains(r.Text, "spamming the market") {
		t.Fatalf("/chatban: %+v", r)
	}
	act, _ := f.store.ActivePunishments(f.ctx, 1, f.now)
	if len(act) != 1 || act[0].Type != account.PunishChat || !act[0].EndAt.Equal(f.now.Add(30*time.Minute)) || act[0].Executor != "boss" {
		t.Fatalf("stored %+v", act)
	}
	if len(fr.changed) != 1 || fr.changed[0] != 1 {
		t.Fatalf("cache drops %v", fr.changed)
	}
	if r := f.run("/chatban Aria 1h"); !r.Refused || !strings.Contains(r.Text, "already chat-banned") {
		t.Fatalf("a second /chatban: %+v", r)
	}
	// The trade ban is its own; a GM's account may be banned (no lock-out).
	if r := f.run("/tradeban @boss forever"); r.Refused || !strings.Contains(r.Text, "trade-banned account boss") || !strings.Contains(r.Text, "forever") {
		t.Fatalf("/tradeban @boss: %+v", r)
	}
	if r := f.run("/tradeban Aria 7d"); r.Refused || !strings.Contains(r.Text, "Trading restricted by a game master.") {
		t.Fatalf("/tradeban Aria: %+v", r)
	}
	// No login block came of it.
	if _, err := f.store.Authenticate(f.ctx, "alice", "pw"); err != nil {
		t.Fatalf("a chat-banned account cannot log in: %v", err)
	}
	if r := f.run("/unchatban Aria"); r.Refused || !strings.Contains(r.Text, "no longer chat-banned") {
		t.Fatalf("/unchatban: %+v", r)
	}
	act, _ = f.store.ActivePunishments(f.ctx, 1, f.now)
	if len(act) != 1 || act[0].Type != account.PunishTrade {
		t.Fatalf("after /unchatban %+v", act)
	}
	if r := f.run("/unchatban Aria"); !r.Refused || !strings.Contains(r.Text, "not chat-banned") {
		t.Fatalf("a second /unchatban: %+v", r)
	}
	if r := f.run("/untradeban Aria"); r.Refused {
		t.Fatalf("/untradeban: %+v", r)
	}
	for _, line := range []string{"/chatban", "/chatban Aria", "/chatban Aria soon", "/tradeban Aria 4000d", "/unchatban", "/untradeban a b"} {
		if r := f.run(line); !r.Refused || !strings.HasPrefix(r.Text, "usage: /") {
			t.Fatalf("%s: %+v", line, r)
		}
	}
	if r := f.run("/chatban Nobody 1h"); !r.Refused || !strings.Contains(r.Text, "no character named Nobody") {
		t.Fatalf("an unknown name: %+v", r)
	}
	if !strings.Contains(Help, "/chatban") || !strings.Contains(Help, "/questblock") {
		t.Fatal("Help does not list the round's commands")
	}
}

// /questblock sets and releases a quest block mask (a test tool).
func TestGMQuestBlock(t *testing.T) {
	f := newAcct788(t)
	fr := &fakeRestrictions{blocks: map[string]uint32{"Aria": 0}}
	f.deps.Restrictions = fr
	if r := f.run("/questblock aria 0x200"); r.Refused || !strings.Contains(r.Text, "now 0x200") {
		t.Fatalf("/questblock: %+v", r)
	}
	if r := f.run("/questblock Aria 0x60000"); r.Refused || !strings.Contains(r.Text, "now 0x60200") {
		t.Fatalf("/questblock a second bit: %+v", r)
	}
	if r := f.run("/questblock Aria clear 0x200"); r.Refused || !strings.Contains(r.Text, "now 0x60000") {
		t.Fatalf("/questblock clear: %+v", r)
	}
	if r := f.run("/questblock Aria clear"); r.Refused || !strings.Contains(r.Text, "now 0x0") {
		t.Fatalf("/questblock clear all: %+v", r)
	}
	for _, line := range []string{"/questblock", "/questblock Aria", "/questblock Aria zero", "/questblock Aria 0", "/questblock Aria 1 2"} {
		if r := f.run(line); !r.Refused || !strings.HasPrefix(r.Text, "usage: /questblock") {
			t.Fatalf("%s: %+v", line, r)
		}
	}
	if r := f.run("/questblock Bo 0x200"); !r.Refused || !strings.Contains(r.Text, "no character named Bo is in the world") {
		t.Fatalf("an offline character: %+v", r)
	}
	f.deps.Restrictions = nil
	if r := f.run("/questblock Aria 0x200"); !r.Refused {
		t.Fatalf("no control: %+v", r)
	}
}
