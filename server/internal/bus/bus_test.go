package bus

import (
	"context"
	"testing"
	"time"
)

func TestMemoryDeliversInOrderAndCancels(t *testing.T) {
	m := NewMemory()
	got := make(chan string, 8)
	cancel := m.Subscribe("host.a", func(msg []byte) { got <- string(msg) })
	other := make(chan string, 8)
	m.Subscribe(Broadcast, func(msg []byte) { other <- string(msg) })
	for _, s := range []string{"one", "two", "three"} {
		m.Publish(context.Background(), "host.a", []byte(s))
	}
	m.Publish(context.Background(), Broadcast, []byte("all"))
	for _, want := range []string{"one", "two", "three"} {
		select {
		case g := <-got:
			if g != want {
				t.Fatalf("got %q, want %q", g, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("no %q", want)
		}
	}
	if g := <-other; g != "all" {
		t.Fatalf("broadcast %q", g)
	}
	cancel()
	m.Publish(context.Background(), "host.a", []byte("late"))
	select {
	case g := <-got:
		t.Fatalf("delivered after cancel: %q", g)
	case <-time.After(100 * time.Millisecond):
	}
}
