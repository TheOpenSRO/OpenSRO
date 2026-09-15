// Package combat implements this project's own minimal PvE loop: monsters
// with HP that players can attack, using their equipped weapon's stats.
// Entirely own design.
package combat

import (
	"context"
	"math"
	"math/rand"
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
	Rarity  int
	Zone    string
	X, Y, Z float64 // own design placeholder position -- see Hub.Spawn
	MaxHP   int
	HP      int
	// Defense is a flat subtraction, still the disclosed curve.
	Defense int
	// DefensePercent is the monster's own mitigation percentage, and it is
	// REAL: characterdata columns 73 and 74 hold the physical and magical
	// reduction, and both equal the monster's level on every row of the
	// ORIGINAL client's table (Mangyang 1, Gyo 5, Yeoha 10, Bandit Archer 12).
	// The server reads them as ParamKeeper params 7 and 8 and applies them as
	// a percentage -- see MitigateDamage.
	DefensePercent int
	// Attack is the disclosed flat counter-damage, kept only as a fallback.
	Attack int
	// AttackMin/AttackMax are REAL: a monster attacks with a SKILL, not a
	// weapon. characterdata col 83 is its primary attack skill id (named after
	// the species -- MSKILL_CH_MANGNYANG_ATTACK01), and that skill's 'att'
	// param carries the damage range. With no weapon to scale, the project's
	// already-grounded skill formula collapses to rand(min, max).
	AttackMin, AttackMax int
	// GoldReward is the flat disclosed fallback; GoldMin/GoldMax are the real
	// per-level range. See RollGold.
	GoldReward       int64
	GoldMin, GoldMax int64
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

// MitigateDamage applies the game's own mitigation, which is a SHAPE this
// project had wrong rather than a number it had wrong.
//
// srrevamp subtracted defence flatly. SR_GameServer.exe does not:
// Formula_MitigatePhysicalDamage (0040e450) and its magical twin
// Formula_MitigateMagicalDamage (0040e830) -- structurally identical, gated on
// bits 4 and 8 of the flags at +0x230 -- compute
//
//	damage = raw / (1 + reductionPercent/100) - flatAbsorb        (floored at 0)
//
// with the reduction read as ParamKeeper param 7 (physical) or param 8
// (magical) through the getter virtual at vtable offset 0x104, and the
// constants 1.0 and 100.0 at .rdata 0x00b45ac0 and 0x00b45af0.
//
// Which side owns the reduction is settled by the formula's own monotonicity,
// not by assumption: a larger param 7 yields LESS damage, so it cannot be the
// attacker's -- a stat that weakens your own blows is not a stat. It is the
// defender's.
//
// The floor stays at 1 here rather than the game's 0, because a zero-damage hit
// in the real game is a miss, and srrevamp has no hit/evade roll yet (the
// 'hra'/'era' params exist and are unimplemented). That floor is own design,
// disclosed.
func MitigateDamage(raw, reductionPercent, flat int) int {
	if reductionPercent < 0 {
		reductionPercent = 0
	}
	reduced := float64(raw) / (1 + float64(reductionPercent)/100)
	out := int(math.Round(reduced)) - flat
	if out < 1 {
		out = 1
	}
	return out
}

// RollDamage picks a blow's damage uniformly in [min, max], the way the game
// does rather than always swinging for maximum.
//
// RECOVERED. Formula_RollWeaponDamage (0040f8d0) and its twin for the other
// damage type (0040f930) are three lines each:
//
//	min = GetParam(191);  max = GetParam(190)      // 193 / 192 on the twin
//	if max - min < 1 { return 0 }
//	return rand() % (max - min + 1) + min
//
// so the range is inclusive at both ends and a non-positive span yields nothing.
// Char_PublishCombatStats publishes 190/191 and 192/193 as the two types'
// min/max pairs, and this project already loads both ends of the range from the
// client's own itemdata (columns 12-15).
//
// r is the source of randomness; a nil r rolls the maximum, which keeps tests
// that want a fixed blow deterministic without a second code path.
func RollDamage(min, max int, r *rand.Rand) int {
	if max < min {
		min, max = max, min
	}
	if max-min < 1 {
		return max
	}
	if r == nil {
		return max
	}
	return min + r.Intn(max-min+1)
}

// RollGold picks a kill's gold in [min, max], falling back to flat when the
// caller has no range.
//
// The RANGE is real client data, the LINKAGE is inferred, and the difference
// matters. levelgold.txt ships with the original client shaped level -> min ->
// max (level 1 = 28-59, level 10 = 60-125), and the server's level-table
// manager holds a per-level gold table at +0x268 that a gold item is spawned
// from -- FUN_009348f0 creates ITEM_ETC_GOLD_03 with an amount rolled out of
// exactly that table, which is the use-site that makes it the gold table rather
// than a lookalike. What is NOT proven is that levelgold.txt is what fills it:
// the server references no refdata filename at all (it loads from its database),
// so no parser ties the file to the table. Two real things that fit perfectly,
// with the join inferred.
//
// It is still strictly better than the `10 + level*5` invention it replaces.
func RollGold(min, max int64, flat int64, r *rand.Rand) int64 {
	if max <= 0 || max < min {
		return flat
	}
	if r == nil || max == min {
		return max
	}
	return min + r.Int63n(max-min+1)
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
	// AttackMin/AttackMax are the real damage range of this species' primary
	// attack skill (characterdata col 83 -> that skill's 'att' param). Zero
	// means the caller has none and the flat disclosed Attack is used instead.
	AttackMin, AttackMax int
	// GoldMin/GoldMax are the real per-level gold range (levelgold.txt).
	GoldMin, GoldMax int64
}

// SpawnSpecies is Spawn with the species' code name carried along, so the
// client can resolve the model without depending on the display name.
func (h *Hub) SpawnSpecies(zone string, species Species, x, y, z float64, maxHP, defense, attack int, goldReward int64) *Monster {
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID.Add(1)
	m := &Monster{ID: id, Name: species.Name, CodeName: species.CodeName, Level: species.Level, Rarity: species.Rarity, Zone: zone, X: x, Y: y, Z: z, MaxHP: maxHP, HP: maxHP, Defense: defense, DefensePercent: species.Level, Attack: attack, AttackMin: species.AttackMin, AttackMax: species.AttackMax,
		GoldReward: goldReward, GoldMin: species.GoldMin, GoldMax: species.GoldMax, ExpReward: ExpFor(maxHP), SPReward: SPFor(maxHP)}
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
