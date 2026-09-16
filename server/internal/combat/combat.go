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
	// Mangyang 1, Gyo 5 ... TigerWoman 110, monotonic with difficulty). 0 if
	// unknown. (This used to add "unlike MaxHP/Attack, still disclosed
	// defaults"; MaxHP has been real since 2026-09-14, characterdata col 59,
	// and the attack range since the same pass -- col 83's skill 'att'.)
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
	// Defense is the monster's flat absorption, and it is REAL: characterdata
	// col 71, which GObjMob_PublishStats publishes into ParamKeeper param 5 --
	// exactly the term Formula_MitigatePhysicalDamage subtracts. See
	// cmd/server's monsterSpec, which carries it per species.
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
	// Critical is this monster's critical-hit chance, rolled by RollChance
	// against 0..100. REAL: characterdata _RefObjChar col 78.
	//
	// The column is settled by disassembling GObjMob_PublishStats
	// (004c3730), which publishes the monster's ref-object fields into
	// ParamKeeper params in a consecutive 4-byte run -- +0x230 -> param 5,
	// +0x234 -> 6, +0x238 -> 7, +0x23c -> 8, +0x240 -> 9, +0x244 -> 10,
	// +0x248 -> 11, +0x24c -> 12. Two of those offsets were already proven
	// (+0x230 = col 71, the flat absorb; +0x238 = col 73, the reduction
	// percentage), which anchors the run onto columns 71..78 and puts
	// 'cri' (param 12) on col 78.
	//
	// The data agrees four ways: cols 73 and 74 equal the monster's level
	// exactly on every row, cols 75 and 77 are identical (25 + 2*level),
	// col 76 is 0 for every monster on the Jangan ladder -- blocking is a
	// shield mechanic -- and col 78 reads 2 on 7,493 of the game's 7,495
	// monster rows.
	Critical int
	// Block is this monster's chance to block a blow outright, characterdata
	// _RefObjChar col 76 ('bri'), published into ParamKeeper param 10 by the
	// same consecutive run that puts Critical on col 78 -- see Critical for
	// how that run is anchored.
	//
	// It is 0 for every species on the Jangan ladder, and that is the real
	// value rather than an unmodelled one: blocking is a shield mechanic and
	// monsters carry no shields. 938 of the game's other monsters do read 20.
	Block int
	// ExpReward is the disclosed toughness-derived fallback (ExpFor), used only
	// when no level table is loaded. The real reward is leveldata.KillExp, and
	// it is NOT per-species: Formula_MonsterExpReward reads the level table's
	// own per-level unit at the minimum of the two levels and scales it by the
	// level gap, so a monster contributes only its Level. There is no mob
	// experience column to recover.
	ExpReward int64
	// SPReward is the disclosed whole-point fallback (SPFor), used only when no
	// level table is loaded. Normally the skill economy is fed by skill
	// EXPERIENCE converted at leveldata.SkillExpPerPoint -- see that constant,
	// and session's kill path. The conversion is recovered; how much skill
	// experience a kill is worth is not, and srrevamp credits the kill's own
	// experience as a disclosed stand-in.
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
// The floor stays at 1 here rather than the game's 0. That is own design and
// disclosed -- but the REASON has been corrected: an earlier note here said a
// zero-damage hit is a miss in the real game and that srrevamp "has no
// hit/evade roll yet", implying one was waiting to be implemented.
//
// There is no such roll to implement. ParamKeeper params 9 ('era', parry rate)
// and 11 ('hra', attack rate) are published -- by Char_PublishCombatStats from
// the item aggregate, by GObjMob_PublishStats from characterdata, by
// GObjPC_InitStats with a base of 10.0, and by three skill codes -- and then
// read by NOTHING. Every GetParam call in the binary was enumerated, literal
// and computed alike (the computed ones resolve to 13/14, 15/16, and
// 0x80-0x83), and neither 9 nor 11 appears among them.
//
// What the engine actually rolls in Combat_ResolveDamage is blocking (param 10,
// 'bri') opposed by 56 ('evbl'), and critical (12, 'cri') opposed by 57
// ('evcr') -- both of which this project already models, and both of which are
// unopposed against monsters because GObjMob_PublishStats publishes neither 56
// nor 57. So srrevamp is not missing a hit/miss mechanic; the game resolves a
// swing as blocked or not, never as a miss.
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

// ApplySkillPercent scales an already-mitigated blow by a skill's attack
// percentage. percent <= 0 means the skill declares none and the blow is
// unchanged.
//
// ORDER, and it is the whole point of this function existing separately:
// the game applies a skill's percentage AFTER mitigation and after the clamp
// at zero, not to the raw roll. Formula_MitigatePhysicalDamage (0040e450),
// disassembled because the decompiled C loses the registers here:
//
//	40e50a  push 0x5  ; ecx=edi ; call [edx+0x104]   <- defender's flat absorb
//	40e524  push 0x7  ; ecx=edi ; call [edx+0x104]   <- defender's reduction %
//	40e52a  fdiv qword [0x00b45af0]                  <- /100
//	40e538  fadd qword [0x00b45ac0]                  <- +1.0
//	40e53e  fdivr qword [esp+0x10]                   <- raw / (1 + pct/100)
//	40e542  fsub dword [esp+0x18]                    <- - flat
//	40e54a  fldz / fcom / fst                        <- clamped at 0
//	40e56e  fild dword [eax+0x4]                     <- the skill's percentage
//	40e57e  fmul dword [esp+0x24]
//	40e582  fdiv qword [0x00b45af0]                  <- * pct / 100
//
// The struct at +0x230 that `eax` points at is the attack descriptor, and its
// three numeric fields are exactly what this project already reads out of
// skilldata's 'att' parameter: the percentage at +4, and a flat min/max pair at
// +8/+0xc. The flat pair goes in EARLIER, added to the rolled bound inside
// FUN_0040db50 (40db86 reads +0x8 for the minimum, 40db8b +0xc for the
// maximum), so the two halves of a skill's damage land on opposite sides of
// mitigation and cannot be folded into one number.
//
// Applying the percentage to the raw roll instead -- which this code did until
// 2026-09-15 -- differs whenever the defender has any flat absorb:
// `(raw*p)/(1+m) - flat` against `(raw/(1+m) - flat)*p`. The first scales the
// defence away, so a 200% skill paid only half the armour it should. It is the
// same mistake, and the same fix, as the berserk multiplier's ordering.
func ApplySkillPercent(damage, percent int) int {
	if percent <= 0 || percent == 100 {
		return damage
	}
	out := int(math.Round(float64(damage) * float64(percent) / 100))
	if out < 1 {
		out = 1
	}
	return out
}

// LevelAdvantagePerLevel and LevelAdvantageCap are the real level-difference
// damage term: an attacker who out-levels its target hits harder, 3% per level
// and no more than 30%.
//
// RECOVERED 2026-09-15 from Formula_MitigatePhysicalDamage (0040e450), which
// ends with
//
//	defLvl = Char_GetLevel(defender);  atkLvl = Char_GetLevel(attacker)
//	if defLvl < atkLvl { damage = (FUN_0040fd60() + 1.0) * damage }
//
// and FUN_0040fd60, disassembled because the decompiled register arguments are
// ambiguous about which level is subtracted from which:
//
//	MOV EDX,[EAX + 0x124] ; CALL EDX ; MOVZX ESI,AL   <- level(ECX)
//	MOV EDX,[EAX + 0x124] ; CALL EDX ; MOVZX EAX,AL   <- level(EDI)
//	SUB ESI,EAX                                       <- level(ECX) - level(EDI)
//	FMUL double [0x00b45dc8]                          <- * 0.03
//	FLDZ / FCOM                                       <- clamped at 0 below
//	... and at 0.3 above (float 0x00b45b8c)
//
// Which of the two objects is the attacker is settled by an independent fact
// rather than by the argument order: the same function reads the DEFENCE
// params 5 and 7 off the other one, and this project already established that
// those are the target's (GObjMob_PublishStats publishes characterdata cols 71
// and 73 into exactly them). So the object whose level is subtracted FROM is
// the attacker, and the bonus favours out-levelling.
//
// ORDER: the game applies this after mitigation and after the berserk
// multiplier, which is the last thing it does to the number before rounding.
const (
	LevelAdvantagePerLevel = 0.03
	LevelAdvantageCap      = 0.30
)

// LevelAdvantage is the multiplier an attacker of attackerLevel gets against a
// defender of defenderLevel: 1.0 when it does not out-level the target, rising
// 3% per level to a maximum of 1.3.
func LevelAdvantage(attackerLevel, defenderLevel int) float64 {
	d := attackerLevel - defenderLevel
	if d <= 0 {
		return 1
	}
	bonus := float64(d) * LevelAdvantagePerLevel
	if bonus > LevelAdvantageCap {
		bonus = LevelAdvantageCap
	}
	return 1 + bonus
}

// ApplyLevelAdvantage scales a already-mitigated blow by LevelAdvantage. A
// blow never drops below 1 -- the same floor MitigateDamage keeps, and this
// term only ever multiplies up, so the floor is just carried through.
func ApplyLevelAdvantage(damage, attackerLevel, defenderLevel int) int {
	out := int(math.Round(float64(damage) * LevelAdvantage(attackerLevel, defenderLevel)))
	if out < 1 {
		out = 1
	}
	return out
}

// ReinforcePercentScale converts an itemdata reinforce column into a percent.
// The table stores tenths of a percent -- a Copper Sword's 306 is 30.6% -- and
// the engine's innate defaults confirm the unit: GObjPC_InitStats writes 30.6
// as param 34's base from .rdata 0x00b462a8, and 306 is exactly the floor of
// column 105 across all 1,568 weapon rows.
const ReinforcePercentScale = 10

// ReinforceDamage is the Strength-derived term added to one end of a weapon's
// damage range: Str * reinforce%, where reinforceTenths is the itemdata column
// in its own unit (see ReinforcePercentScale).
//
// RECOVERED. GObjPC_InitStats (004e3200) declares the chain as graph edges:
// param 1 (Strength) binds into param 17 at slot 0, param 34 (the weapon's
// physical reinforce) binds into param 17 at slot 3, and param 17 binds into
// param 13 at slot 0. Slot 3 is the percent scale -- ParamKeeper_EvaluateParam
// divides it by 100 -- so param 17 evaluates to Str*reinforce/100.
//
// It ADDS to the weapon's own range rather than replacing it. Param 13's slot 0
// receives two entries: the weapon's flat minimum (stored by
// Char_PublishCombatStats with ctx = the equipped item) and this derived term
// (stored by Param_PropagateToDependents with ctx = the source param's object).
// A slot is a container keyed by ctx, so distinct keys coexist, and slot 0's
// reduce (GParamKeeper 004b2e60) sums its entries.
//
// The use-site is FUN_0040db50, the helper the attack roll calls once per
// bound: it reads GetParam((EDI != 0) + 0xd), i.e. param 13 or 14 -- a computed
// id, which is why a literal-id search of the dump finds no reader for these
// two params and finding none proves nothing.
//
// Rounded rather than truncated: the engine carries the whole chain in floats
// and rounds once at the end, so truncating here would bias every blow down.
func ReinforceDamage(str int, reinforceTenths float64) int {
	if str <= 0 || reinforceTenths <= 0 {
		return 0
	}
	return int(math.Round(float64(str) * reinforceTenths / (ReinforcePercentScale * 100)))
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
// **The linkage got WEAKER, not stronger, on 2026-09-15.** Enumerating the
// server's SQL refdata tables turned up 85 of them, including `_REFLEVEL` (the
// leveldata equivalent) and `_REFDROPGOLD` -- but **no `_REFLEVELGOLD`**. So the
// server's gold table is named after *drops*, not after levelgold, and the file
// this range comes from may be the client's own copy of something else. The
// server loads its refdata from that database rather than from any file (it
// references no refdata filename anywhere), so nothing here ties levelgold.txt
// to the `+0x268` table that the gold item is actually spawned from.
//
// Kept anyway, because the honest comparison is against what it replaced: a
// made-up `10 + level*5`. A real client table of per-level gold ranges is better
// evidence than an invention, and the gap is named rather than hidden. If an
// operator ever supplies `_REFDROPGOLD`, that supersedes this outright.
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
// grants on death: its max HP. A disclosed design choice, and a FALLBACK ONLY:
// the kill path uses leveldata.KillExp, the real formula, whenever a level
// table is loaded. This is what remains for an export with no exp_unit column.
//
// An earlier note here sent the reader looking for "RefObjChar's ExpToGive".
// There is no such field in the formula: Formula_MonsterExpReward (004105d0)
// reads the LEVEL TABLE's per-level unit at the minimum of the two levels and
// scales it, and the monster contributes only its level. Nothing per-species is
// read, so there is no mob column to load.
func ExpFor(maxHP int) int64 {
	if maxHP < 1 {
		return 1
	}
	return int64(maxHP)
}

// SPFor is the disclosed whole-point fallback, used only when no level table is
// loaded and there is therefore no experience to convert.
//
// The normal path does not use it. The game grants skill EXPERIENCE and
// converts it at leveldata.SkillExpPerPoint, carrying the remainder on the
// character; srrevamp does the same, crediting a kill's own experience as skill
// experience. Granting whole points per kill cannot reproduce that pacing at
// any rate, because it rounds each kill up or down to a whole point.
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
	// Critical is the species' real critical-hit chance, characterdata
	// _RefObjChar col 78. See Monster.Critical.
	Critical int
	// Block is the species' real block chance, characterdata col 76. See
	// Monster.Block.
	Block int
}

// SpawnSpecies is Spawn with the species' code name carried along, so the
// client can resolve the model without depending on the display name.
func (h *Hub) SpawnSpecies(zone string, species Species, x, y, z float64, maxHP, defense, attack int, goldReward int64) *Monster {
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID.Add(1)
	m := &Monster{ID: id, Name: species.Name, CodeName: species.CodeName, Level: species.Level, Rarity: species.Rarity, Critical: species.Critical, Block: species.Block, Zone: zone, X: x, Y: y, Z: z, MaxHP: maxHP, HP: maxHP, Defense: defense, DefensePercent: species.Level, Attack: attack, AttackMin: species.AttackMin, AttackMax: species.AttackMax,
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

// ChanceRollSides is the number of distinct values the game's chance roll can
// take: rand() % 101, an integer in [0, 100] INCLUSIVE. Not 100 -- the modulus
// in the binary is 0x65.
const ChanceRollSides = 101

// CriticalMultiplier is what a critical hit does: it doubles.
//
// Formula_MitigatePhysicalDamage builds a damage multiplier, 1.0 by default and
// `GetParam(189) + 2.0` for a berserk attacker, and then
//
//	if (flags & 2) { multiplier = multiplier + multiplier }
//
// before multiplying the already-mitigated damage by it. Bit 1 of those flags is
// set by Combat_ResolveDamage when the critical roll succeeds, so an ordinary
// critical turns 1.0 into 2.0. It doubles whatever the multiplier already is,
// which is why a berserk critical is 4.6x rather than 2.3x + 2.
const CriticalMultiplier = 2

// RollChance is the game's own chance roll, used for criticals and blocks.
//
// RECOVERED 2026-09-15 from FUN_00599cc0, reached through FUN_005a1a20 from
// Combat_ResolveDamage:
//
//	if chance == 0            -> fail, no roll taken
//	if chance >= 100          -> succeed, no roll taken
//	otherwise                 -> succeed when chance >= rand() % 101
//
// so the roll is inclusive at both ends and a chance of 100 is a certainty
// rather than a 100-in-101 near-certainty.
//
// NOW MODELLED, 2026-09-16, and this note used to say otherwise. The real
// function also keeps a per-actor accumulator, raised by `chance` on every
// failure and dropped by 100 on every success, and rolls against that
// accumulated value rather than the raw chance -- bad-luck protection. The
// blocker recorded here was "reproducing it needs per-actor state this project
// does not carry", which stopped being true once the package grew trackers of
// its own. See RollChanceTracked and ChanceTracker in chancememory.go.
//
// RollChance itself is unchanged and stays the memoryless roll: it is what a
// nil tracker falls back to, and what every test asserting an exact outcome
// depends on.
//
// r is the source of randomness. A nil r takes the MAXIMUM outcome -- any
// positive chance succeeds -- which is the same convention RollDamage and
// RollGold already use in this package, and is what lets a caller switch the
// randomness off and still assert exact numbers. Getting this backwards is a
// silent failure rather than a loud one: internal/session's TestMain nils the
// generator on purpose, so a nil-means-never rule made every critical in every
// session test quietly impossible.
func RollChance(chance int, r *rand.Rand) bool {
	if chance <= 0 {
		return false
	}
	if chance >= 100 || r == nil {
		return true
	}
	return chance >= r.Intn(ChanceRollSides)
}

// Blow is one resolved strike: what it did, and which of the game's outcomes
// it took.
type Blow struct {
	Damage   int
	Critical bool
	Blocked  bool
}

// ResolveBlow runs the game's damage pipeline once, in the order the engine
// runs it. Every attack in srrevamp goes through here -- a player hitting a
// monster, a monster's counterattack, and one player duelling another -- so the
// three cannot drift apart again.
//
// They had. The PvE path collected six recoveries in a row (the mitigation
// shape, berserk, the level term, criticals, blocking, the death penalty) while
// the duel path kept the bare `base - armor` it was written with, and the
// grounding audit went on claiming PvP "reuses the same combat model". That is
// what duplicated logic does; one function is the fix.
//
// The order is the real one, from Formula_MitigatePhysicalDamage:
//
//	a successful BLOCK skips everything -- the real resolve function jumps past
//	  every Formula_Mitigate* call, so no damage is computed at all
//	otherwise  mitigate:  damage / (1 + pct/100) - flat
//	then       multiply:  x2 on a critical (the engine doubles a multiplier
//	                      berserk may already have raised)
//	then       scale:     the level-difference term, applied last
//
// Berserk is NOT applied here. It is per-character state this package does not
// hold, and the caller that has it applies it between the critical and the
// level term -- see session's use of berserk.Tracker.Boost.
//
// r is the source of randomness; a nil r takes the maximum outcome on every
// roll, the same convention RollDamage and RollChance use.
//
// mem carries the engine's per-actor bad-luck accumulators (see
// chancememory.go). It may be nil, in which case both rolls are memoryless --
// which is what every test that asserts an exact outcome relies on. The BLOCK
// roll is the defender's and the CRITICAL roll is the attacker's, so the two
// draw on different actors' streaks, which is why ChanceMemory carries both
// ids rather than one.
func ResolveBlow(base, mitigationPercent, flat, critChance, blockChance, attackerLevel, defenderLevel int, r *rand.Rand, mem *ChanceMemory) Blow {
	if mem.roll(blockChance, r, mem.defender(), ChanceBlock) {
		return Blow{Blocked: true}
	}
	out := Blow{Damage: MitigateDamage(base, mitigationPercent, flat)}
	if mem.roll(critChance, r, mem.attacker(), ChanceCritical) {
		out.Damage *= CriticalMultiplier
		out.Critical = true
	}
	// Both levels must be known. A zero is "not set", not "level zero".
	if attackerLevel > 0 && defenderLevel > 0 {
		out.Damage = ApplyLevelAdvantage(out.Damage, attackerLevel, defenderLevel)
	}
	return out
}
