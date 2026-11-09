package gameworld

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
)

// directPlacer attaches straight to the other hosts' managers (the bus's
// stand-in for a test of two hosts in one binary).
type directPlacer struct {
	hosts map[string]*Manager
}

func (p directPlacer) Version() string { return "v1" }

func (p directPlacer) Attach(ctx context.Context, host string, in registry.Instance) error {
	_, err := p.hosts[host].Attach(ctx, in, false)
	return err
}

// Three managers on one registry: openings from the open world's host are
// placed by load on the two instance hosts; the opener holds proxies whose
// members and state are the registry's; Find answers a proxy for another
// host's layer; a close on the running host ends the proxy; a draining host
// is refused.
func TestPlacementAcrossManagers(t *testing.T) {
	ctx := context.Background()
	ref, err := LoadDir(synthGodDir(t))
	if err != nil {
		t.Fatal(err)
	}
	reg := registry.NewMemory(nil)
	mk := func(host string) *Manager {
		return NewManager(ManagerConfig{Ref: ref, Registry: reg, Host: host})
	}
	home, w1, w2 := mk("home"), mk("w1"), mk("w2")
	p := directPlacer{hosts: map[string]*Manager{"w1": w1, "w2": w2}}
	home.SetPlacer(p)
	reg.Beat(ctx, registry.Host{ID: "home", OpenWorld: true, Version: "v1"})
	reg.Beat(ctx, registry.Host{ID: "w1", Instances: true, Version: "v1"})
	reg.Beat(ctx, registry.Host{ID: "w2", Instances: true, Version: "v1"})
	var proxies []*World
	for i := 0; i < 4; i++ {
		w, err := home.Open(ctx, 63, int64(100+i), 0)
		if err != nil {
			t.Fatal(err)
		}
		if !w.Remote() || w.Hub != nil {
			t.Fatalf("opening %d is not a proxy: %+v", i, w)
		}
		proxies = append(proxies, w)
	}
	if n1, n2 := len(w1.Local()), len(w2.Local()); n1 != 2 || n2 != 2 {
		t.Fatalf("spread %d / %d", n1, n2)
	}
	first := proxies[0]
	run := map[string]*Manager{"w1": w1, "w2": w2}[first.HostID()]
	unit := run.Get(first.ID)
	if unit == nil || unit.Key != first.Key || unit.Remote() {
		t.Fatalf("the running unit %+v", unit)
	}
	unit.Enter(7, 40)
	if m := first.Members(); len(m) != 1 || m[0] != 7 {
		t.Fatalf("proxy members %v", m)
	}
	if got := home.Find(ctx, first.ID); got == nil || !got.Remote() || got.Key != first.Key {
		t.Fatalf("Find %+v", got)
	}
	unit.CloseAsync(CloseManual)
	deadline := time.Now().Add(2 * time.Second)
	for !first.Closed() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !first.Closed() || home.Find(ctx, first.ID) != nil {
		t.Fatal("the proxy outlived its layer")
	}
	// A draining host refuses an attach; the opening fails and frees the slot.
	in, _ := reg.Open(ctx, registry.OpenRequest{World: 63, Layers: 50, Host: "w1"})
	if _, err := w1.Attach(ctx, in, true); err == nil {
		t.Fatal("a draining host attached")
	}
}
