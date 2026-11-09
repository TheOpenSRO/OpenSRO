package gameworld

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

func testManager(t *testing.T, clock Clock, hooks Hooks) *Manager {
	t.Helper()
	ref, err := LoadDir(synthGodDir(t))
	if err != nil {
		t.Fatal(err)
	}
	return NewManager(ManagerConfig{Ref: ref, Clock: clock, Hooks: hooks})
}

// TestLayersShareNothing: two layers of world 63 hold the same region and the
// same coordinates and see none of each other's characters or monsters
// (game_worlds.md 3: visibility is per layer, regions are shared).
func TestLayersShareNothing(t *testing.T) {
	m := testManager(t, nil, Hooks{})
	a, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.Open(context.Background(), 63, 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID.Layer != 1 || b.ID.Layer != 2 || a.Key == b.Key {
		t.Fatalf("layers %v key %d, %v key %d: want 63.1 and 63.2, distinct keys", a.ID, a.Key, b.ID, b.Key)
	}
	if a.Hub == b.Hub || a.Monsters == b.Monsters || a.Ground == b.Ground {
		t.Fatal("two layers share a hub")
	}
	at := world.Position{X: 1063, Z: 1125}
	sa, sb := gateway.NewTestSession(9001), gateway.NewTestSession(9002)
	a.Hub.Enter(sa, 501, "LayerOne", 40, "126/228", at)
	if others := b.Hub.Enter(sb, 502, "LayerTwo", 40, "126/228", at); len(others) != 0 {
		t.Fatalf("layer 2 sees %d characters of layer 1", len(others))
	}
	for _, e := range a.Hub.ViewOfCharacter(501) {
		if e.CharacterID != 501 {
			t.Fatalf("layer 1 sees character %d", e.CharacterID)
		}
	}
	ma := a.Monsters.SpawnSpecies("126/228", combat.Species{Name: "m"}, at.X, 0, at.Z, 10, 1, 1, 0)
	mb := b.Monsters.SpawnSpecies("126/228", combat.Species{Name: "m"}, at.X, 0, at.Z, 10, 1, 1, 0)
	if ma.ID == mb.ID {
		t.Fatalf("both layers' monsters have id %d", ma.ID)
	}
	if _, ok := a.Monsters.Get(mb.ID); ok {
		t.Fatal("layer 1's monster hub holds layer 2's monster")
	}
	if sa.Place() != a.Hub || sb.Place() != b.Hub {
		t.Fatal("a session's place is not its layer's hub")
	}
	if h, ok := world.Locate(502); !ok || h != b.Hub {
		t.Fatal("presence does not name layer 2 for its character")
	}
	if Of(a.Hub) != a || Of(b.Hub) != b {
		t.Fatal("Of does not answer the unit")
	}
}

// TestLayersRunInParallel drives two layers' hubs, monsters and ground items
// from their own goroutines at once: under -race it proves they share no
// lock-free mutable state, and it must not deadlock.
func TestLayersRunInParallel(t *testing.T) {
	m := testManager(t, nil, Hooks{})
	var ws []*World
	for i := 0; i < 2; i++ {
		w, err := m.Open(context.Background(), 63, int64(i+1), 0)
		if err != nil {
			t.Fatal(err)
		}
		ws = append(ws, w)
	}
	var wg sync.WaitGroup
	for i, w := range ws {
		wg.Add(1)
		go func(i int, w *World) {
			defer wg.Done()
			for n := 0; n < 200; n++ {
				s := gateway.NewTestSession(uint64(20000 + i*1000 + n))
				p := world.Position{X: float64(n), Z: float64(n)}
				w.Hub.Enter(s, int64(30000+i*1000+n), fmt.Sprintf("p%d_%d", i, n), 40, "126/228", p)
				w.Hub.Relocate(s, world.Position{X: p.X + 5, Z: p.Z}, world.MoveWalk, 0)
				mon := w.Monsters.SpawnSpecies("126/228", combat.Species{Name: "m"}, p.X, 0, p.Z, 10, 1, 1, 0)
				w.Ground.Drop("126/228", 1, 1, false, float32(p.X), 0, float32(p.Z), 0)
				w.Monsters.Remove(mon.ID)
				w.Enter(int64(30000+i*1000+n), 40)
				w.Leave(int64(30000 + i*1000 + n))
				w.Hub.Leave(s)
			}
			w.Sync()
		}(i, w)
	}
	wg.Wait()
}

func TestOpenRefusals(t *testing.T) {
	m := testManager(t, nil, Hooks{})
	if _, err := m.Open(context.Background(), 1, 0, 0); !errors.Is(err, ErrNotInstanced) {
		t.Errorf("open world 1: %v, want ErrNotInstanced", err)
	}
	if _, err := m.Open(context.Background(), 999, 0, 0); !errors.Is(err, ErrUnknownWorld) {
		t.Errorf("open world 999: %v", err)
	}
	for i := 0; i < 50; i++ {
		if _, err := m.Open(context.Background(), 64, 0, 0); err != nil {
			t.Fatalf("layer %d: %v", i+1, err)
		}
	}
	if _, err := m.Open(context.Background(), 64, 0, 0); !errors.Is(err, registry.ErrNoSlot) {
		t.Errorf("51st layer: %v, want ErrNoSlot (WorldMaxCount 50)", err)
	}
}

// TestEmptyClose: a layer nobody enters closes WorldEmptyRemainTime (600 s)
// after it opened (game_worlds.md 4; MEASURED 601.0 / 604.9 s on the
// original, the excess its shard manager's tick), and one whose last member
// leaves closes 600 s after that.
func TestEmptyClose(t *testing.T) {
	clock := NewFakeClock(time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC))
	var closes []CloseReason
	var mu sync.Mutex
	m := testManager(t, clock, Hooks{Close: func(w *World, r CloseReason) {
		mu.Lock()
		closes = append(closes, r)
		mu.Unlock()
	}})
	w, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(599 * time.Second)
	w.Sync()
	if w.Closed() {
		t.Fatal("closed before 600 s")
	}
	clock.Advance(time.Second)
	<-w.Done()
	if !w.Closed() || len(closes) != 1 || closes[0] != CloseEmpty || m.Get(w.ID) != nil {
		t.Fatalf("at 600 s: closed %v, closes %v", w.Closed(), closes)
	}
	// The slot is free again: the next open takes layer 1 with a new key.
	again, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil || again.ID.Layer != 1 || again.Key == w.Key {
		t.Fatalf("reopen: %v %v key %d", err, again.ID, again.Key)
	}
	// Someone inside: no empty close; out at t, closed at t + 600 s.
	again.Enter(77, 40)
	clock.Advance(20 * time.Minute)
	again.Sync()
	if again.Closed() {
		t.Fatal("closed with a member inside")
	}
	again.Leave(77)
	clock.Advance(599 * time.Second)
	again.Sync()
	if again.Closed() {
		t.Fatal("closed before 600 s empty")
	}
	clock.Advance(time.Second)
	<-again.Done()
}

// TestDurationEndAndWarnings: a 2 h layer warns at 60, 10 and 5 minutes
// before its end and closes at 2 h with its members (game_worlds.md 4).
func TestDurationEndAndWarnings(t *testing.T) {
	start := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	clock := NewFakeClock(start)
	type warnAt struct {
		at   time.Duration
		left time.Duration
	}
	var mu sync.Mutex
	var warns []warnAt
	var closedWith []int64
	var reason CloseReason
	m := testManager(t, clock, Hooks{
		Warn: func(w *World, left time.Duration) {
			mu.Lock()
			warns = append(warns, warnAt{clock.Now().Sub(start), left})
			mu.Unlock()
		},
		Close: func(w *World, r CloseReason) {
			mu.Lock()
			closedWith, reason = w.Members(), r
			mu.Unlock()
		},
	})
	w, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if w.Expires.Sub(w.Created) != 2*time.Hour {
		t.Fatalf("expires %v after creation", w.Expires.Sub(w.Created))
	}
	w.Enter(5, 40)
	w.Enter(6, 41)
	for i := 0; i < 24; i++ { // five-minute steps to 2 h
		clock.Advance(5 * time.Minute)
		w.Sync()
	}
	<-w.Done()
	want := []warnAt{{time.Hour, time.Hour}, {110 * time.Minute, 10 * time.Minute}, {115 * time.Minute, 5 * time.Minute}}
	if fmt.Sprint(warns) != fmt.Sprint(want) {
		t.Errorf("warnings %v, want %v", warns, want)
	}
	if reason != CloseEnd || fmt.Sprint(closedWith) != "[5 6]" {
		t.Errorf("closed %v with %v, want end with [5 6]", reason, closedWith)
	}
	var bytes []string
	for _, w := range warns {
		bytes = append(bytes, fmt.Sprintf("% x", EncodeCloseWarning(w.left)))
	}
	if fmt.Sprint(bytes) != "[1a 0c 3c 1a 0c 0a 1a 0c 05]" {
		t.Errorf("0x300C payloads %v, want {0x0C1A, 60 / 10 / 5}", bytes)
	}
}
