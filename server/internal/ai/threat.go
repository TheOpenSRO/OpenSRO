package ai

// The attacker accounting -- who a monster fights when more than one thing
// hits it. Read off AITactics_CreditAttacker (0x5473c0, behaviour +0xec),
// AITactics_ResolveTarget (0x545680), AITactics_Handler_0fc (0x548090) and
// AI::CAISkill_Basic::ArmNextAttack (0x5619e0) on 2026-09-19, round 259
// (docs/protocol/monster_ai.md "The threat table").
//
// A monster keeps exactly TWO attackers: its TARGET (ctx+0xbc..+0xcc) and one
// CHALLENGER (ctx+0xd0..+0xe0), each {id, damage, hate, hits, lastHitTick},
// plus the total damage it has taken (ctx+0xb0). A third attacker is not
// tracked at all. Every blow arrives as a record {attacker, damage, hate,
// hatePercent} and is credited as
//
//	slot.damage += damage
//	slot.hate    = clamp(slot.hate + slot.hate*hatePercent/100 + hate, 0, INT_MAX)
//	slot.hits++ ; slot.lastHit = now
//
// with a code saying which slot took it: 0 the target, 1 the challenger
// (empty or already this attacker), 2 nobody. A target whose hate is below
// 1 after the credit is DROPPED (the credit returns 1, BATTLE goes to IDLE).
//
// Which attacker the monster then faces is the tactics row's RETARGET RULE
// (`_RefTactics+0x20`, column 9), applied while in BATTLE by Handler_0fc:
//
//	0  keep the first attacker
//	1  always face the latest attacker
//	2  by hate: a challenger takes over when its hate exceeds the target's, or
//	   when the target has not hit for two attack intervals; a third attacker
//	   (code 2) takes over only when it stands FARTHER than the target
//	   (fcomp at 0x545720: keep when d_candidate <= d_target); an invalid
//	   target is replaced by the challenger outright
//
// The attack interval the idle test doubles is the selector's +0x48:
// ReuseDelay + rand % (J + 1), J = clamp(previous interval / 5, 500, 2000) ms.

// Retarget rules, the tactics row's column 9.
const (
	RetargetKeepFirst = 0
	RetargetLatest    = 1
	RetargetByHate    = 2
)

// Credit codes: which slot a blow landed in.
const (
	CreditTarget     = 0
	CreditChallenger = 1
	CreditUntracked  = 2
)

// ThreatIdleIntervals is how many attack intervals a target may go without
// hitting before a challenger overtakes it under RetargetByHate (2 x the
// selector's +0x48, 0x5456xx `iVar2 * 2`).
const ThreatIdleIntervals = 2

// The attack interval's jitter: ArmNextAttack adds rand % (J + 1) ms to the
// skill's ReuseDelay, J being a fifth of the previous interval clamped to
// [500, 2000].
const (
	AttackJitterDivisor = 5
	AttackJitterMinMs   = 500
	AttackJitterMaxMs   = 2000
)

// AttackJitterMs is J for a previous interval.
func AttackJitterMs(previousIntervalMs int) int {
	j := previousIntervalMs / AttackJitterDivisor
	if j < AttackJitterMinMs {
		return AttackJitterMinMs
	}
	if j > AttackJitterMaxMs {
		return AttackJitterMaxMs
	}
	return j
}

// AttackIntervalRange is the [min, max] a monster's next attack interval can
// take: ReuseDelay plus 0..J.
func AttackIntervalRange(reuseDelayMs, previousIntervalMs int) (min, max int) {
	return reuseDelayMs, reuseDelayMs + AttackJitterMs(previousIntervalMs)
}

// ThreatSlot is one tracked attacker.
type ThreatSlot struct {
	ID      int64
	Damage  int
	Hate    int
	Hits    int
	LastHit int64 // the tick the slot was last credited, in the caller's unit
}

func (s ThreatSlot) empty() bool { return s.ID == 0 }

// ThreatTable is a monster's two-slot attacker accounting.
type ThreatTable struct {
	Target      ThreatSlot
	Challenger  ThreatSlot
	TotalDamage int
}

// Credit books one blow. It returns the slot code and whether the target
// must be dropped (its hate fell below 1) -- the engine's `return 1`.
func (t *ThreatTable) Credit(attacker int64, damage, hate, hatePercent int, now int64) (code int, drop bool) {
	t.TotalDamage += damage
	var slot *ThreatSlot
	switch {
	case t.Target.empty() || t.Target.ID == attacker:
		code, slot = CreditTarget, &t.Target
	case t.Challenger.empty() || t.Challenger.ID == attacker:
		code, slot = CreditChallenger, &t.Challenger
	default:
		return CreditUntracked, false
	}
	slot.Hits++
	slot.ID = attacker
	slot.Damage += damage
	h := slot.Hate + (hatePercent*slot.Hate)/100 + hate
	if h < 0 {
		h = 0
	} else if h > 0x7ffffffe {
		h = 0x7fffffff
	}
	slot.Hate = h
	slot.LastHit = now
	return code, code == CreditTarget && h < 1
}

// Clear forgets both attackers (SetTarget(0) / the leave paths).
func (t *ThreatTable) Clear() { *t = ThreatTable{} }

// Face is the engine's SetTarget(id): the target slot's id and last-hit
// tick change, and NOTHING else -- the damage, hate and hit count already in
// the seat stay with it. Rule 1 does this on every new attacker, so the seat's
// history carries over to whoever sits in it; that is the engine's, kept.
func (t *ThreatTable) Face(attacker int64, now int64) {
	t.Target.ID = attacker
	t.Target.LastHit = now
}

// replaceTarget is the untracked-attacker takeover (0x5456d9..0x5456f6): the
// seat is zeroed and the newcomer starts at one hit.
func (t *ThreatTable) replaceTarget(attacker int64, now int64) {
	t.Target = ThreatSlot{ID: attacker, Hits: 1, LastHit: now}
}

// Resolve applies retarget rule 2 after a blow with the given credit code
// and returns the id the monster should face. targetValid is whether the
// current target still exists and can be attacked; candidateDist and
// targetDist are the monster's distances to the new attacker and to its
// target (used only for an untracked attacker); intervalMs is the current
// attack interval.
func (t *ThreatTable) Resolve(code int, attacker int64, targetValid bool, candidateDist, targetDist float64, now int64, intervalMs int) int64 {
	switch code {
	case CreditTarget:
		return t.Target.ID
	case CreditChallenger:
		if !targetValid {
			// Promote the challenger into the empty seat.
			t.Target, t.Challenger = t.Challenger, ThreatSlot{}
			return t.Target.ID
		}
		if t.Target.Hate < t.Challenger.Hate || now-t.Target.LastHit >= int64(ThreatIdleIntervals*intervalMs) {
			t.Target, t.Challenger = t.Challenger, t.Target
		}
		return t.Target.ID
	default:
		if !targetValid {
			t.replaceTarget(attacker, now)
			return attacker
		}
		if candidateDist <= targetDist {
			return t.Target.ID
		}
		// A farther third attacker takes the seat; the old target becomes
		// the challenger (0x545550 moves the slot down).
		t.Challenger = t.Target
		t.replaceTarget(attacker, now)
		return attacker
	}
}

// FaceAfterHit is the whole in-BATTLE rule: which attacker the monster faces
// after a blow, by the tactics row's retarget rule. Rule 0 never moves, rule
// 1 follows the latest attacker, rule 2 is Resolve.
func (t *ThreatTable) FaceAfterHit(rule, code int, attacker int64, targetValid bool, candidateDist, targetDist float64, now int64, intervalMs int) int64 {
	switch rule {
	case RetargetLatest:
		if t.Target.ID != attacker {
			t.Face(attacker, now)
		}
		return attacker
	case RetargetByHate:
		return t.Resolve(code, attacker, targetValid, candidateDist, targetDist, now, intervalMs)
	}
	return t.Target.ID
}

// The skill choice, read off AI::CAISkill_Basic::PickSkill (0x561b00) and its
// trigger evaluators (0x5611d0, 0x561210), round 260 (docs/protocol/
// monster_ai.md "The skill choice"). Triggers -- skills bound to the tactics
// row by a _RefAISkill row -- are checked first; otherwise one attack skill
// is drawn at random in proportion to its weight.

// AISkill trigger types, _RefAISkill column 3.
const (
	TriggerHPBelow  = 0 // once, when HP % <= column 4
	TriggerPeriodic = 1 // every column-4 ms; column 5 bit 0 fires at once the first time
)

// SkillWeight is an attack skill's share of the draw: its AI_AttackChance
// (skilldata column 66) plus, when the target is inside the skill's reach,
// the margin in whole units (skill Range + both BCRadius - distance, ftol'd).
// A skill with AI_AttackChance 0 is never drawn.
func SkillWeight(attackChance, skillRange, ownerBC, targetBC int, distance float64) int {
	if attackChance == 0 {
		return 0
	}
	w := attackChance
	if margin := float64(skillRange+ownerBC+targetBC) - distance; margin > 0 {
		w += int(margin)
	}
	return w
}

// TriggerHPBelowHolds is trigger type 0: the owner's HP percentage
// (CurHP*100/MaxHP, as the engine computes it in floats) at or below the
// row's threshold. The caller disables the entry once it fires.
func TriggerHPBelowHolds(curHP, maxHP, threshold int) bool {
	if maxHP <= 0 {
		return false
	}
	pct := float32(curHP) * 100 / float32(maxHP)
	return float32(threshold) >= pct
}
