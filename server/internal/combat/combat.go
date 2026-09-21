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
	"time"

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
	// RefObjID is the species' numeric characterdata id (_RefObjChar col 1;
	// MOB_CH_MANGNYANG is 1933). It is the key the real drop tables use --
	// _RefMonster_AssignedItemRndDrop.RefMonsterID -- so a kill can only
	// consult real drop data if the monster carries it.
	//
	// combat/loot.go named its absence as one of the two things standing
	// between this project and the real drop path; cmd/server has carried
	// monsterSpec.RefObjID since 2026-09-19 and simply never passed it down.
	// 0 when unknown, which falls back to the own-design LootTables.
	RefObjID int64
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
	Rarity int
	// BCRadius is the species' collision radius (characterdata col 50), the
	// monster's half of the attack-distance rule's base -- see ApproachBand.
	BCRadius int
	// AttackReuseMs / AttackRange: the primary attack skill's ReuseDelay and
	// Range -- see Species. The hub's CounterattackReady enforces the delay.
	AttackReuseMs int
	AttackRange   int
	Zone          string
	X, Y, Z       float64 // own design placeholder position -- see Hub.Spawn
	MaxHP         int
	HP            int
	// Defense is the monster's flat absorption, and it is REAL: characterdata
	// col 71, which GObjMob_PublishStats publishes into ParamKeeper param 5 --
	// exactly the term Formula_MitigatePhysicalDamage subtracts. See
	// cmd/server's monsterSpec, which carries it per species.
	Defense int
	// DefensePercent is the monster's own mitigation percentage, and it is
	// REAL: characterdata columns 73 and 74 hold the physical and magical
	// reduction, and the server reads them as ParamKeeper params 7 and 8 and
	// applies them as a percentage -- see MitigateDamage.
	//
	// Hub.Spawn passes the monster's LEVEL here, because the two columns equal
	// the level. That used to rest on four hand-checked rows (Mangyang 1, Gyo
	// 5, Yeoha 10, Bandit Archer 12), which is the sample size that has misread
	// a characterdata column twice before. MEASURED 2026-09-16 across the whole
	// table instead:
	//
	//	7,495 MOB_ rows with a level     -> 99.45% have BOTH columns == level
	//	41 diverge
	//
	// so the rule is real rather than a coincidence of four rows, but it is NOT
	// universal. The 41 exceptions are bosses, uniques and quest clones --
	// MOB_EU_KERBEROS is level 110 with 24, MOB_TQ_WHITESNAKE level 110 with
	// 105, the MOB_QT_*_CLON quest spawns give the two columns DIFFERENT values
	// (level 29 with 29 and 54) -- which is exactly the population where a
	// designer would hand-tune mitigation away from the level.
	//
	// All 11 species this server currently spawns were checked individually and
	// every one holds the equality, so passing the level is correct today. It
	// stops being correct the moment a boss or a quest clone is added: those
	// need the real columns carried on Species, not the level.
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
// (magical) through IGObj::GetParam, vtable slot 65 / offset 0x104 -- named
// 2026-09-16 from the base class's own stub string, having been read as "the
// getter virtual" until then (docs/protocol/igobj_vtable.md) -- and the
// constants 1.0 and 100.0 at .rdata 0x00b45ac0 and 0x00b45af0.
//
// Which side owns the reduction is settled by the formula's own monotonicity,
// not by assumption: a larger param 7 yields LESS damage, so it cannot be the
// attacker's -- a stat that weakens your own blows is not a stat. It is the
// defender's.
//
// CONFIRMED A SECOND WAY 2026-09-16, from the registers rather than the shape.
// The formula takes the defender in EDX and the attacker as its first stack
// argument, and it asks the EDX object what it is before reading a stat off the
// other one:
//
//	40e5ba  mov edx,[eax+0x28]    ; slot 10 = IGObj::IsMonster   on EDX
//	40e5c7  mov edx,[eax+0x12c]   ; slot 75 = GetMonsterClass    on EDX
//	40e5d1  cmp al,0x3 / jne skip
//	40e5d8  mov edx,[eax+0x104]   ; GetParam                     on the STACK object
//	40e5de  push 0x103
//
// A bonus conditioned on what the target IS belongs to the attacker, so EDX is
// the target. Two independent routes, one answer.
//
// WHAT SRREVAMP DOES NOT MODEL, so it is not mistaken for a gap: the full
// pipeline reads seven params, four of them the attacker's. Step 4 above is an
// anti-monster-class bonus (param 259, a percentage, only against monster class
// 3); steps 3, 5 and 6 are further attacker percentages (128/129, 189,
// 178/179). No srrevamp item or skill publishes any of them, so they are
// unreachable rather than omitted. The defender's side -- params 5/7 here, plus
// 180 -- is what this function implements. Full table:
// docs/protocol/param_registry.md.
//
// THE FLOOR OF 1 IS THE GAME'S OWN, corrected 2026-09-16. This note used to say
// "the floor stays at 1 here rather than the game's 0. That is own design and
// disclosed" -- which was wrong about the game, and wrong in the direction that
// makes srrevamp look less faithful than it is.
//
// The zero the earlier reading found is real but is not the end of the
// pipeline: Formula_MitigatePhysicalDamage clamps its result at 0, and then
// Combat_ResolveDamage floors the finished blow at 1:
//
//	if (damage == 0) {
//	    if (local_d0 == 0) { damage = 1; }
//	    else { ... a different path for skills with no attack parameter ... }
//	}
//
// `local_d0` is set to 1 only when the skill carries NEITHER 'att' (0x230) nor
// 'ck' (0x248) -- a buff or utility skill. So `local_d0 == 0` is exactly the
// case of a blow that HAS an attack parameter, which includes every ordinary
// swing (SKILL_CH_SWORD_BASE_01 carries att at 60%). For those the engine
// guarantees at least 1 damage.
//
// So srrevamp's floor is faithful rather than invented. The earlier note read
// the mitigation clamp and stopped there, missing the floor applied a stage
// later -- which is why this file now says where in the pipeline each clamp
// lives.
//
// EXTENDED 2026-09-18, because the description above is true but partial in two
// ways that matter.
//
// First, `local_d0` does more than pick the floor: it gates the
// Formula_MitigatePhysicalDamage call itself. Every branch that mitigates is
// under `if (local_d0 == 0)`, so a skill with no attack parameter does not take
// the physical path at all. What it takes instead has not been read, so nothing
// here claims what such a skill deals.
//
// Second, there is an EARLY RETURN before `local_d0` is ever set, and it is the
// part with a settled meaning. The test is 33 parameters wide -- the whole
// vocabulary of "does this skill do anything in combat", see
// skillparam.CombatParameters -- and a skill carrying none of them, with no
// 'efr' whose second value is 6, makes Combat_ResolveDamage return before it
// resolves anything. No blow, not a blow of zero.
//
// That is 1,797 of the 32,367 real skill rows that walk cleanly (5.6%).
// srrevamp gives every one of them DisclosedSkillDamagePerLevel * level
// instead, because session.skillDamageBonus falls back to the disclosed bonus
// whenever AttackPercent is zero. Closing that needs the exporter to say
// whether a skill carries any combat parameter, which is a new column rather
// than a new constant; it is queued, not done.
//
// The REASON attached to the old note is unaffected and still correct: an even
// earlier version said a zero-damage hit is a miss in the real game and that
// srrevamp "has no hit/evade roll yet", implying one was waiting to be
// implemented.
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
// ('evcr') -- both of which this project already models. So srrevamp is not
// missing a hit/miss mechanic; the game resolves a swing as blocked or not,
// never as a miss.
//
// NARROWED IN ROUND 406. This paragraph used to end "both of which are
// unopposed against monsters because GObjMob_PublishStats publishes neither 56
// nor 57", and that reason is true but covers only TWO of the six divisors
// srrevamp's three attack directions need -- the evader is a player in the
// other four, and a monster's publisher says nothing about those. All six are
// still zero; four of them for a different and weaker reason. The census and
// both reasons are in EvadedChance, which every call site now goes through.
//
// CONFIRMED FROM A SECOND ARTEFACT 2026-09-16. `MagicOption.txt` names these
// tags itself and says which item kind carries each: MATTR_CRITICAL ('cri') on
// a weapon against MATTR_EVADE_CRITICAL ('evcr') on a shield, and
// MATTR_BLOCKRATE ('bri') on a shield against MATTR_EVADE_BLOCK ('evbl') on a
// weapon. Attacker's weapon, defender's shield, both ways round -- exactly the
// pairing above, from a table none of it was derived from.
//
// That table also checks the two names in the paragraph before this one rather
// than overturning them: MATTR_ER sits on `armor` and MATTR_HR on `weapon`, so
// 'er'/'hr' are the parry and attack ratios, and reading ER as "evasion" would
// have been a wrong correction. (Params 9 and 11 carry the AVATAR variants
// 'era'/'hra', a separate family that sits on cosmetic pieces -- see
// paramtags.go.) Full vocabulary: docs/protocol/magic_options.md.
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

// SkillPercentZero says the skill's percentage is a REAL zero, as opposed to the
// 0 that means "this blow carries no skill percentage" (a plain attack, or an
// own-design catalog skill).
//
// The two are different in the engine and were conflated here until 2026-09-18.
// When the attack descriptor exists the multiply is unconditional -- the
// disassembly below has no branch around `fild [eax+4] / fmul / fdiv 100`, in
// either the physical formula or its magical twin (0040e830) -- so a percent of
// zero makes the mitigated blow zero, every later term being proportional to
// it. Combat_ResolveDamage then floors a computed zero at 1:
//
//	if (total == 0) { if (local_d0 == 0) { total = 1; } ... }
//
// So the blow is exactly 1. It is negative because no real percentage can be:
// the engine reads the field unsigned (it adds 2^32 to a negative int before
// the multiply). See skillparam.BlowIsFloor for the full class -- 446 real
// rows -- and refdata.Skill.FloorBlow for how a skill is known to be in it.
const SkillPercentZero = -1

// ApplySkillPercent scales an already-mitigated blow by a skill's attack
// percentage. percent == 0 means the blow carries no skill percentage and is
// unchanged; SkillPercentZero means a real percentage of zero, which the
// engine's floor turns into exactly 1.
//
// ORDER, and it is the whole point of this function existing separately:
// the game applies a skill's percentage AFTER mitigation and after the clamp
// at zero, not to the raw roll. Formula_MitigatePhysicalDamage (0040e450),
// disassembled because the decompiled C loses the registers here:
//
//	40e50a  push 0x5  ; ecx=edi ; call [edx+0x104]   <- GetParam(5),  flat absorb
//	40e524  push 0x7  ; ecx=edi ; call [edx+0x104]   <- GetParam(7),  reduction %
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
	if percent == SkillPercentZero {
		return 1
	}
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

// SkillLevelPenaltyPerLevel and SkillLevelPenaltyFloorPercent are the OPPOSITE
// level-difference term: a skill's own physical damage is scaled DOWN when the
// TARGET out-levels the attacker, 2.5% per level, floored at 10% of the base.
//
// Note the asymmetry with LevelAdvantage above -- 3% per level up to +30% for
// out-levelling, 2.5% per level down to 10% for being out-levelled. Two
// different rates, in two different functions, which is why neither can be
// assumed from the other.
//
// RECOVERED from Formulae::Formula_SkillPhysDamage (0040f5f0, 248 bytes), whose
// assert names its own source file:
//
//	"... File: %s, Line: %d", "D:\WORK2005\...\SR_GameServer\Formulae.cpp", 0x436
//
// The body, after a flat bonus is added to the base:
//
//	40f62c  uVar2 = level(param_3) ; uVar3 = level(param_2)
//	40f63b  sub eax,esi                  ; d = level(param_2) - level(param_3)
//	40f643  jle done                     ; only when d > 0
//	40f651  fild  d
//	40f655  fmul  QWORD ds:0xb45e50      ; * 2.5
//	40f65b  fld   QWORD ds:0xb45af0      ; 100.0
//	40f661  fdiv  st(1),st               ; (d * 2.5) / 100
//	40f663  fld1
//	40f665  fsubrp st(2),st              ; 1 - (d * 2.5)/100
//	40f66d  fmulp                        ; base * that
//	40f671  call  __ftol2                ; TRUNCATES toward zero
//	40f678  lea ecx,[edi+edi*4] / add ecx,ecx / imul 0x51eb851f / sar edx,5
//	                                     ; floor = base * 10 / 100
//	        return clamp(scaled, floor, base)
//
// The `imul 0x51eb851f ; sar edx,5` pair is the compiler's magic-number
// division by 100, not a constant of the game.
//
// WHICH PARTICIPANT IS THE ATTACKER -- settled 2026-09-17, three ways.
// The argument order alone cannot settle it: Combat_ResolveDamage (0058e5f0)
// calls this twice and the two sites look swapped --
//
//	58f4fc  push edi ; mov edx,esi ; call 0x40f5f0
//	58fbab  push esi ; mov edx,edi ; call 0x40f5f0
//
// -- but that is register allocation, not argument order. Both sites load the
// SAME two stack slots (58f4bc/58fb5d read [esp+0x124], 58f468/58fb64 read
// [esp+0x28]) and pass [esp+0x124] as param_3 at both. So:
//
//  1. [esp+0x124] is Combat_ResolveDamage's own arg0. Its callers -- FUN_005857b0
//     and FUN_00586700 -- pass their actor object there, the one they read
//     param 0x8d off and whose skill state they mutate: the CASTER.
//  2. The same slot is passed as param_3 to Formula_MitigatePhysicalDamage at
//     both of ITS call sites (58f2f8, 58f7e7), always as the last push, i.e.
//     the argument immediately before the damage float -- and inside that
//     function param_3 is `ebp`, the object that receives the out-levelling
//     BONUS (40e6b6) and the Str ratio (40e6cb). Both are the attacker's.
//  3. [esp+0x28] is written once (58e908), from a walk over a container the
//     caller passes as arg1/arg2, each element resolved through FUN_00485d90
//     and then filtered on vtable slots 0x18 and 0x28 before it is damaged:
//     one attacker, many targets.
//
// So param_2 is the TARGET, param_3 the ATTACKER, and the subtraction
// `level(param_2) - level(param_3)` makes the penalty fire when the target
// out-levels the attacker. Applied backwards it would penalise the wrong side,
// which is why nothing was wired until this was proven rather than inferred.
//
// WHERE IT APPLIES. The engine keeps three damage accumulators on the record
// at `ebp` and this result is ADDed into +0x20 (58f522, 58fbd1), while the
// mitigated weapon blow lands in +0x28 (physical) and +0x24 (magical). So the
// term scales the skill's OWN flat damage contribution, not the weapon blow --
// which is srrevamp's `damageBonus`, the half that joins the roll before
// mitigation.
const (
	SkillLevelPenaltyPerLevel     = 0.025
	SkillLevelPenaltyFloorPercent = 10
)

// SkillLevelPenalty scales a skill's own flat damage down when the target
// out-levels the attacker. It returns base unchanged when the attacker is the
// equal or higher level, and never drops below SkillLevelPenaltyFloorPercent of
// base -- so the penalty saturates at 36 levels of deficit, where
// 1 - 0.025*36 is exactly 0.10.
//
// A zero level on either side is "not known", not "level zero", and skips the
// term, the same convention ApplyLevelAdvantage's caller uses.
func SkillLevelPenalty(base, attackerLevel, targetLevel int) int {
	if base <= 0 || attackerLevel <= 0 || targetLevel <= 0 {
		return base
	}
	d := targetLevel - attackerLevel
	if d <= 0 {
		return base
	}
	// math.Trunc, not Round: the engine converts through __ftol2 (0x9fbb40),
	// which is the C cast and truncates toward zero.
	scaled := int(math.Trunc(float64(base) * (1 - SkillLevelPenaltyPerLevel*float64(d))))
	floor := base * SkillLevelPenaltyFloorPercent / 100
	if scaled < floor {
		return floor
	}
	if scaled < base {
		return scaled
	}
	return base
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
//
// **Read 2026-09-19 (round 235), and it moves the goalposts, not the number.**
// The server's per-level table is `CRefDropGold` (`_REFDROPGOLD`, binder
// 0x8312c0, record base 0x30), found by level through
// `CGameServer::LevelGold_FindEntry`, each entry (chance, min, max): the roll
// `GObjPC::FUN_00724330` is `rand()%101 <= chance` then a value in [min, max]
// (`min <= max` asserted). Its readers are exactly: `LevelGold_GetMin` for
// FORMULAS (the skill-withdrawal cost at `Formula_SkillWithdrawGoldCost`, a
// COS cost, a x3 in `FUN_00410370`), and the ROLL in one place only --
// `GObjPC::FUN_009348f0`, which fires when the dying object's type (vtable slot
// 300) is 7 and drops THREE piles of `ITEM_ETC_GOLD_03`, each `roll * 4`,
// skipping ids 10100 and 11000. **No ordinary monster kill rolls this table.**
// A normal kill's gold is one of the monster's assigned drop rows -- the same
// DB-only content as its item drops. So this range is a stand-in twice over:
// levelgold.txt is not the server's table, and the server's table is not the
// ordinary kill's source. It also never gates: the real roll fails
// `100 - chance` percent of the time; here gold drops on every kill. Both are
// disclosed here rather than modelled, because neither number exists outside
// the shard database. The client's levelgold.txt (level, min, max -- no chance
// column; 140 rows, level 1 = 28..59, level 140 = 515..1080) stays the range.
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
	// lastBlow is when each monster last struck: the re-use gate below.
	lastBlow map[int64]time.Time
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{byID: make(map[int64]*Monster), lastBlow: make(map[int64]time.Time)}
}

// CounterattackReady reports whether monster id may strike at now, and when
// it may, records the blow. A monster's blows are at least its attack skill's
// ReuseDelay apart (Monster.AttackReuseMs); a monster with no known delay is
// always ready. srrevamp's monster still strikes only when struck (it has no
// BATTLE loop of its own yet), so this is a ceiling on its cadence, not the
// cadence -- the real one is the skill's re-use delay on its own timer.
func (h *Hub) CounterattackReady(id int64, now time.Time) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	m, ok := h.byID[id]
	if !ok {
		return false
	}
	if m.AttackReuseMs > 0 {
		if last, struck := h.lastBlow[id]; struck && now.Sub(last) < time.Duration(m.AttackReuseMs)*time.Millisecond {
			return false
		}
	}
	h.lastBlow[id] = now
	return true
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
	// RefObjID is the species' numeric characterdata id -- see
	// Monster.RefObjID, which this populates.
	RefObjID int64
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
	// BCRadius is the species' collision radius, characterdata _RefObjChar
	// col 50 (the common record's word at +0xee, IGObj slot 344) -- one of the
	// two radii the attack-distance rule adds to a range (see ApproachBand).
	BCRadius int
	// AttackReuseMs is the ReuseDelay (skilldata column 14) of the species'
	// primary attack skill (characterdata col 83), and AttackRange that
	// skill's Range (column 21, world units). In the real BATTLE state the
	// monster fires that skill through the same action machine a player's
	// cast runs (AITactics_Handler_0e8 -> the tactics' AI-skill Execute), so
	// it cannot strike more often than the skill's re-use delay: Mangyang
	// 3000 ms, Gyo 2000, Yeoha 2500 (read from the retail table 2026-09-19,
	// round 254). Zero means unknown and imposes no cadence.
	AttackReuseMs int
	AttackRange   int
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
	// The engine scales a ranked monster's HP by its rank (champion x2, elite
	// x4, giant x20, titan x100 -- RarityHPPercent, read from CGObjMob::
	// PublishStats); the authored row is the general's figure.
	maxHP = ScaleHPForRarity(maxHP, species.Rarity)
	h.mu.Lock()
	defer h.mu.Unlock()

	id := h.nextID.Add(1)
	m := &Monster{ID: id, Name: species.Name, CodeName: species.CodeName, RefObjID: species.RefObjID, Level: species.Level, Rarity: species.Rarity, BCRadius: species.BCRadius, AttackReuseMs: species.AttackReuseMs, AttackRange: species.AttackRange, Critical: species.Critical, Block: species.Block, Zone: zone, X: x, Y: y, Z: z, MaxHP: maxHP, HP: maxHP, Defense: defense, DefensePercent: species.Level, Attack: attack, AttackMin: species.AttackMin, AttackMax: species.AttackMax,
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
	// Stage 16: the engine's floor band, applied after the level term and
	// before the attacker percentages srrevamp cannot reach. See
	// ApplyFloorBand.
	out.Damage = ApplyFloorBand(out.Damage, base, r)
	return out
}

// FloorBandThreshold, FloorBandScale and FloorBandRandMax are the engine's
// low-end reshaping constants, all three read out of .rdata.
const (
	// FloorBandThreshold is the fraction of the PRE-mitigation base below
	// which a blow is reshaped. `.rdata 0x00b45f60` = 0.05.
	FloorBandThreshold = 0.05
	// FloorBandScale divides the surviving damage. The engine multiplies by
	// `.rdata 0x00b45c60` = 10 and divides by 100, i.e. a tenth.
	FloorBandScale = 10.0
	// FloorBandRandMax is `RAND_MAX`, `.rdata 0x00b45af8` = 32767, the
	// divisor the engine interpolates against.
	FloorBandRandMax = 32767
)

// ApplyFloorBand is stage 16 of Formula_MitigatePhysicalDamage
// (docs/protocol/damage_pipeline.md): a blow that has been mitigated below 5%
// of its pre-mitigation base is NOT simply floored at 1. It is reshaped to a
// tenth of the BASE, floored at 1, and then randomised uniformly between 1 and
// that value:
//
//	40e6eb  if (damage < base * 0.05):
//	40e706      band = base * 10 / 100           // a tenth of the base, NOT of damage
//	40e716      if (band <= 0) band = 1
//	40e729      r = rand()                        // 0x9dd338
//	40e732      damage = 1 + (band - 1) * r / 32767
//
// So a heavily out-geared hit lands for a small RANDOM amount rather than a
// constant 1. This is a different clamp from the floor of 1 that
// Combat_ResolveDamage applies later, which catches a zero; this one reshapes
// the whole low end.
//
// CORRECTED 2026-09-18: the tenth is of `base`, not of `damage`. The asm at
// 40e6f9..40e706 leaves the FPU stack holding the BASE (`[esp+0x28]`, the same
// value the 5% threshold compares against) when it multiplies by 10 and divides
// by 100 -- an fstp st(1) after the compare pops the mitigated damage off and
// leaves the base on top. The earlier reading took it as `damage * 10/100`,
// which is degenerate: in this branch damage is already below 5% of base, so a
// tenth of it is always ~1, i.e. the same constant-1 the doc says this stage
// exists to AVOID. A tenth of the base is a meaningful minimum (1..10% of the
// attacker's attack), which is what "lands for a small RANDOM amount" means.
//
// A nil r takes the maximum outcome, the convention RollDamage and RollChance
// already use, which leaves the tenth undisturbed.
func ApplyFloorBand(damage, base int, r *rand.Rand) int {
	if base <= 0 || float64(damage) >= float64(base)*FloorBandThreshold {
		return damage
	}
	v := float64(base) * FloorBandScale / 100
	if v <= 0 {
		v = 1
	}
	frac := 1.0
	if r != nil {
		frac = float64(r.Intn(FloorBandRandMax+1)) / FloorBandRandMax
	}
	out := int(math.Round(1 + (v-1)*frac))
	if out < 1 {
		out = 1
	}
	return out
}

// MasteryDamageCap is the ceiling on the mastery percentage that scales base
// damage, `cmp al,0x5a` in Combat_ResolveDamage at 0x0058f2c1, 0x0058f2d7,
// 0x0058f97d and 0x0058f993 -- four sites, the same constant.
//
// FOUND BY AUDIT, not by reading. After a decompiler-rendered bound nearly
// shipped as 49 instead of 50 (see guild.MaxHostileGuilds), every unsigned
// bound inside the 161 functions this project cites was re-read in assembly:
// 54 comparisons. Most confirmed a shipped constant -- 13 in
// CGItemEquip::CanBeEquipedAt is equipment.MaxEquipSlots, 3 and 7 in
// HandleSiegeRequest are the fortress-war requirements, 40 in the siege module
// is the -20..+20 tax range biased by 20. These four were the largest thing the
// audit found that nothing claimed.
const MasteryDamageCap = 90

// MasteryDamagePercent is what FUN_0059e770 returns: the character's level in
// the higher of the skill's two required masteries.
//
//	if (ctx == 0 || ctx[0x574] == 0) return 0;
//	a = 1; b = 1;
//	if (ctx[0xa0] != 0) a = masteryLevel(slot1);
//	if (ctx[0xa4] != 0) b = masteryLevel(slot2);
//	return max(a, b);
//
// `masteryLevel` is FUN_0059e750, which resolves the mastery on the character's
// `+0xa30` container and returns the byte at `record[+8] + 0x20` -- the level.
// So it is the CHARACTER's level in that mastery, not the skill's requirement.
//
// The defaults matter: a skill with a mastery slot the character has no level
// in still contributes 1, not 0. Only an attack with no skill record at all
// returns 0.
func MasteryDamagePercent(hasSkill, slot1, slot2 bool, level1, level2 int) int {
	if !hasSkill {
		return 0
	}
	a, b := 1, 1
	if slot1 {
		a = level1
	}
	if slot2 {
		b = level2
	}
	if a < b {
		return b
	}
	return a
}

// ClampMasteryPercent is the call-site clamp, and it is NOT min(pct, 90).
// Combat_ResolveDamage computes the percentage twice, off two different attack
// records, and picks between them:
//
//	0058f2c1  cmp al,0x5a ; mov [esp+0x68],al ; jbe done   ; p1 <= 90 -> p1
//	0058f2cd  mov [esp+0x68],0x5a                          ; else 90
//	0058f2d7  cmp al,0x5a ; jbe done                       ; p2 <= 90 -> keep 90
//	0058f2db  mov [esp+0x68],al                            ; else p2
//
// so: p1 if p1 <= 90, otherwise max(90, p2). A plain `min` would be wrong in
// the one case the engine bothered to write four instructions for -- when BOTH
// exceed 90 the result is p2, which is above the cap.
//
// What the second record is has NOT been identified; it is the object the
// mitigation formula receives as its context, distinct from the one the first
// percentage is read off. Pass secondary equal to primary when there is only
// one, which is what srrevamp does.
func ClampMasteryPercent(primary, secondary int) int {
	if primary <= MasteryDamageCap {
		return primary
	}
	if secondary <= MasteryDamageCap {
		return MasteryDamageCap
	}
	return secondary
}

// MasteryDamageScale is stage 1's multiplier: `1 + pct/100`.
//
// FUN_0040dce0, which docs/protocol/damage_pipeline.md listed as
// `FUN_0040dce0(ctx, defender, damage)` -> base, takes no damage argument at
// all. Its real shape is
//
//	fVar9 = FUN_0040db50(ctx)                    ; the weapon/skill roll
//	fVar1 = (float)param_2 / 100.0 + 1.0         ; param_2 is a PERCENTAGE byte
//	fVar3 = fVar1 * (float)fVar9
//
// so **stage 1 is `roll * (1 + masteryPercent/100)`**, and the byte the caller
// spends four instructions clamping is that percentage. The page described the
// argument as damage; it is mastery.
func MasteryDamageScale(pct int) float64 {
	if pct < 0 {
		pct = 0
	}
	return 1 + float64(pct)/100
}

// ApplyMasteryScale scales a rolled base by MasteryDamageScale, rounding the
// way every other integer step in this package does.
func ApplyMasteryScale(base, pct int) int {
	if base <= 0 {
		return base
	}
	return int(math.Round(float64(base) * MasteryDamageScale(pct)))
}

// MaxDamage is the engine's ceiling on a single blow: **16,777,215**.
//
// RECOVERED 2026-09-20 (round 320), reading the tail of
// `Formula_MitigatePhysicalDamage` (`0x0040e450`) that this project had left
// unread -- docs/protocol/damage_pipeline.md carried "stages past 17 run to
// 40e819 and are not yet read" for as long as the page has existed.
//
// The function ends by comparing the accumulated damage against the double at
// `.rdata 0x00b46110` and, when it is exceeded, replacing it with the float at
// `0x00b46108`. Both hold the same number, 16777215.0 = 2^24 - 1: the largest
// integer a float32 still counts one by one. The result is then converted with
// the rounding mode forced to truncate (`or eax, 0xc00` before `fistp`), so a
// fractional blow loses its fraction rather than rounding up.
//
// `Formula_MitigateMagicalDamage` (`0x0040e830`) carries the same two constants,
// which is the confirmation rather than the finding.
//
// It is unreachable with today's content -- nothing srrevamp spawns can deal
// sixteen million -- and it is here because a ceiling that exists in the engine
// should exist in the reimplementation, cited, rather than being discovered as
// a divergence later.
const MaxDamage = 16777215

// CapDamage applies the engine's ceiling and truncation to a blow.
func CapDamage(damage int) int {
	if damage > MaxDamage {
		return MaxDamage
	}
	return damage
}
