package main

// Keeping a bot's party-match entry listed.
//
// An entry expires 60 whole minutes after it was registered or last changed
// (party.ExpireAfterMinutes, swept every party.SweepInterval), and the owner
// is not told: the ShardManager's sweep (SM 0x4504c0, READ) sends only 0x386f
// to the owner's GameServer, which has no case for it, and OpenSRO's
// party.Matcher.Sweep sends nothing either -- no 0xb06b delete, no state
// change. A bot that lists once is gone from the list an hour later, which
// is what a long run showed ("nothing in party matching").
//
// So a bot asks. Its check is a 0x706a change of its own entry, unchanged:
// accepted (0xb06a [1]) it renews the entry's time, so a listed bot is never
// swept; refused 0x2c1c (no such entry) it learns the entry is gone and lists
// again (0x7069). The check runs every 55 minutes with jitter (52..58, inside
// the 61 minutes before an entry can be swept), and a few seconds after any
// party event that can take the entry away: its party dissolved (0x3864 kind
// 1, the Hub drops a dissolved party's entry) or the bot left it (kind 3 with
// its own JID: a leaving leader's entry moves to the next leader). A refusal
// 0x2c1d (in someone else's party, not its leader) waits for that party's
// events. OURS: a retail client lists by hand.

import (
	"context"
	"encoding/binary"
	"fmt"
	"math/rand"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/party"
)

const (
	// relistMean and relistJitter: a check every 52..58 minutes.
	relistMean   = 55 * time.Minute
	relistJitter = 3 * time.Minute
	// relistSettle is the wait between a party event and the check it
	// triggers, so a burst of events is one check.
	relistSettle = 3 * time.Second
)

// lister keeps one connection's entry listed. Its handle runs on the bot's
// reader; loop on its own goroutine.
type lister struct {
	c     *conn
	st    *stats
	entry party.Entry
	self  uint32 // the bot's JID (its character id)

	mu  sync.Mutex
	num uint32 // the entry number the server gave, 0 when not known
	rnd *rand.Rand

	kick   chan struct{}
	every  func() time.Duration
	settle time.Duration
}

func newLister(c *conn, st *stats, e party.Entry, self uint32, seed int64) *lister {
	l := &lister{c: c, st: st, entry: e, self: self, rnd: rand.New(rand.NewSource(seed)), kick: make(chan struct{}, 1), settle: relistSettle}
	l.every = l.relistWait
	return l
}

// relistWait is uniform over relistMean +- relistJitter.
func (l *lister) relistWait() time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	return relistMean - relistJitter + time.Duration(l.rnd.Int63n(int64(2*relistJitter)+1))
}

// register lists the entry (0x7069).
func (l *lister) register() error {
	e := l.entry
	e.Number = 0
	return l.c.send(party.OpMatchRegister, party.AppendEntry(nil, &e))
}

// check renews the entry with an unchanged 0x706a, or registers when no
// number is known.
func (l *lister) check() error {
	l.st.relistChecks.Add(1)
	l.mu.Lock()
	n := l.num
	l.mu.Unlock()
	if n == 0 {
		return l.register()
	}
	e := l.entry
	e.Number = n
	return l.c.send(party.OpMatchChange, party.AppendEntry(nil, &e))
}

// loop checks every l.every() and soon after a kick, until ctx ends or done
// closes (the connection is gone).
func (l *lister) loop(ctx context.Context, done <-chan struct{}) {
	t := time.NewTimer(l.every())
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		case <-t.C:
		case <-l.kick:
			select {
			case <-ctx.Done():
				return
			case <-done:
				return
			case <-time.After(l.settle):
			}
			if !t.Stop() {
				select {
				case <-t.C:
				default:
				}
			}
		}
		if err := l.check(); err != nil {
			return
		}
		t.Reset(l.every())
	}
}

// handle reads the replies and events that concern the entry: 0xb069,
// 0xb06a and 0x3864. An error is a failed send.
func (l *lister) handle(op uint16, data []byte) error {
	switch op {
	case party.OpMatchRegAck:
		if len(data) > 0 && data[0] == party.ResultOK {
			e, _, err := party.ReadEntry(data[1:])
			if err == nil {
				l.mu.Lock()
				l.num = e.Number
				l.mu.Unlock()
			}
			l.st.listed.Add(1)
			return nil
		}
		if code, ok := ackCode(data); ok && code == party.CodeRecordAgain {
			return nil // already listed
		}
		l.st.noteErr(fmt.Errorf("party-match register refused: % x", data))
	case party.OpMatchChgAck:
		if len(data) > 0 && data[0] == party.ResultOK {
			l.st.renewed.Add(1)
			return nil
		}
		code, _ := ackCode(data)
		switch code {
		case party.CodeNoEntry:
			// Gone (expired, or taken by a party's change): list again.
			l.mu.Lock()
			l.num = 0
			l.mu.Unlock()
			l.st.relisted.Add(1)
			return l.register()
		case party.CodeNotLeader:
			// A member of another's party: its events bring the next check.
		default:
			l.st.noteErr(fmt.Errorf("party-match change refused: % x", data))
		}
	case party.OpEvent:
		ev, err := party.DecodeEvent(data)
		if err != nil {
			return nil
		}
		if ev.Kind == party.EventDissolved || (ev.Kind == party.EventLeft && ev.JID == l.self) {
			select {
			case l.kick <- struct{}{}:
			default:
			}
		}
	}
	return nil
}

// ackCode is the u16 code of a [2][code] refusal.
func ackCode(data []byte) (uint16, bool) {
	if len(data) < 3 || data[0] != party.ResultError {
		return 0, false
	}
	return binary.LittleEndian.Uint16(data[1:]), true
}
