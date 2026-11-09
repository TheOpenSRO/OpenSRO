package gameworld

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Manager is the game worlds of one process: CGameWorldMgr's world rows and
// CPublicInstanceWorldMgr's live layers (READ s:0xd6a9a4, s:0xd6a9a8). It
// opens a layer through the Registry (the shard manager's slot allocation),
// runs it as a World unit and drops it when it closes. Its lock guards only
// the directory of live units and is taken on an open, a close and a
// lookup -- never by a world's tick.
type Manager struct {
	ref    *Ref
	reg    registry.Registry
	clock  Clock
	hooks  Hooks
	host   string
	logger *slog.Logger
	// zonePlaces is where each event zone's structure stands (OPEN data;
	// SetZonePlaces).
	zonePlaces map[string]ZonePlace

	mu   sync.Mutex
	live map[registry.InstanceID]*World
	open *World
	// placer places new instances by load on other hosts (remote.go).
	placer Placer
}

// ManagerConfig is what a Manager is made with.
type ManagerConfig struct {
	Ref      *Ref
	Registry registry.Registry // nil: registry.NewMemory on Clock
	Clock    Clock             // nil: RealClock
	Hooks    Hooks
	Host     string
	Logger   *slog.Logger
}

// NewManager makes the process's manager.
func NewManager(c ManagerConfig) *Manager {
	if c.Clock == nil {
		c.Clock = RealClock{}
	}
	if c.Registry == nil {
		c.Registry = registry.NewMemory(c.Clock.Now)
	}
	if c.Ref == nil {
		c.Ref = &Ref{Worlds: map[uint16]*WorldRef{}, Groups: map[int]*Group{}, EventZones: map[string]*EventZone{}}
	}
	return &Manager{ref: c.Ref, reg: c.Registry, clock: c.Clock, hooks: c.Hooks, host: c.Host, logger: c.Logger,
		live: map[registry.InstanceID]*World{}, zonePlaces: map[string]ZonePlace{}}
}

// Ref is the reference data.
func (m *Manager) Ref() *Ref { return m.ref }

// Registry is the instance registry.
func (m *Manager) Registry() registry.Registry { return m.reg }

// SetZonePlaces records where event zones' structures stand.
func (m *Manager) SetZonePlaces(p map[string]ZonePlace) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, v := range p {
		m.zonePlaces[k] = v
	}
}

// AttachOpenWorld makes world 1 layer 1 out of the open world's hubs, which
// cmd/server's own loops run (its monsters, nests and passes); the unit adds
// the world-1 triggers (the pillars) and is what Of answers for its hub.
func (m *Manager) AttachOpenWorld(hub *world.Hub, monsters *combat.Hub, ground *grounditem.Hub) *World {
	in, err := m.reg.Open(context.Background(), registry.OpenRequest{World: OpenWorldID, Layers: 1, Layer: OpenLayer, Host: m.host})
	if err != nil {
		// A second attach (a test): the slot is in use; reuse its record.
		in, _ = m.reg.Get(context.Background(), registry.InstanceID{World: OpenWorldID, Layer: OpenLayer})
	}
	m.mu.Lock()
	hooks := m.hooks
	m.mu.Unlock()
	w := &World{Ref: m.ref.World(OpenWorldID), ID: in.ID, Key: in.Key, Created: in.Created, Hub: hub, Monsters: monsters,
		Ground: ground, mgr: m, clock: m.clock, hooks: hooks, external: true, Logger: m.logger}
	if w.Ref == nil {
		w.Ref = &WorldRef{ID: OpenWorldID, Code: "INS_DEFAULT", MaxCount: 1, regionSet: map[uint16]bool{}}
	}
	w.start()
	m.mu.Lock()
	m.live[w.ID] = w
	m.open = w
	m.mu.Unlock()
	return w
}

// OpenWorld is world 1 layer 1 (nil before AttachOpenWorld).
func (m *Manager) OpenWorld() *World {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.open
}

// ErrNotInstanced is an Open of a world that is not Type 1.
var ErrNotInstanced = errors.New("gameworld: not an instanced world")

// ErrUnknownWorld is an Open of a world id with no row.
var ErrUnknownWorld = errors.New("gameworld: no such world")

// instanceSeq numbers the instances this process opens: each one's monster
// ids start at a base of their own (combat.NewHubAt), so no two layers'
// monsters share an id on this process.
var instanceSeq atomic.Uint32

// Monster id bases (OURS): 0x40000000 and up, 0x10000 ids per instance,
// below the COS range 0x7e000000.
const (
	monsterIDBase  = 0x40000000
	monsterIDSpan  = 0x10000
	monsterIDSlots = (0x7d000000 - monsterIDBase) / monsterIDSpan
)

// Open opens a new layer of world id for owner (and its party): the world
// job's open (READ game_worlds.md 4: GS->SM 0x7C14 kind 1, the first free
// slot, SM->GS 0x3C15). registry.ErrNoSlot when every layer is in use. With
// a Placer (lane W2) the layer may open on another host: the World answered
// is then its proxy (Remote).
func (m *Manager) Open(ctx context.Context, id uint16, owner, party int64) (*World, error) {
	ref := m.ref.World(id)
	if ref == nil {
		return nil, fmt.Errorf("%w: %d", ErrUnknownWorld, id)
	}
	if !ref.Instanced() {
		return nil, fmt.Errorf("%w: %d %s", ErrNotInstanced, id, ref.Code)
	}
	m.mu.Lock()
	p := m.placer
	m.mu.Unlock()
	if p != nil {
		return m.openPlaced(ctx, p, ref, owner, party)
	}
	in, err := m.reg.Open(ctx, registry.OpenRequest{World: id, Layers: ref.MaxCount, Owner: owner, Party: party,
		Lifetime: ref.Duration, Host: m.host})
	if err != nil {
		return nil, err
	}
	return m.build(ref, in), nil
}

// Get is the live unit of an instance, nil for none.
func (m *Manager) Get(id registry.InstanceID) *World {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.live[id]
}

// List is every live unit, by world then layer.
func (m *Manager) List() []*World {
	m.mu.Lock()
	out := make([]*World, 0, len(m.live))
	for _, w := range m.live {
		out = append(out, w)
	}
	m.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].ID.World != out[j].ID.World {
			return out[i].ID.World < out[j].ID.World
		}
		return out[i].ID.Layer < out[j].ID.Layer
	})
	return out
}

// remove drops a closed world and frees its slot (the game server's ack,
// GS->SM 0x7C14 {3, world, layer}).
func (m *Manager) remove(w *World) {
	m.mu.Lock()
	if m.live[w.ID] == w {
		delete(m.live, w.ID)
	}
	m.mu.Unlock()
	m.reg.Close(context.Background(), w.ID, w.Key)
}
