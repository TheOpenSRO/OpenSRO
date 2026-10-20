package jobs

import "time"

// Job PvP's rules (round 802; docs/protocol/jobs.md "Job PvP"). READ in
// SR_GameServer.exe unless a line says otherwise.

// Job states (chardata +0xf, GetJobState): the worn suit's TypeID4, or 4.
const (
	StateTrader byte = 1
	StateThief  byte = 2
	StateHunter byte = 3
	StateNone   byte = 4
)

// The attack refusals (the client's category-4 keys, c:0x7b8b40).
const (
	ErrWrongTarget    uint16 = 0x3006 // UIIT_SKILL_USE_FAIL_WRONGTARGET
	ErrNoBattleField  uint16 = 0x3018 // ITS_NOT_A_BATTLE_FIELD
	ErrPartyMember    uint16 = 0x3022 // CANT_ATTACK_PARTY_MEMBER
	ErrCaravanLevel1  uint16 = 0x3024 // CANT_ATTACK_CARAVAN_LEVEL1
	ErrPKProhibited   uint16 = 0x3025 // PK_PROHIBITED_IN_THIS_SERVER
	ErrYourLevelLow   uint16 = 0x3016 // YOUR_LEVEL_TOO_LOW_TO_PK
	ErrTargetLevelLow uint16 = 0x3017 // TARGET_LEVEL_TOO_LOW_TO_PK
	PKMinLevel               = 20
)

// Opposed is FUN_004eb620 (s:0x4eb620): a trader or a hunter against a
// thief, either way round. Trader against hunter and thief against thief
// are not opposed.
func Opposed(a, b byte) bool {
	ah := a == StateTrader || a == StateHunter
	bh := b == StateTrader || b == StateHunter
	return (ah && b == StateThief) || (a == StateThief && bh)
}

// Fighter is one side of a player-against-player attack as
// CGObjPC::vslot_394 reads it (a COS target is replaced by its owner first).
type Fighter struct {
	Job     byte
	Level   int
	InTown  bool  // the region's IsBattleField byte is 0
	PartyID int64 // 0: none
	// The caravan rule's three tests (s:0x52b760): the transport holds
	// goods, the trader's safe-trade Status, the trade scale.
	TradeGoods bool
	SafeTrade  bool
	TradeScale byte
}

// caravanProtected is s:0x52b760's test on a trader: goods carried, Status
// 1, the scale at most 1.
func (f Fighter) caravanProtected() bool {
	return f.Job == StateTrader && f.TradeGoods && f.SafeTrade && f.TradeScale <= 1
}

// AttackCode is CGObjPC::vslot_394 (s:0x5293a0) with the skill validator's
// context test (s:0x58cc70) for a player attacking a player (or a player's
// COS, own reporting whether the target is the attacker's own COS): 0 when
// the attack may land, else the refusal. area is a secondary target of an
// area skill (flags 1), which never starts a PK: refused with no code
// (returned as ErrWrongTarget's silent twin, 0xFFFF).
//
// OURS, disclosed: OpenSRO has no PvP capes, guild wars or murder states, so
// those branches never apply; a pair that is not job-opposed would be a
// first-strike PK (purple / red murderers, the PK counters), which OpenSRO
// does not model -- it is refused with 0x3025, the code the engine gives
// when its PK-off byte is set (which in the engine also forbids job PvP).
func AttackCode(a, t Fighter, own, area bool) uint16 {
	if own {
		return ErrWrongTarget
	}
	if a.InTown || t.InTown {
		return ErrNoBattleField
	}
	if a.PartyID != 0 && a.PartyID == t.PartyID {
		return ErrPartyMember
	}
	// The caravan rule (s:0x52b760).
	if a.Job == StateThief && t.caravanProtected() {
		return ErrCaravanLevel1
	}
	if t.Job == StateThief && a.caravanProtected() {
		return ErrWrongTarget
	}
	if Opposed(a.Job, t.Job) {
		return 0
	}
	if area {
		return SilentRefusal
	}
	if a.Level < PKMinLevel {
		return ErrYourLevelLow
	}
	if t.Level < PKMinLevel {
		return ErrTargetLevelLow
	}
	// Two players in job mode who are not opposed: the validator's context
	// test refuses an offensive skill 0x3006 (s:0x58d0a8).
	if a.Job != StateNone && a.Job != 0 && t.Job != StateNone && t.Job != 0 {
		return ErrWrongTarget
	}
	return ErrPKProhibited
}

// SilentRefusal is a refusal the engine sends no code for (vslot_394 step 15).
const SilentRefusal uint16 = 0xFFFF

// Monster kinds a job's rules name (characterdata TypeID4 of a 1/2/1 row:
// 2 MOB_THIEF_NPC, 3 MOB_HUNTER_NPC; MEASURED).
const (
	MobNPCThief  = 2
	MobNPCHunter = 3
)

// MonsterAttackCode is vslot_394's monster branch (s:0x52967d): a trader or
// hunter cannot hit an NPC hunter, a thief an NPC thief, a player out of a
// job either.
func MonsterAttackCode(job byte, mobKind int) uint16 {
	switch mobKind {
	case MobNPCHunter:
		if job == StateTrader || job == StateHunter || job == StateNone || job == 0 {
			return ErrWrongTarget
		}
	case MobNPCThief:
		if job == StateThief || job == StateNone || job == 0 {
			return ErrWrongTarget
		}
	}
	return 0
}

// MobMayTarget is CGObjMob::vslot_394's job filter (s:0x529110): an NPC
// hunter hunts thieves only (refused job 1/3/4, s:0x4e59c0), an NPC thief
// never touches thieves or players out of a job (2/4, s:0x4e59e0). A COS is
// judged by its owner's job. Ordinary monsters pass.
func MobMayTarget(mobKind int, job byte) bool {
	switch mobKind {
	case MobNPCHunter:
		return job == StateThief
	case MobNPCThief:
		return job == StateTrader || job == StateHunter
	}
	return true
}

// JobDeathByPlayer is ResolveDeathCause's cause 1 for a player killer
// (s:0x4e6590): the killer wears a job suit and the pair is opposed.
func JobDeathByPlayer(killerSuit bool, killerJob, victimJob byte) bool {
	return killerSuit && Opposed(killerJob, victimJob)
}

// JobDeathByMonster is cause 1 for an NPC killer: a trader or hunter killed
// by an NPC thief, any job killed by an NPC hunter.
func JobDeathByMonster(victimJob byte, mobKind int) bool {
	switch mobKind {
	case MobNPCThief:
		return victimJob == StateTrader || victimJob == StateHunter
	case MobNPCHunter:
		return victimJob == StateTrader || victimJob == StateThief || victimJob == StateHunter
	}
	return false
}

// JobDeathExpLoss is the cause-1 handler's character exp loss
// (s:0x4e6820): 6 x leveldata's exp unit (column 6) at min(victim, killer)
// level, less the premium reduction trunc(param 0x101 / 100.0 x base) when
// it is positive. OpenSRO has no premium: reductionPct 0.
func JobDeathExpLoss(expUnit int64, reductionPct int) int64 {
	base := 6 * expUnit
	red := int64(float64(reductionPct) / 100.0 * float64(base))
	if red > 0 {
		return base - red
	}
	return base
}

// JobKillCharExp is the kill credit's character exp for a player victim
// (s:0x4e1f60): 3 x the exp unit at min(killer, victim) level.
func JobKillCharExp(expUnit int64) int64 { return 3 * expUnit }

// PartyJobShare is s:0x5bd7f0's share for one eligible member:
// ftol(jobExp x level / sumLevels x (1 + 0.05 x (n - 1))), jobExp that
// member's own KillExp.
func PartyJobShare(jobExp int64, level, sumLevels, n int) int64 {
	if sumLevels <= 0 || n <= 0 {
		return 0
	}
	return int64(float64(jobExp) * float64(level) / float64(sumLevels) * (1 + 0.05*float64(n-1)))
}

// SafeTrade is the trader's _CharTrijobSafeTrade row (round 802):
// AbleCount, Status, LastSafeTrade.
type SafeTrade struct {
	Count  int
	Status bool
	Last   time.Time
}

// Safe-trade options (TRADE_SAFETY_OPTION): 0 counted per day, 1 never, 2
// always.
const (
	SafeTradeCounted = 0
	SafeTradeNever   = 1
	SafeTradeAlways  = 2
)

// The 0x34D5 codes (s:0x51a960): 0x50 granted, 0x41 the day's limit, 0x40
// not eligible (or lost), 0x51 the login's report.
const (
	SafeGranted byte = 0x50
	SafeLimit   byte = 0x41
	SafeLost    byte = 0x40
	SafeAtLogin byte = 0x51
)

// DailyReset is s:0x60e690: with the counted option, a talk on a new
// server-local calendar day resets the count and stamps today 00:00. It
// reports a change.
func (s *SafeTrade) DailyReset(now time.Time, option int) bool {
	if option != SafeTradeCounted {
		return false
	}
	y, m, d := now.Date()
	ly, lm, ld := s.Last.Date()
	if !s.Last.IsZero() && y == ly && m == lm && d == ld {
		return false
	}
	s.Count = 0
	s.Last = time.Date(y, m, d, 0, 0, 0, 0, now.Location())
	return true
}

// Decide is s:0x60e890, run when a trader closes a specialty trader's
// dialog: special goods (3/3/8/2) in a transport or a scale other than 1
// make him ineligible; the counted option grants while the count is below
// num (a grant while already safe does not count again), the always option
// grants. It sets Status and returns the 0x34D5 code.
func (s *SafeTrade) Decide(specialGoods bool, scale byte, option, num int) byte {
	if specialGoods || scale != 1 {
		s.Status = false
		return SafeLost
	}
	switch option {
	case SafeTradeAlways:
		s.Status = true
		return SafeGranted
	case SafeTradeCounted:
		if num > s.Count {
			if !s.Status {
				s.Count++
				if s.Count > num {
					s.Count = num
				}
			}
			s.Status = true
			return SafeGranted
		}
		s.Status = false
		return SafeLimit
	}
	s.Status = false
	return SafeLost
}
