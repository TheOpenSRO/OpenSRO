package gameworld

// Instances on other processes (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.2): with a Placer, a new instance goes to
// the least-loaded live host (the registry's pick, in the slot's own
// transaction); when that is another process, the host is asked to build
// the layer from the registry's record (Attach -- the shard manager's
// 0x3C15 answer), and the opener holds a proxy: a World with the record's
// identity, its members and state read from the registry, no hub and no
// goroutine. The session layer moves a character into a proxy's layer by a
// hand-off to its host.

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Placer places instances on hosts (the session layer's cluster glue).
type Placer interface {
	// Version is this process's version (the pick prefers its own).
	Version() string
	// Attach asks host to build the layer of record in.
	Attach(ctx context.Context, host string, in registry.Instance) error
}

// SetPlacer turns placement by load on (nil: every instance opens here, as
// in one process).
func (m *Manager) SetPlacer(p Placer) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.placer = p
}

// Host is this process's host id.
func (m *Manager) Host() string { return m.host }

// Remote reports a proxy: a layer running on another host.
func (w *World) Remote() bool { return w.host != "" }

// HostID is the process running w ("" for one of this process's).
func (w *World) HostID() string { return w.host }

func (w *World) record(ctx context.Context) (registry.Instance, bool) {
	if w.mgr == nil {
		return registry.Instance{}, false
	}
	in, err := w.mgr.reg.Get(ctx, w.ID)
	if err != nil || in.Key != w.Key {
		return registry.Instance{}, false
	}
	return in, true
}

func (w *World) proxyMembers() []int64 {
	in, ok := w.record(context.Background())
	if !ok {
		return nil
	}
	return in.Members
}

func (w *World) proxyClosed() bool {
	in, ok := w.record(context.Background())
	return !ok || in.State != registry.StateOpen
}

// proxyOf is the proxy of record in.
func (m *Manager) proxyOf(ref *WorldRef, in registry.Instance) *World {
	return &World{Ref: ref, ID: in.ID, Key: in.Key, Owner: in.Owner, Party: in.Party, Created: in.Created,
		Expires: in.Expires, mgr: m, clock: m.clock, host: in.Host, Logger: m.logger}
}

// ErrDraining is an Attach to a host that takes no new instances.
var ErrDraining = errors.New("gameworld: this host is draining")

// placementSeq counts openings placed elsewhere (the load test's).
var placementSeq atomic.Int64

// openPlaced is Open with a Placer: the registry picks the host.
func (m *Manager) openPlaced(ctx context.Context, p Placer, ref *WorldRef, owner, party int64) (*World, error) {
	in, err := m.reg.Open(ctx, registry.OpenRequest{World: ref.ID, Layers: ref.MaxCount, Owner: owner, Party: party,
		Lifetime: ref.Duration, Pick: true, Version: p.Version()})
	if err != nil {
		return nil, err
	}
	if in.Host == m.host {
		return m.build(ref, in), nil
	}
	if err := p.Attach(ctx, in.Host, in); err != nil {
		m.reg.Close(context.Background(), in.ID, in.Key)
		return nil, fmt.Errorf("gameworld: host %s did not open %s: %w", in.Host, in.ID, err)
	}
	placementSeq.Add(1)
	if m.logger != nil {
		m.logger.Info("instance placed on another host", "world", in.ID.String(), "code", ref.Code, "key", in.Key, "host", in.Host)
	}
	return m.proxyOf(ref, in), nil
}

// Attach builds the layer of an existing registry record on this process
// (another process placed it here).
func (m *Manager) Attach(ctx context.Context, in registry.Instance, draining bool) (*World, error) {
	ref := m.ref.World(in.ID.World)
	if ref == nil {
		return nil, fmt.Errorf("%w: %d", ErrUnknownWorld, in.ID.World)
	}
	if draining {
		return nil, ErrDraining
	}
	cur, err := m.reg.Get(ctx, in.ID)
	if err != nil || cur.Key != in.Key {
		return nil, fmt.Errorf("gameworld: %s key %d is not open", in.ID, in.Key)
	}
	if w := m.Get(in.ID); w != nil && w.Key == in.Key {
		return w, nil
	}
	return m.build(ref, cur), nil
}

// Find is the open layer id: this process's unit, or a proxy of a layer
// another host runs; nil for none.
func (m *Manager) Find(ctx context.Context, id registry.InstanceID) *World {
	if w := m.Get(id); w != nil {
		return w
	}
	in, err := m.reg.Get(ctx, id)
	if err != nil || in.Host == "" || in.Host == m.host || in.State != registry.StateOpen {
		return nil
	}
	ref := m.ref.World(id.World)
	if ref == nil {
		return nil
	}
	return m.proxyOf(ref, in)
}

// Local is every live unit of this process that is an instance (not the
// open world).
func (m *Manager) Local() []*World {
	var out []*World
	for _, w := range m.List() {
		if !w.Open() {
			out = append(out, w)
		}
	}
	return out
}

// build makes and starts the unit of record in.
func (m *Manager) build(ref *WorldRef, in registry.Instance) *World {
	seq := instanceSeq.Add(1)
	base := int64(monsterIDBase) + int64(seq%monsterIDSlots)*monsterIDSpan
	m.mu.Lock()
	hooks := m.hooks
	m.mu.Unlock()
	w := &World{Ref: ref, ID: in.ID, Key: in.Key, Owner: in.Owner, Party: in.Party, Created: in.Created, Expires: in.Expires,
		Hub: world.NewHub(), Monsters: combat.NewHubAt(base), Ground: grounditem.NewHub(), mgr: m, clock: m.clock,
		hooks: hooks, Logger: m.logger}
	m.mu.Lock()
	m.live[w.ID] = w
	m.mu.Unlock()
	w.start()
	if m.logger != nil {
		m.logger.Info("instance opened", "world", w.ID.String(), "code", ref.Code, "key", w.Key, "owner", in.Owner,
			"expires", w.Expires, "empty_close", ref.EmptyRemain)
	}
	return w
}
