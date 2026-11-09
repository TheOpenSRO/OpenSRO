// Package cluster is one process's membership in a multi-process OpenSRO
// (round 869 lane W2, OURS, docs/protocol/game_worlds.md 12): its host row
// and heartbeat in the registry, the reaper, the presence directory (which
// host holds which character), and request/reply and one-way messages to the
// other processes over the bus. It knows nothing of the game: the session
// layer registers the message kinds it serves (a delivery to a character, an
// instance opening, a party change) and reads the directory.
//
// Channels: "host.<id>" for one process, bus.Broadcast for all.
package cluster

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/bus"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
)

// Msg is one bus message.
type Msg struct {
	Kind  string          `json:"k"`
	From  string          `json:"f"`
	Corr  uint64          `json:"c,omitempty"`
	Reply bool            `json:"r,omitempty"`
	Err   string          `json:"e,omitempty"`
	Body  json.RawMessage `json:"b,omitempty"`
}

// Decode unmarshals the body into v.
func (m Msg) Decode(v any) error { return json.Unmarshal(m.Body, v) }

// Handler serves one message kind; a request's reply is what it returns.
type Handler func(ctx context.Context, m Msg) (reply any, err error)

// Config is what a Node is made with.
type Config struct {
	// Self is this process's host row (ID, Addr, Version, OpenWorld,
	// Instances); the counts are filled from Stats at each beat.
	Self     registry.Host
	Registry registry.Cluster
	Bus      bus.Bus
	Logger   *slog.Logger
	// Beat and Lease (registry.DefaultBeat / DefaultLease when zero).
	Beat  time.Duration
	Lease time.Duration
	// Stats is what a beat reports: players and live instances.
	Stats func() (players, live int)
	// OnHostDead hears a host declared dead (by any process's reaper).
	OnHostDead func(h registry.Host)
	// OnPresence hears a character arriving on or leaving a host.
	OnPresence func(c registry.Character, online bool)
	// OnFenced runs when this host's beat is refused: the reaper declared
	// it dead, so it must stop serving.
	OnFenced func()
	// CallTimeout bounds a request (5 s when zero).
	CallTimeout time.Duration
}

// Node is one process in the cluster.
type Node struct {
	cfg  Config
	self registry.Host

	mu       sync.Mutex
	handlers map[string]Handler
	calls    map[uint64]chan Msg
	hosts    map[string]registry.Host
	draining bool

	dirMu  sync.RWMutex
	byChar map[int64]registry.Character
	byName map[string]int64

	corr     atomic.Uint64
	cancels  []func()
	cpuPrev  time.Duration
	cpuAt    time.Time
	load     atomic.Uint64 // float64 bits
	Sent     atomic.Int64
	Received atomic.Int64
}

// New makes a node; Start runs it.
func New(cfg Config) *Node {
	if cfg.Beat <= 0 {
		cfg.Beat = registry.DefaultBeat
	}
	if cfg.Lease <= 0 {
		cfg.Lease = registry.DefaultLease
	}
	if cfg.CallTimeout <= 0 {
		cfg.CallTimeout = 5 * time.Second
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.Self.State == "" {
		cfg.Self.State = registry.HostActive
	}
	if cfg.Self.Started.IsZero() {
		cfg.Self.Started = time.Now()
	}
	return &Node{cfg: cfg, self: cfg.Self, handlers: map[string]Handler{}, calls: map[uint64]chan Msg{},
		hosts: map[string]registry.Host{}, byChar: map[int64]registry.Character{}, byName: map[string]int64{}}
}

// ID is this process's host id.
func (n *Node) ID() string { return n.self.ID }

// Self is this process's host row as configured.
func (n *Node) Self() registry.Host { return n.self }

// Registry is the cluster registry.
func (n *Node) Registry() registry.Cluster { return n.cfg.Registry }

// Logger is the node's logger.
func (n *Node) Logger() *slog.Logger { return n.cfg.Logger }

// HostChannel is a host's bus channel.
func HostChannel(id string) string { return "host." + id }

// Handle registers the handler of kind (before Start).
func (n *Node) Handle(kind string, h Handler) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.handlers[kind] = h
}

// Start subscribes, loads the directory, beats once and starts the beat and
// reaper loop; it returns once the first beat is in.
func (n *Node) Start(ctx context.Context) error {
	n.cancels = append(n.cancels, n.cfg.Bus.Subscribe(HostChannel(n.self.ID), n.receive),
		n.cfg.Bus.Subscribe(bus.Broadcast, n.receive))
	if w, ok := n.cfg.Bus.(interface{ WaitListening(context.Context) error }); ok {
		wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := w.WaitListening(wctx)
		cancel()
		if err != nil {
			return fmt.Errorf("cluster: the bus is not listening: %w", err)
		}
	}
	if err := n.beat(ctx); err != nil {
		return err
	}
	if on, err := n.cfg.Registry.Online(ctx); err == nil {
		n.dirMu.Lock()
		for _, c := range on {
			n.putLocked(c)
		}
		n.dirMu.Unlock()
	}
	go n.loop(ctx)
	return nil
}

// Stop unsubscribes.
func (n *Node) Stop() {
	for _, c := range n.cancels {
		c()
	}
}

func (n *Node) loop(ctx context.Context) {
	t := time.NewTicker(n.cfg.Beat)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if err := n.beat(ctx); err != nil {
			if errors.Is(err, registry.ErrHostDead) {
				n.cfg.Logger.Error("cluster: this host was declared dead by the reaper; stopping")
				if n.cfg.OnFenced != nil {
					n.cfg.OnFenced()
				}
				return
			}
			n.cfg.Logger.Warn("cluster: heartbeat failed", "err", err)
		}
		n.reap(ctx)
	}
}

// cpuLoad is the cores this process kept busy since the last call.
func (n *Node) cpuLoad(now time.Time) float64 {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0
	}
	cpu := time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
	var load float64
	if !n.cpuAt.IsZero() && now.After(n.cpuAt) {
		load = float64(cpu-n.cpuPrev) / float64(now.Sub(n.cpuAt))
	}
	n.cpuPrev, n.cpuAt = cpu, now
	return load
}

// Load is the CPU score of the last beat (cores busy).
func (n *Node) Load() float64 {
	return float64frombits(n.load.Load())
}

func (n *Node) beat(ctx context.Context) error {
	h := n.self
	if n.cfg.Stats != nil {
		h.Players, h.Live = n.cfg.Stats()
	}
	h.Load = n.cpuLoad(time.Now())
	n.load.Store(float64bits(h.Load))
	n.mu.Lock()
	if n.draining {
		h.State = registry.HostDraining
	} else {
		h.State = ""
	}
	n.mu.Unlock()
	if err := n.cfg.Registry.Beat(ctx, h); err != nil {
		return err
	}
	hs, err := n.cfg.Registry.Hosts(ctx)
	if err == nil {
		m := map[string]registry.Host{}
		for _, x := range hs {
			m[x.ID] = x
		}
		n.mu.Lock()
		n.hosts = m
		n.mu.Unlock()
	}
	return nil
}

func (n *Node) reap(ctx context.Context) {
	r, err := n.cfg.Registry.Reap(ctx)
	if err != nil {
		n.cfg.Logger.Warn("cluster: the reaper failed", "err", err)
		return
	}
	for _, h := range r.Dead {
		lost := 0
		players := 0
		for _, in := range r.Lost {
			if in.Host == h.ID {
				lost++
				players += len(in.Members)
			}
		}
		n.cfg.Logger.Warn("cluster: host declared dead", "host", h.ID, "last_beat", h.Heartbeat, "lost_instances", lost,
			"players_inside", players)
		n.Broadcast(ctx, KindHostDead, h)
	}
}

// Drain marks this host draining (no new instances); its next beats say so.
func (n *Node) Drain(ctx context.Context) error {
	n.mu.Lock()
	n.draining = true
	n.mu.Unlock()
	return n.cfg.Registry.SetHostState(ctx, n.self.ID, registry.HostDraining)
}

// Draining reports a Drain.
func (n *Node) Draining() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.draining
}

// Hosts is every host as of the last beat.
func (n *Node) Hosts() []registry.Host {
	n.mu.Lock()
	defer n.mu.Unlock()
	out := make([]registry.Host, 0, len(n.hosts))
	for _, h := range n.hosts {
		out = append(out, h)
	}
	return out
}

// Host is host id as of the last beat.
func (n *Node) Host(id string) (registry.Host, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	h, ok := n.hosts[id]
	return h, ok
}

// Live reports a host that is not dead and beat within the lease.
func (n *Node) Live(h registry.Host) bool {
	return h.State != registry.HostDead && time.Since(h.Heartbeat) <= n.cfg.Lease+n.cfg.Beat
}

// Home is the live host running the open world.
func (n *Node) Home() (registry.Host, bool) {
	if n.self.OpenWorld {
		return n.self, true
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	var best registry.Host
	found := false
	for _, h := range n.hosts {
		if h.OpenWorld && h.State != registry.HostDead && time.Since(h.Heartbeat) <= n.cfg.Lease+n.cfg.Beat {
			if !found || h.Heartbeat.After(best.Heartbeat) {
				best, found = h, true
			}
		}
	}
	return best, found
}

// RefreshHosts reads the host rows now (a front's lookup before its first
// beat lands, a test).
func (n *Node) RefreshHosts(ctx context.Context) {
	hs, err := n.cfg.Registry.Hosts(ctx)
	if err != nil {
		return
	}
	m := map[string]registry.Host{}
	for _, x := range hs {
		m[x.ID] = x
	}
	n.mu.Lock()
	n.hosts = m
	n.mu.Unlock()
}

// ---- messages ----

// The node's own kinds.
const (
	KindHostDead = "cluster.hostdead"
	KindPresence = "cluster.presence"
)

type presenceBody struct {
	C      registry.Character `json:"c"`
	Online bool               `json:"on"`
}

func (n *Node) publish(ctx context.Context, channel string, m Msg) error {
	m.From = n.self.ID
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	n.Sent.Add(1)
	return n.cfg.Bus.Publish(ctx, channel, b)
}

// Send sends a one-way message to host.
func (n *Node) Send(ctx context.Context, host, kind string, body any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}
	return n.publish(ctx, HostChannel(host), Msg{Kind: kind, Body: b})
}

// Broadcast sends a one-way message to every process, this one included.
func (n *Node) Broadcast(ctx context.Context, kind string, body any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}
	return n.publish(ctx, bus.Broadcast, Msg{Kind: kind, Body: b})
}

// ErrTimeout is a request with no reply in time.
var ErrTimeout = errors.New("cluster: no reply")

// Call sends a request to host and decodes its reply into out (nil to
// ignore it).
func (n *Node) Call(ctx context.Context, host, kind string, body, out any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}
	corr := n.corr.Add(1)
	ch := make(chan Msg, 1)
	n.mu.Lock()
	n.calls[corr] = ch
	n.mu.Unlock()
	defer func() {
		n.mu.Lock()
		delete(n.calls, corr)
		n.mu.Unlock()
	}()
	if err := n.publish(ctx, HostChannel(host), Msg{Kind: kind, Corr: corr, Body: b}); err != nil {
		return err
	}
	t := time.NewTimer(n.cfg.CallTimeout)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return fmt.Errorf("%w: %s from %s", ErrTimeout, kind, host)
	case r := <-ch:
		if r.Err != "" {
			return errors.New(r.Err)
		}
		if out != nil && len(r.Body) > 0 {
			return json.Unmarshal(r.Body, out)
		}
		return nil
	}
}

func (n *Node) receive(raw []byte) {
	var m Msg
	if err := json.Unmarshal(raw, &m); err != nil {
		return
	}
	n.Received.Add(1)
	if m.Reply {
		n.mu.Lock()
		ch := n.calls[m.Corr]
		n.mu.Unlock()
		if ch != nil {
			select {
			case ch <- m:
			default:
			}
		}
		return
	}
	switch m.Kind {
	case KindPresence:
		var p presenceBody
		if m.Decode(&p) == nil {
			n.applyPresence(p.C, p.Online)
		}
		return
	case KindHostDead:
		var h registry.Host
		if m.Decode(&h) == nil {
			n.hostDead(h)
		}
		return
	}
	n.mu.Lock()
	h := n.handlers[m.Kind]
	n.mu.Unlock()
	if h == nil {
		return
	}
	if m.Corr == 0 {
		// One-way messages are served in the order they were published
		// (a character's deliveries must not overtake each other): on the
		// subscription's own goroutine, so their handlers must not block.
		n.serve(h, m)
		return
	}
	// A request may block (an instance opening): its own goroutine.
	go n.serve(h, m)
}

func (n *Node) serve(h Handler, m Msg) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	reply, err := h(ctx, m)
	if m.Corr == 0 {
		if err != nil {
			n.cfg.Logger.Warn("cluster: message failed", "kind", m.Kind, "from", m.From, "err", err)
		}
		return
	}
	r := Msg{Kind: m.Kind, Corr: m.Corr, Reply: true}
	if err != nil {
		r.Err = err.Error()
	} else if reply != nil {
		r.Body, _ = json.Marshal(reply)
	}
	if err := n.publish(ctx, HostChannel(m.From), r); err != nil {
		n.cfg.Logger.Warn("cluster: reply not sent", "kind", m.Kind, "to", m.From, "err", err)
	}
}

func (n *Node) hostDead(h registry.Host) {
	n.mu.Lock()
	if cur, ok := n.hosts[h.ID]; ok {
		cur.State = registry.HostDead
		n.hosts[h.ID] = cur
	}
	n.mu.Unlock()
	var gone []registry.Character
	n.dirMu.Lock()
	for id, c := range n.byChar {
		if c.Host == h.ID {
			gone = append(gone, c)
			n.deleteLocked(id)
		}
	}
	n.dirMu.Unlock()
	if n.cfg.OnPresence != nil {
		for _, c := range gone {
			n.cfg.OnPresence(c, false)
		}
	}
	if n.cfg.OnHostDead != nil {
		n.cfg.OnHostDead(h)
	}
}

// ---- the directory ----

func normName(s string) string { return strings.ToLower(s) }

func (n *Node) putLocked(c registry.Character) {
	if old, ok := n.byChar[c.ID]; ok && normName(old.Name) != normName(c.Name) {
		if n.byName[normName(old.Name)] == c.ID {
			delete(n.byName, normName(old.Name))
		}
	}
	n.byChar[c.ID] = c
	if c.Name != "" {
		n.byName[normName(c.Name)] = c.ID
	}
}

func (n *Node) deleteLocked(id int64) {
	c, ok := n.byChar[id]
	if !ok {
		return
	}
	delete(n.byChar, id)
	if n.byName[normName(c.Name)] == id {
		delete(n.byName, normName(c.Name))
	}
}

func (n *Node) applyPresence(c registry.Character, online bool) {
	n.dirMu.Lock()
	changed := false
	if online {
		cur, ok := n.byChar[c.ID]
		if !ok || cur != c {
			n.putLocked(c)
			changed = true
		}
	} else if cur, ok := n.byChar[c.ID]; ok && cur.Host == c.Host {
		n.deleteLocked(c.ID)
		changed = true
	}
	n.dirMu.Unlock()
	if changed && n.cfg.OnPresence != nil {
		n.cfg.OnPresence(c, online)
	}
}

// Online records c (on this host) in the registry and tells every process.
func (n *Node) Online(ctx context.Context, c registry.Character) {
	c.Host = n.self.ID
	n.applyPresence(c, true)
	if err := n.cfg.Registry.SetOnline(ctx, c); err != nil {
		n.cfg.Logger.Warn("cluster: presence not saved", "character_id", c.ID, "err", err)
	}
	n.Broadcast(ctx, KindPresence, presenceBody{C: c, Online: true})
}

// Offline removes character id from this host.
func (n *Node) Offline(ctx context.Context, id int64) {
	n.dirMu.RLock()
	c, ok := n.byChar[id]
	n.dirMu.RUnlock()
	if !ok || c.Host != n.self.ID {
		c = registry.Character{ID: id, Host: n.self.ID}
	}
	n.applyPresence(c, false)
	if err := n.cfg.Registry.SetOffline(ctx, id, n.self.ID); err != nil {
		n.cfg.Logger.Warn("cluster: presence not cleared", "character_id", id, "err", err)
	}
	n.Broadcast(ctx, KindPresence, presenceBody{C: c, Online: false})
}

// Lookup is where character id is, if online anywhere.
func (n *Node) Lookup(id int64) (registry.Character, bool) {
	n.dirMu.RLock()
	defer n.dirMu.RUnlock()
	c, ok := n.byChar[id]
	return c, ok
}

// LookupName is the online character named name (case-insensitive).
func (n *Node) LookupName(name string) (registry.Character, bool) {
	n.dirMu.RLock()
	defer n.dirMu.RUnlock()
	id, ok := n.byName[normName(name)]
	if !ok {
		return registry.Character{}, false
	}
	c, ok := n.byChar[id]
	return c, ok
}

// Everyone is every online character.
func (n *Node) Everyone() []registry.Character {
	n.dirMu.RLock()
	defer n.dirMu.RUnlock()
	out := make([]registry.Character, 0, len(n.byChar))
	for _, c := range n.byChar {
		out = append(out, c)
	}
	return out
}
