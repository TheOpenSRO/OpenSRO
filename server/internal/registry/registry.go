// Package registry is the registry of game-world instances (round 869, OURS,
// docs/protocol/game_worlds.md 12): the role the original's shard manager
// plays -- it allocates a world's layer slots, keeps each instance's record
// and counts who is in it (READ m:0x658b50, m:0x658e30, m:0x658f10) -- behind
// an interface, so one process (Memory, the default) and many (a PostgreSQL
// implementation, lane W2) run the same game code. The instance's own timers
// run where the instance runs (internal/gameworld); the registry holds the
// record they are measured from.
package registry

import (
	"context"
	crand "crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

// InstanceID is a world and a layer: the u32 {u16 world, u16 layer} every
// object keeps at +0x78 (READ CGObj::EnterWorld s:0x485360).
type InstanceID struct {
	World uint16
	Layer uint16
}

// Word is the id as the engine's u32: world in the high half.
func (id InstanceID) Word() uint32 { return uint32(id.World)<<16 | uint32(id.Layer) }

func (id InstanceID) String() string { return fmt.Sprintf("%d.%d", id.World, id.Layer) }

// State is an instance's state (OURS, game_worlds.md 12.3).
type State string

const (
	StateOpen    State = "open"
	StateClosing State = "closing"
	StateLost    State = "lost"
)

// Instance is one instance's record.
type Instance struct {
	ID InstanceID
	// Key tells incarnations of a reused layer apart (READ: the layer's
	// +0x70; INFERRED to be _CharInstanceWorldData.DungeonKeyID).
	Key uint32
	// Host is the process running it ("" in one process).
	Host    string
	Owner   int64 // the character it was opened for (0 for none)
	Party   int64 // the owner's party at the opening (0 for none)
	Created time.Time
	// Expires is Created + the world's duration; zero for none.
	Expires time.Time
	State   State
	// Members is who is in it now, EmptySince when the last left (or the
	// opening: m:0x6582d0 stamps it at creation).
	Members    []int64
	EmptySince time.Time
}

// Place is where a character is: its instance and the host running it
// (the presence row of game_worlds.md 12.3).
type Place struct {
	Instance InstanceID
	Key      uint32
	Host     string
}

// ErrNoSlot is a world with every layer in use (the Dimension hole's 0x1852;
// READ forgotten_world.md 3).
var ErrNoSlot = errors.New("registry: no free layer")

// ErrNoInstance is a lookup of an instance that is not open.
var ErrNoInstance = errors.New("registry: no such instance")

// OpenRequest is what an instance is opened with.
type OpenRequest struct {
	World uint16
	// Layers is the world's WorldMaxCount: slots 1..Layers (slot 0 unused,
	// READ game_worlds.md 3).
	Layers   int
	Owner    int64
	Party    int64
	Lifetime time.Duration // the world's WorldDurationTime; 0 for none
	Host     string
	// Layer, when non-zero, asks for that slot exactly (the open world's
	// layer 1); a slot in use is ErrNoSlot.
	Layer uint16
	// Pick places the instance on the least-loaded live host (Cluster.Pick,
	// in the same transaction as the slot: lane W2), overriding Host;
	// Version is the opener's, preferred by the pick. ErrNoHost for none.
	Pick    bool
	Version string
}

// Registry is the instance registry. Implementations: Memory (one process),
// Postgres (several, lane W2; postgres.go). Every method is safe for concurrent use.
type Registry interface {
	// Open allocates the first free layer of the world and records the
	// instance, empty since now.
	Open(ctx context.Context, req OpenRequest) (Instance, error)
	// Get is an open instance's record.
	Get(ctx context.Context, id InstanceID) (Instance, error)
	// Close frees the layer of the incarnation key; a key that no longer
	// matches (the layer reopened) is ignored.
	Close(ctx context.Context, id InstanceID, key uint32) error
	// Join and Leave count a character in and out (m:0x658e30, m:0x658f10)
	// and record its place; they answer the members after the change.
	Join(ctx context.Context, id InstanceID, key uint32, char int64) (members int, err error)
	Leave(ctx context.Context, id InstanceID, key uint32, char int64) (members int, err error)
	// Presence is where a character is, if any instance holds it.
	Presence(ctx context.Context, char int64) (Place, bool, error)
	// List is every open instance, ordered by world then layer.
	List(ctx context.Context) ([]Instance, error)
	// Now is the registry's clock (the database's now() in W2's).
	Now() time.Time
}

// Memory is the in-process Registry: one lock over the records, taken only
// when an instance opens, closes or a character enters or leaves one --
// never by a tick.
type Memory struct {
	mu       sync.Mutex
	clock    func() time.Time
	byID     map[InstanceID]*Instance
	presence map[int64]Place
	nextKey  uint32
	// cl is the cluster half (cluster.go), made on first use.
	cl *memCluster
}

// NewMemory makes an empty in-process registry on clock (nil: time.Now).
func NewMemory(clock func() time.Time) *Memory {
	if clock == nil {
		clock = time.Now
	}
	// The keys start at a random point (OURS): a key outlives the process in
	// the characters' rows and timed jobs, so a restart must not hand out the
	// last run's keys again (W2's PostgreSQL registry uses a sequence).
	var seed [4]byte
	_, _ = crand.Read(seed[:])
	return &Memory{clock: clock, byID: map[InstanceID]*Instance{}, presence: map[int64]Place{},
		nextKey: binary.LittleEndian.Uint32(seed[:])}
}

// Now is the registry's clock.
func (m *Memory) Now() time.Time { return m.clock() }

// Open implements Registry.
func (m *Memory) Open(_ context.Context, req OpenRequest) (Instance, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var layer uint16
	if req.Layer != 0 {
		if _, used := m.byID[InstanceID{req.World, req.Layer}]; used {
			return Instance{}, ErrNoSlot
		}
		layer = req.Layer
	} else {
		for l := 1; l <= req.Layers && l <= 0xFFFF; l++ {
			if _, used := m.byID[InstanceID{req.World, uint16(l)}]; !used {
				layer = uint16(l)
				break
			}
		}
	}
	if layer == 0 {
		return Instance{}, ErrNoSlot
	}
	if req.Pick {
		h, err := m.pickLocked(req.Version)
		if err != nil {
			return Instance{}, err
		}
		req.Host = h.ID
	}
	m.nextKey++
	if m.nextKey == 0 {
		m.nextKey++
	}
	now := m.clock()
	in := &Instance{ID: InstanceID{req.World, layer}, Key: m.nextKey, Host: req.Host, Owner: req.Owner, Party: req.Party,
		Created: now, State: StateOpen, EmptySince: now}
	if req.Lifetime > 0 {
		in.Expires = now.Add(req.Lifetime)
	}
	m.byID[in.ID] = in
	return copyInstance(in), nil
}

func copyInstance(in *Instance) Instance {
	out := *in
	out.Members = append([]int64(nil), in.Members...)
	return out
}

// Get implements Registry.
func (m *Memory) Get(_ context.Context, id InstanceID) (Instance, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	in, ok := m.byID[id]
	if !ok {
		return Instance{}, ErrNoInstance
	}
	return copyInstance(in), nil
}

// Close implements Registry.
func (m *Memory) Close(_ context.Context, id InstanceID, key uint32) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	in, ok := m.byID[id]
	if !ok || in.Key != key {
		return nil
	}
	for _, c := range in.Members {
		if p, ok := m.presence[c]; ok && p.Instance == id && p.Key == key {
			delete(m.presence, c)
		}
	}
	delete(m.byID, id)
	return nil
}

// Join implements Registry.
func (m *Memory) Join(_ context.Context, id InstanceID, key uint32, char int64) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	in, ok := m.byID[id]
	if !ok || in.Key != key {
		return 0, ErrNoInstance
	}
	found := false
	for _, c := range in.Members {
		if c == char {
			found = true
		}
	}
	if !found {
		in.Members = append(in.Members, char)
	}
	m.presence[char] = Place{Instance: id, Key: key, Host: in.Host}
	return len(in.Members), nil
}

// Leave implements Registry.
func (m *Memory) Leave(_ context.Context, id InstanceID, key uint32, char int64) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	in, ok := m.byID[id]
	if !ok || in.Key != key {
		return 0, ErrNoInstance
	}
	for i, c := range in.Members {
		if c == char {
			in.Members = append(in.Members[:i], in.Members[i+1:]...)
			break
		}
	}
	if len(in.Members) == 0 {
		in.EmptySince = m.clock() // re-stamped at 0 users (m:0x658f10)
	}
	if p, ok := m.presence[char]; ok && p.Instance == id && p.Key == key {
		delete(m.presence, char)
	}
	return len(in.Members), nil
}

// Presence implements Registry.
func (m *Memory) Presence(_ context.Context, char int64) (Place, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.presence[char]
	return p, ok, nil
}

// List implements Registry.
func (m *Memory) List(_ context.Context) ([]Instance, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Instance, 0, len(m.byID))
	for _, in := range m.byID {
		out = append(out, copyInstance(in))
	}
	sortInstances(out)
	return out, nil
}

func sortInstances(out []Instance) {
	sort.Slice(out, func(i, j int) bool {
		if out[i].ID.World != out[j].ID.World {
			return out[i].ID.World < out[j].ID.World
		}
		return out[i].ID.Layer < out[j].ID.Layer
	})
}

func sortHosts(out []Host) {
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
}
