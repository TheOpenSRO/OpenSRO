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
	ID   int64
	Name string
	// CodeName is the characterdata key of the species (MOB_CH_MANGNYANG),
	// the same string in every client archive where Name is whatever
	// language column an archive carries. The client draws the model by it.
	CodeName string
	// Level is the monster's real level, recovered from the client's own
	// characterdata (_RefObjChar column 57 -- verified across 31 monsters:
	// Mangyang 1, Gyo 5 ... TigerWoman 110, monotonic with difficulty). Unlike
	// MaxHP/Attack (still disclosed defaults), the level is grounded. 0 if
	// unknown.
	Level int
	// Rarity is the monster's rank, grounded from characterdata (_RefObjChar
	// column 15): 0 normal, 1 champion, 3/8 unique, 4 giant, 5 titan, 6 elite.
	// The client maps it to the target-window rank gem (mapping recovered from
	// the retail client). Structural data, so grounded like Level.
	Rarity     int
	Zone       string
	X, Y, Z    float64 // own design placeholder position -- see Hub.Spawn
	MaxHP      int
	HP         int
	Defense    int
	Attack     int // counter-damage dealt to whoever attacks it, before their own defense (none exists yet)
	GoldReward int64
	// ExpReward is the experience a kill grants. Derived from the monster's
	// toughness for now (a disclosed default, ExpFor) -- the real per-species
	// experience lives in mob data this project does not load yet; recovering
	// it (like the item refdata) is a follow-up.
	ExpReward int64
	// SPReward is the skill points a kill grants -- the skill economy's income
	// (points are spent raising masteries, which unlocks skills). Skill points
	// come from mob kills in the real game, but the exact per-species amount is
	// in the same mob data (RefObjChar) this project does not load yet, so this
	// is a disclosed default (SPFor), the same status as ExpReward.
	SPReward int64
}

// ExpFor is the placeholder experience a monster of the given toughness
// grants on death: its max HP. A disclosed design choice, not recovered --
// the real value is in the client's mob data (RefObjChar's ExpToGive), which
// is not loaded yet.
func ExpFor(maxHP int) int64 {
	if maxHP < 1 {
		return 1
	}
	return int64(maxHP)
}

// SPFor is the placeholder skill points a monster of the given toughness
// grants on death: a tenth of its max HP, at least 1. A disclosed design
// choice, not recovered -- skill points come from mob kills in the real game,
// but the real per-species amount is in the mob data (RefObjChar), not loaded
// yet, the same status as ExpFor.
func SPFor(maxHP int) int64 {
	if maxHP < 10 {
		return 1
	}
	return int64(maxHP) / 10
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

// Spawn creates a new monster in zone at (x, y, z) with full HP and returns
// it. The position is this project's own placeholder design -- no real
// per-monster spawn coordinate data exists (see docs/protocol/
// refdata_schema.md); callers (server/cmd/server's monsterSpec) pick a
// fixed anchor point per species so multiple monsters don't stack exactly
// on top of each other, not a claim about the real game's actual spawn
// points.
func (h *Hub) Spawn(zone, name string, x, y, z float64, maxHP, defense, attack int, goldReward int64) *Monster {
	return h.SpawnSpecies(zone, Species{Name: name}, x, y, z, maxHP, defense, attack, goldReward)
}

// Species names a kind of monster both ways the game's tables do: the
// display name and the code name characterdata keys the row by.
type Species struct {
	Name     string
	CodeName string
	// Level is the real monster level from characterdata (_RefObjChar col 57).
	Level int
	// Rarity is the monster rank from characterdata (_RefObjChar col 15).
	Rarity int
}

// SpawnSpecies is Spawn with the species' code name carried along, so the
// client can resolve the model without depending on the display name.
func (h *Hub) SpawnSpecies(zone string, species Species, x, y, z float64, maxHP, defense, attack int, goldReward int64) *Monster {
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID.Add(1)
	m := &Monster{ID: id, Name: species.Name, CodeName: species.CodeName, Level: species.Level, Rarity: species.Rarity, Zone: zone, X: x, Y: y, Z: z, MaxHP: maxHP, HP: maxHP, Defense: defense, Attack: attack, GoldReward: goldReward, ExpReward: ExpFor(maxHP), SPReward: SPFor(maxHP)}
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
