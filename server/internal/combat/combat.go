// Package combat implements this project's own minimal PvE loop: monsters
// with HP that players can attack, using their equipped weapon's stats.
// Entirely own design.
package combat

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// ItemLookup resolves an item's stats, for reading a weapon's attack power.
// Satisfied by refdata.SQLStore in production.
type ItemLookup interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
}

// Monster is one attackable NPC.
type Monster struct {
	ID         int64
	Name       string
	Zone       string
	MaxHP      int
	HP         int
	Defense    int
	Attack     int // counter-damage dealt to whoever attacks it, before their own defense (none exists yet)
	GoldReward int64
}

// Hub tracks all live monsters, grouped by zone. Safe for concurrent use.
// In-memory only, same reasoning as world.Hub -- monster state resetting
// on restart is normal, not a bug.
type Hub struct {
	mu     sync.Mutex
	byID   map[int64]*Monster
	nextID atomic.Int64
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{byID: make(map[int64]*Monster)}
}

// Spawn creates a new monster in zone with full HP and returns it.
func (h *Hub) Spawn(zone, name string, maxHP, defense, attack int, goldReward int64) *Monster {
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID.Add(1)
	m := &Monster{ID: id, Name: name, Zone: zone, MaxHP: maxHP, HP: maxHP, Defense: defense, Attack: attack, GoldReward: goldReward}
	h.byID[id] = m
	return m
}

// Get returns a copy of the monster with the given ID, if it's still alive.
func (h *Hub) Get(id int64) (Monster, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	m, ok := h.byID[id]
	if !ok {
		return Monster{}, false
	}
	return *m, true
}

// InZone returns a snapshot of every live monster currently in zone. Used
// so a client can discover monster IDs to attack -- without this, a
// client has no way to learn a monster's ID at all (it's never broadcast
// on its own; only Attack's responses reference an ID the caller already
// supplied).
func (h *Hub) InZone(zone string) []Monster {
	h.mu.Lock()
	defer h.mu.Unlock()

	var out []Monster
	for _, m := range h.byID {
		if m.Zone == zone {
			out = append(out, *m)
		}
	}
	return out
}

// ApplyDamage reduces monster id's HP by amount (never below 0) and
// returns the updated monster, whether this hit killed it, and whether the
// monster existed at all. A dead monster is removed from the hub as part
// of this call -- callers that want a respawn need to Spawn a new one.
func (h *Hub) ApplyDamage(id int64, amount int) (monster Monster, died bool, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	m, exists := h.byID[id]
	if !exists {
		return Monster{}, false, false
	}

	m.HP -= amount
	if m.HP < 0 {
		m.HP = 0
	}
	result := *m

	if m.HP == 0 {
		delete(h.byID, id)
		return result, true, true
	}
	return result, false, true
}
