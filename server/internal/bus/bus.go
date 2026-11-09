// Package bus is the cross-instance message bus (round 869, OURS,
// docs/protocol/game_worlds.md 12.3): what must reach a character wherever it
// is -- a whisper, a party or guild line, a notice -- is published on a
// channel and delivered by whichever process subscribes to it. Memory is the
// in-process implementation (the default, -role all); PostgreSQL
// LISTEN/NOTIFY and NATS are lane W2's.
//
// Channels (OURS): "host.<id>" for one process running instances, "front.<id>"
// for one front, and Broadcast for every process.
package bus

import (
	"context"
	"sync"
)

// Broadcast is the channel every process subscribes to.
const Broadcast = "all"

// Bus publishes and subscribes. Safe for concurrent use. A handler runs on
// the bus's own goroutine for its subscription, in publish order.
type Bus interface {
	Publish(ctx context.Context, channel string, msg []byte) error
	Subscribe(channel string, handler func(msg []byte)) (cancel func())
}

// Memory is the in-process Bus: each subscription has its own goroutine and
// queue, so a slow handler never holds up a publisher or another channel.
type Memory struct {
	mu   sync.Mutex
	subs map[string]map[int]*sub
	next int
}

type sub struct {
	ch   chan []byte
	done chan struct{}
}

// NewMemory makes an in-process bus.
func NewMemory() *Memory { return &Memory{subs: map[string]map[int]*sub{}} }

// Publish implements Bus: msg goes to every subscriber of channel. A
// subscriber whose queue (1024 messages) is full drops it (OURS: a bus never
// blocks the game on a stuck consumer).
func (m *Memory) Publish(_ context.Context, channel string, msg []byte) error {
	m.mu.Lock()
	var targets []*sub
	for _, s := range m.subs[channel] {
		targets = append(targets, s)
	}
	m.mu.Unlock()
	for _, s := range targets {
		cp := append([]byte(nil), msg...)
		select {
		case s.ch <- cp:
		default:
		}
	}
	return nil
}

// Subscribe implements Bus.
func (m *Memory) Subscribe(channel string, handler func(msg []byte)) func() {
	s := &sub{ch: make(chan []byte, 1024), done: make(chan struct{})}
	m.mu.Lock()
	m.next++
	id := m.next
	if m.subs[channel] == nil {
		m.subs[channel] = map[int]*sub{}
	}
	m.subs[channel][id] = s
	m.mu.Unlock()
	go func() {
		for {
			select {
			case <-s.done:
				return
			case msg := <-s.ch:
				handler(msg)
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() {
			m.mu.Lock()
			delete(m.subs[channel], id)
			m.mu.Unlock()
			close(s.done)
		})
	}
}
