package cluster

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/bus"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
)

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// Three processes on one in-memory registry and bus: requests and replies,
// the presence directory everywhere, a host gone silent reaped, its
// characters dropped from every directory, its next beat fenced.
func TestNodesPresenceCallsAndReaper(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	reg := registry.NewMemory(nil)
	reg.SetLease(300 * time.Millisecond)
	b := bus.NewMemory()
	var deadSeen atomic.Int32
	var fenced atomic.Bool
	mk := func(id string, open, inst bool) *Node {
		return New(Config{Self: registry.Host{ID: id, Addr: id + ":1", OpenWorld: open, Instances: inst}, Registry: reg, Bus: b,
			Beat: 50 * time.Millisecond, Lease: 300 * time.Millisecond,
			OnHostDead: func(registry.Host) { deadSeen.Add(1) },
			OnFenced:   func() { fenced.Store(true) }})
	}
	home, w1, w2 := mk("home", true, false), mk("w1", false, true), mk("w2", false, true)
	w1.Handle("echo", func(_ context.Context, m Msg) (any, error) {
		var s string
		m.Decode(&s)
		if s == "fail" {
			return nil, errors.New("refused")
		}
		return s + " from w1", nil
	})
	w2ctx, w2cancel := context.WithCancel(ctx)
	for _, n := range []*Node{home, w1} {
		if err := n.Start(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if err := w2.Start(w2ctx); err != nil {
		t.Fatal(err)
	}
	var got string
	if err := home.Call(ctx, "w1", "echo", "hi", &got); err != nil || got != "hi from w1" {
		t.Fatalf("call %q %v", got, err)
	}
	if err := home.Call(ctx, "w1", "echo", "fail", nil); err == nil || err.Error() != "refused" {
		t.Fatalf("a refused call: %v", err)
	}
	home.Online(ctx, registry.Character{ID: 7, Name: "Aria", Level: 30})
	w1.Online(ctx, registry.Character{ID: 8, Name: "Bram"})
	waitFor(t, "the directory", func() bool {
		c, ok := w2.LookupName("aria")
		_, ok2 := home.Lookup(8)
		return ok && c.Host == "home" && ok2
	})
	// A hand-off: Bram arrives on w2 before w1's offline is heard.
	w2.Online(ctx, registry.Character{ID: 8, Name: "Bram"})
	w1.Offline(ctx, 8)
	waitFor(t, "the hand-off", func() bool {
		c, ok := home.Lookup(8)
		return ok && c.Host == "w2"
	})
	time.Sleep(50 * time.Millisecond)
	if c, ok := home.Lookup(8); !ok || c.Host != "w2" {
		t.Fatalf("a late offline from the old host removed it: %+v %v", c, ok)
	}
	if h, ok := w1.Home(); !ok || h.ID != "home" {
		t.Fatalf("home %+v %v", h, ok)
	}
	// w2 goes silent (a kill -9): its beats stop.
	w2.Stop()
	w2cancel()
	waitFor(t, "w2 reaped", func() bool {
		hs, _ := reg.Hosts(ctx)
		for _, h := range hs {
			if h.ID == "w2" {
				return h.State == registry.HostDead
			}
		}
		return false
	})
	waitFor(t, "the dead host's characters dropped", func() bool {
		_, ok := home.Lookup(8)
		return !ok && deadSeen.Load() >= 2
	})
	// Were it to beat again, it would be fenced.
	if err := reg.Beat(ctx, registry.Host{ID: "w2"}); !errors.Is(err, registry.ErrHostDead) {
		t.Fatalf("a dead host's beat: %v", err)
	}
	_ = fenced.Load()
}

// The beats carry the load and the counts; a drain is kept by later beats.
func TestNodeBeatsAndDrain(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	reg := registry.NewMemory(nil)
	b := bus.NewMemory()
	var mu sync.Mutex
	players := 3
	n := New(Config{Self: registry.Host{ID: "w1", Instances: true}, Registry: reg, Bus: b, Beat: 20 * time.Millisecond,
		Stats: func() (int, int) { mu.Lock(); defer mu.Unlock(); return players, 1 }})
	if err := n.Start(ctx); err != nil {
		t.Fatal(err)
	}
	if err := n.Drain(ctx); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	players = 9
	mu.Unlock()
	waitFor(t, "a beat", func() bool {
		hs, _ := reg.Hosts(ctx)
		return len(hs) == 1 && hs[0].Players == 9 && hs[0].State == registry.HostDraining
	})
	if _, err := reg.Pick(ctx, ""); !errors.Is(err, registry.ErrNoHost) {
		t.Fatalf("a draining host was picked: %v", err)
	}
}
