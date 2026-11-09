package gameworld

import (
	"sort"
	"sync"
	"time"
)

// Clock is what a world's timers run on: the real clock, or a test's
// FakeClock.
type Clock interface {
	Now() time.Time
	AfterFunc(d time.Duration, f func()) Timer
}

// Timer is a pending AfterFunc.
type Timer interface {
	Stop() bool
}

// RealClock is time's own.
type RealClock struct{}

// Now is time.Now.
func (RealClock) Now() time.Time { return time.Now() }

// AfterFunc is time.AfterFunc.
func (RealClock) AfterFunc(d time.Duration, f func()) Timer { return time.AfterFunc(d, f) }

// FakeClock is a clock a test moves by hand: Advance fires every timer due
// by the new time, in time order, on the caller's goroutine.
type FakeClock struct {
	mu     sync.Mutex
	now    time.Time
	seq    int
	timers []*fakeTimer
}

type fakeTimer struct {
	c       *FakeClock
	at      time.Time
	seq     int
	f       func()
	stopped bool
}

// NewFakeClock starts at t.
func NewFakeClock(t time.Time) *FakeClock { return &FakeClock{now: t} }

// Now is the fake time.
func (c *FakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

// AfterFunc schedules f at now + d.
func (c *FakeClock) AfterFunc(d time.Duration, f func()) Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seq++
	t := &fakeTimer{c: c, at: c.now.Add(d), seq: c.seq, f: f}
	c.timers = append(c.timers, t)
	return t
}

func (t *fakeTimer) Stop() bool {
	t.c.mu.Lock()
	defer t.c.mu.Unlock()
	was := !t.stopped
	t.stopped = true
	return was
}

// Advance moves the clock by d, firing each timer due on the way at its own
// time.
func (c *FakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	end := c.now.Add(d)
	c.mu.Unlock()
	for {
		c.mu.Lock()
		sort.SliceStable(c.timers, func(i, j int) bool {
			if !c.timers[i].at.Equal(c.timers[j].at) {
				return c.timers[i].at.Before(c.timers[j].at)
			}
			return c.timers[i].seq < c.timers[j].seq
		})
		var next *fakeTimer
		for len(c.timers) > 0 {
			t := c.timers[0]
			if t.stopped {
				c.timers = c.timers[1:]
				continue
			}
			if t.at.After(end) {
				break
			}
			next = t
			c.timers = c.timers[1:]
			c.now = t.at
			t.stopped = true
			break
		}
		if next == nil {
			c.now = end
			c.mu.Unlock()
			return
		}
		c.mu.Unlock()
		next.f()
	}
}
