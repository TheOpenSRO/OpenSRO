package registry

// The cluster half of the registry (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.2-12.4): the processes that run worlds
// (hosts), their heartbeats and load, the placement of a new instance on the
// least-loaded live host, every character's presence (which host holds it),
// its return point while it is inside an instance, and the reaper that
// declares a silent host dead and its instances lost. Memory implements it
// for one process and for tests that run several hosts in one binary;
// Postgres for several processes.

import (
	"context"
	"errors"
	"time"
)

// HostState is a host's state (OURS, game_worlds.md 12.3).
type HostState string

const (
	// HostActive takes new instances.
	HostActive HostState = "active"
	// HostDraining takes none; its instances run to their end or its
	// deadline (12.4).
	HostDraining HostState = "draining"
	// HostDead missed its heartbeat lease: its instances are lost.
	HostDead HostState = "dead"
)

// Host is one process that runs worlds.
type Host struct {
	ID string
	// Addr is its relay listener (host:port), where fronts open streams.
	Addr    string
	Version string
	State   HostState
	// OpenWorld: it runs world 1 layer 1 (the open world, logins, the
	// social services). Instances: it takes instance layers.
	OpenWorld bool
	Instances bool
	// Heartbeat is its last beat. Started is when the process started (a
	// beat carries it; zero: its first beat): the game clock's epoch of the
	// open world's host, which every other process keeps to (OURS).
	Heartbeat time.Time
	Started   time.Time
	// Players, Live (instances) and Load (a CPU score, cores busy) are what
	// it reported at its last beat.
	Players int
	Live    int
	Load    float64
}

// Character is one character's presence: who it is and which host holds its
// session (the presence row of 12.3).
type Character struct {
	ID       int64
	Name     string
	Level    int
	Account  int64
	Username string
	Host     string
}

// Return is a character's return point while it is in an instance (READ:
// the original keeps it on _Char, which the warp in does not overwrite,
// s:0x4df666): the place a lost instance or a dead host sends it back to.
type Return struct {
	Zone, Bucket, Frame string
	X, Y, Z             float64
}

// Reaped is what one reaper pass found: the hosts it declared dead and the
// instances they ran, now lost, each with the members it had.
type Reaped struct {
	Dead []Host
	Lost []Instance
}

// ErrNoHost is a placement with no live active host that takes instances.
var ErrNoHost = errors.New("registry: no live host takes instances")

// ErrHostDead is a heartbeat from a host the reaper declared dead: it must
// stop (OURS: the fence -- its instances were given up and its players
// moved).
var ErrHostDead = errors.New("registry: this host was declared dead")

// Cluster is the registry with the hosts, the presence and the reaper.
type Cluster interface {
	Registry
	// Beat records h's heartbeat and load (inserting its row the first
	// time). ErrHostDead when the reaper has declared it dead.
	Beat(ctx context.Context, h Host) error
	// Hosts is every host row, dead ones included, by id.
	Hosts(ctx context.Context) ([]Host, error)
	// SetHostState moves a host to s (a drain).
	SetHostState(ctx context.Context, id string, s HostState) error
	// Pick is the host a new instance goes to: the live active host taking
	// instances with the fewest open instances, then the fewest players,
	// then the lowest load; same-version hosts first. ErrNoHost for none.
	Pick(ctx context.Context, version string) (Host, error)
	// Reap declares dead every host whose heartbeat is older than the lease,
	// marks its instances lost and clears its presence. Only one process
	// reaps at a time (the PostgreSQL one holds an advisory lock).
	Reap(ctx context.Context) (Reaped, error)

	// Online records c as present on c.Host; Offline removes it when it is
	// still on host. Online lists everyone present.
	SetOnline(ctx context.Context, c Character) error
	SetOffline(ctx context.Context, char int64, host string) error
	Online(ctx context.Context) ([]Character, error)

	// SetReturn records char's return point at an instance entry;
	// ReturnOf reads it; ClearReturn drops it at the exit.
	SetReturn(ctx context.Context, char int64, r Return) error
	ReturnOf(ctx context.Context, char int64) (Return, bool, error)
	ClearReturn(ctx context.Context, char int64) error
}

// DefaultLease is how long a host may miss its heartbeat before the reaper
// declares it dead (game_worlds.md 12.4: 10 s); DefaultBeat how often a host
// beats (12.2: every 2 s).
const (
	DefaultLease = 10 * time.Second
	DefaultBeat  = 2 * time.Second
)

// ---- Memory ----

// memCluster is Memory's cluster state (guarded by Memory.mu).
type memCluster struct {
	hosts   map[string]*Host
	online  map[int64]Character
	returns map[int64]Return
	lease   time.Duration
}

func (m *Memory) cluster() *memCluster {
	if m.cl == nil {
		m.cl = &memCluster{hosts: map[string]*Host{}, online: map[int64]Character{}, returns: map[int64]Return{},
			lease: DefaultLease}
	}
	return m.cl
}

// SetLease sets the reaper's lease (tests; DefaultLease otherwise).
func (m *Memory) SetLease(d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cluster().lease = d
}

// Beat implements Cluster.
func (m *Memory) Beat(_ context.Context, h Host) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := m.cluster()
	now := m.clock()
	cur, ok := c.hosts[h.ID]
	if ok && cur.State == HostDead {
		return ErrHostDead
	}
	if !ok {
		if h.Started.IsZero() {
			h.Started = now
		}
		if h.State == "" {
			h.State = HostActive
		}
		cur = &h
		c.hosts[h.ID] = cur
	} else {
		st, started := cur.State, cur.Started
		if h.State != "" && h.State != st {
			st = h.State
		}
		if !h.Started.IsZero() {
			started = h.Started
		}
		*cur = h
		cur.State, cur.Started = st, started
	}
	cur.Heartbeat = now
	return nil
}

// Hosts implements Cluster.
func (m *Memory) Hosts(_ context.Context) ([]Host, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Host
	for _, h := range m.cluster().hosts {
		out = append(out, *h)
	}
	sortHosts(out)
	return out, nil
}

// SetHostState implements Cluster.
func (m *Memory) SetHostState(_ context.Context, id string, s HostState) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if h, ok := m.cluster().hosts[id]; ok {
		h.State = s
	}
	return nil
}

// Pick implements Cluster.
func (m *Memory) Pick(_ context.Context, version string) (Host, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.pickLocked(version)
}

func (m *Memory) pickLocked(version string) (Host, error) {
	c := m.cluster()
	now := m.clock()
	live := map[string]int{}
	for _, in := range m.byID {
		live[in.Host]++
	}
	var best *Host
	better := func(a, b *Host) bool {
		if (a.Version == version) != (b.Version == version) {
			return a.Version == version
		}
		if live[a.ID] != live[b.ID] {
			return live[a.ID] < live[b.ID]
		}
		if a.Players != b.Players {
			return a.Players < b.Players
		}
		if a.Load != b.Load {
			return a.Load < b.Load
		}
		return a.ID < b.ID
	}
	for _, h := range c.hosts {
		if h.State != HostActive || !h.Instances || now.Sub(h.Heartbeat) > c.lease {
			continue
		}
		if best == nil || better(h, best) {
			best = h
		}
	}
	if best == nil {
		return Host{}, ErrNoHost
	}
	return *best, nil
}

// Reap implements Cluster.
func (m *Memory) Reap(_ context.Context) (Reaped, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := m.cluster()
	now := m.clock()
	var r Reaped
	dead := map[string]bool{}
	for _, h := range c.hosts {
		if h.State != HostDead && now.Sub(h.Heartbeat) > c.lease {
			h.State = HostDead
			dead[h.ID] = true
			r.Dead = append(r.Dead, *h)
		}
	}
	if len(dead) == 0 {
		return r, nil
	}
	sortHosts(r.Dead)
	for id, in := range m.byID {
		if !dead[in.Host] {
			continue
		}
		lost := copyInstance(in)
		lost.State = StateLost
		r.Lost = append(r.Lost, lost)
		for _, ch := range in.Members {
			if p, ok := m.presence[ch]; ok && p.Instance == id && p.Key == in.Key {
				delete(m.presence, ch)
			}
		}
		delete(m.byID, id)
	}
	sortInstances(r.Lost)
	for id, ch := range c.online {
		if dead[ch.Host] {
			delete(c.online, id)
		}
	}
	return r, nil
}

// SetOnline implements Cluster.
func (m *Memory) SetOnline(_ context.Context, ch Character) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cluster().online[ch.ID] = ch
	return nil
}

// SetOffline implements Cluster.
func (m *Memory) SetOffline(_ context.Context, char int64, host string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := m.cluster()
	if cur, ok := c.online[char]; ok && cur.Host == host {
		delete(c.online, char)
	}
	return nil
}

// Online implements Cluster.
func (m *Memory) Online(_ context.Context) ([]Character, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Character
	for _, ch := range m.cluster().online {
		out = append(out, ch)
	}
	return out, nil
}

// SetReturn implements Cluster.
func (m *Memory) SetReturn(_ context.Context, char int64, r Return) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cluster().returns[char] = r
	return nil
}

// ReturnOf implements Cluster.
func (m *Memory) ReturnOf(_ context.Context, char int64) (Return, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.cluster().returns[char]
	return r, ok, nil
}

// ClearReturn implements Cluster.
func (m *Memory) ClearReturn(_ context.Context, char int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.cluster().returns, char)
	return nil
}

var _ Cluster = (*Memory)(nil)
