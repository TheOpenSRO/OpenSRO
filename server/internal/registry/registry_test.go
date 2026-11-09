package registry

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestMemorySlotsKeysPresence(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	m := NewMemory(func() time.Time { return now })
	a, err := m.Open(ctx, OpenRequest{World: 63, Layers: 2, Lifetime: 2 * time.Hour})
	if err != nil || a.ID != (InstanceID{63, 1}) || !a.Expires.Equal(now.Add(2*time.Hour)) || !a.EmptySince.Equal(now) {
		t.Fatalf("first open %+v %v", a, err)
	}
	b, _ := m.Open(ctx, OpenRequest{World: 63, Layers: 2})
	if b.ID.Layer != 2 || b.Key == a.Key {
		t.Fatalf("second open %+v", b)
	}
	if _, err := m.Open(ctx, OpenRequest{World: 63, Layers: 2}); !errors.Is(err, ErrNoSlot) {
		t.Fatalf("third open: %v, want ErrNoSlot", err)
	}
	if n, _ := m.Join(ctx, a.ID, a.Key, 7); n != 1 {
		t.Fatalf("join: %d", n)
	}
	if p, ok, _ := m.Presence(ctx, 7); !ok || p.Instance != a.ID {
		t.Fatalf("presence %+v %v", p, ok)
	}
	if _, err := m.Join(ctx, a.ID, a.Key+1, 8); !errors.Is(err, ErrNoInstance) {
		t.Fatalf("a stale key joins: %v", err)
	}
	now = now.Add(time.Minute)
	if n, _ := m.Leave(ctx, a.ID, a.Key, 7); n != 0 {
		t.Fatalf("leave: %d", n)
	}
	if in, _ := m.Get(ctx, a.ID); !in.EmptySince.Equal(now) {
		t.Fatalf("empty since %v, want re-stamped at %v", in.EmptySince, now)
	}
	m.Close(ctx, a.ID, a.Key)
	c, _ := m.Open(ctx, OpenRequest{World: 63, Layers: 2})
	if c.ID.Layer != 1 || c.Key == a.Key {
		t.Fatalf("the freed slot %+v", c)
	}
	if l, _ := m.List(ctx); len(l) != 2 || l[0].ID.Layer != 1 {
		t.Fatalf("list %+v", l)
	}
	if NewMemory(nil).nextKey == NewMemory(nil).nextKey {
		t.Log("two registries drew the same key seed (1 in 2^32)")
	}
	if (InstanceID{63, 2}).Word() != 63<<16|2 {
		t.Fatal("Word")
	}
}
