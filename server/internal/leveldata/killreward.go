package leveldata

// The kill reward as the monster's death distributor pays it (round 712, party
// lane S2). docs/protocol/party_rules.md "Kill EXP and SP" has the whole read;
// this file is its arithmetic, one function per engine function, each step at
// the precision the engine keeps it.
//
// The pipeline (READ, SR_GameServer.exe):
//
//	CGObjMob::vslot_399 (0x4c44a0)   groups the damage list, picks the kill credit
//	  -> FUN_004c4820                 an individual award (no party, or Exp Free-For-All)
//	  -> GObjPC::FUN_005bca60         the party share (Exp Auto Share)
//	     both -> CGObjPC::vslot_420   (0x4ea6a0) EXP/SP x multiplier, the rate bonus,
//	                                   then GainExpAndLevel (slot 92)
//
// The per-receiver EXP and SP before the multiplier are
// Formula_ExpRewardForContributor (0x410110) and Formulae::FUN_004106b0
// (0x4106b0); ContributorExp and ContributorSP below.

// ContributorShareFloor is the low clamp on a contributor's damage share: the
// float at 0xb45c84 (`fld DWORD`), 1e-6. The high clamp is fld1, 1.0 (READ,
// 0x41024a-0x41027a).
const ContributorShareFloor float32 = 9.999999974752427e-07

// ContributorShare is a receiver's share of the victim: damage over the
// victim's maximum HP, both converted to float32 and clamped to [1e-6, 1]
// (READ, 0x41014b-0x4101d2 and 0x41021e-0x41027a: `fild` the MaxHP from slot
// 68, `fstp DWORD`; the damage arrives as a float argument; `fdiv DWORD`).
// A victim with no HP pays nothing (the engine asserts and stores 0).
func ContributorShare(damage, maxHP int) float32 {
	if maxHP <= 0 || damage <= 0 {
		return 0
	}
	s := float32(damage) / float32(maxHP)
	if s < ContributorShareFloor {
		s = ContributorShareFloor
	}
	if s > 1 {
		s = 1
	}
	return s
}

// The monster's EXP/SP multiplier, CGObjMob::vslot_359 (0x4c15c0). READ (asm;
// party_rules.md "The two formulas"): 1.0, 7.5 for a party monster (`fld DWORD
// 0xb45b9c` = 7.5), then times the rank's factor; a rank outside the table
// returns a bare 1.0, the party factor dropped.
const (
	MonsterExpPartyFactor = 7.5  // 0xb45b9c, float
	MonsterExpChampion    = 2.0  // `fadd st,st`
	MonsterExpGiant       = 15.0 // 0xb45e88, double
	MonsterExpRank5       = 60.0 // 0xb45e80, double
	MonsterExpElite       = 4.0  // 0xb45cf0, double
	MonsterExpRank7       = 30.0 // 0xb45e58, double
)

// MonsterExpFactor is vslot_359 for a monster of this rank (the class byte's low
// nibble, combat.Monster.Rarity) and party flag.
func MonsterExpFactor(partyMonster bool, rank int) float64 {
	f := 1.0
	if partyMonster {
		f = MonsterExpPartyFactor
	}
	switch rank {
	case 0, 3, 8:
		return f
	case 1:
		return f * MonsterExpChampion
	case 4:
		return f * MonsterExpGiant
	case 5:
		return f * MonsterExpRank5
	case 6:
		return f * MonsterExpElite
	case 7:
		return f * MonsterExpRank7
	}
	return 1.0
}

// MasterySPScale is the mirror of MasteryExpScale the engine writes beside it,
// pc+0x1cdc, which the kill's SKILL experience is multiplied by: `1 - (ref -
// charLevel) * 0.1`, CLAMPED to [0.1f, 1.9f] like its twin, and 1.0 when the
// reference exceeds 120 (READ, GObjPC_RecalcLevelDiffExpScale 0x4e30d0: the
// unclamped value is stored at 0x4e3151 and then overwritten by the clamp at
// 0x4e31af-0x4e31e9 -- floor 0x1cdc = 0.1f when it is 0.1 or less, cap 1.9f
// when it reaches the double 1.8999999761 at 0xb45f10; FUN_004106b0 loads it
// at 0x41076f). The reference is the highest mastery level, capped at the
// character's level, so a lagging mastery earns MORE skill experience, up to
// x1.9. (Round 712's first build left it unclamped; its review read the clamp.)
func MasterySPScale(charLevel, maxMasteryLevel int) float64 {
	if maxMasteryLevel > MasteryExpRefCap {
		return 1.0
	}
	scale := 1.0 - float64(maxMasteryLevel-charLevel)*MasteryExpPenaltyPerLevel
	if scale < MasteryExpScaleMin {
		return MasteryExpScaleMin
	}
	if scale > MasteryExpScaleMax {
		return MasteryExpScaleMax
	}
	return scale
}

// ExpWindowScale32 is ExpWindowScale at the engine's precision
// (Formula_ExpScaleByLevelWindow 0x40fed0, READ): the step is stored to a
// float32 before the `1 -` (0x40ff4b, 0x40ff80) and the difference stored
// again (0x40ff8c); 0.9f flat four to six levels down (0xb45ddc); floor 0.1f
// below the double 0.1 (0x40ff94-0x40ffad), 1.0 at 1.0 or above. The kill
// formulas use it; ExpWindowScale keeps its float64 callers.
func ExpWindowScale32(receiverLevel, victimLevel int) float32 {
	gap := victimLevel - receiverLevel
	v := float32(1)
	switch {
	case gap >= 11:
		t := float32(float64(gap-10) * ExpWindowFarAbovePerLevel)
		v = float32(1 - float64(t))
	case gap <= -4:
		if gap > -7 {
			v = float32(ExpWindowNearBelow)
		} else {
			t := float32(float64(-gap-3) * ExpWindowFarBelowPerLevel)
			v = float32(1 - float64(t))
		}
	}
	if float64(v) < ExpWindowScaleFloor {
		return float32(ExpWindowScaleFloor)
	}
	if v >= 1 {
		return 1
	}
	return v
}

// ExpDiffScale32 is ExpDiffScale at the engine's precision
// (Formula_ExpScaleByLevelDiff 0x40ffe0, READ): the party gap bonus is a
// float32 constant, `bonus + 1.0` is stored to a float32 (0x41009a) before
// `steps * 0.03` is added and the sum stored again (0x4100cc); clamped to
// [1, 4] (0x4100d0-0x410100).
func ExpDiffScale32(receiverLevel, victimLevel int, expSharingParty, europe bool) float32 {
	var bonus float32
	if expSharingParty {
		bonus = float32(ExpDiffPartyBonus(receiverLevel, victimLevel, europe))
	}
	b := float32(float64(bonus) + 1.0)
	if victimLevel+3 <= receiverLevel {
		return 1
	}
	steps := victimLevel - receiverLevel + 3
	if steps > ExpDiffScaleMaxSteps {
		steps = ExpDiffScaleMaxSteps
	}
	v := float32(float64(steps)*ExpDiffScalePerStep + float64(b))
	if v < 1 {
		return 1
	}
	if v >= float32(ExpDiffScaleCap) {
		return float32(ExpDiffScaleCap)
	}
	return v
}

// RewardInput is what the two contributor formulas read for one receiver.
type RewardInput struct {
	// Base is slot 332 of the victim, the monster's base EXP: its
	// characterdata col 79, ExpToGive, the same for every receiver (READ,
	// round 712's review: CGObjMob slot 332 0x4a68b0 jumps to the instance's
	// slot 13, 0x449340, which returns the reference row's +0x250). Without
	// the column the caller passes Table.KillBase (OURS fallback).
	Base int64
	// MonsterFactor is vslot_359 (MonsterExpFactor).
	MonsterFactor float64
	// Share is ContributorShare of the damage the award is for.
	Share float32
	// ReceiverLevel and VictimLevel feed the two level scalers, evaluated for
	// the receiver (ESI/EDI at 0x41022a, 0x410241).
	ReceiverLevel, VictimLevel int
	// ExpShareParty is ExpDiffScale's party gate for the receiver (its party
	// has bit 0), Europe its Country selector.
	ExpShareParty, Europe bool
	// ExpLag and SPLag are the receiver's pc+0x1cd8 and pc+0x1cdc
	// (MasteryExpScale, MasterySPScale).
	ExpLag, SPLag float64
	// ExpUnitReceiver is the receiver's level row +0x1c, leveldata column 5
	// (Table.ExpUnit at ReceiverLevel), which divides the SP.
	ExpUnitReceiver int64
}

// u32AsFloat is how the engine loads slot 332's int: `fild DWORD`, plus 2^32
// when it is negative (`jge; fadd DWORD 0xb45ba4`), so the int is unsigned.
func u32AsFloat(v int64) float64 {
	return float64(uint32(v))
}

// ContributorExp is Formula_ExpRewardForContributor (0x410110), READ from the
// asm 0x4101e6-0x410366:
//
//	base  = float32(u32(slot332) * slot359)
//	EXP   = ftol(base * share * Window * pc[0x1cd8] * Diff)   ; each factor a float32
//	EXP   = 1 when it comes to 0 or less
//
// ftol truncates (0x9fbb76, the int64 __ftol2).
func ContributorExp(in RewardInput) int64 {
	if in.Share <= 0 {
		return 0
	}
	base := float32(u32AsFloat(in.Base) * in.MonsterFactor)
	window := ExpWindowScale32(in.ReceiverLevel, in.VictimLevel)
	lag := float32(in.ExpLag)
	diff := ExpDiffScale32(in.ReceiverLevel, in.VictimLevel, in.ExpShareParty, in.Europe)
	v := float64(base) * float64(in.Share) * float64(window) * float64(lag) * float64(diff)
	out := int64(v)
	if out <= 0 {
		return 1
	}
	return out
}

// SPPerExpUnit is the 100.0 FUN_004106b0 multiplies by before it divides by the
// receiver's EXP unit (`fmul QWORD 0xb45af0`, a double; READ).
const SPPerExpUnit = 100.0

// ContributorSP is the kill's skill experience, Formulae::FUN_004106b0
// (0x4106b0), READ from the asm 0x4107b8-0x410872:
//
//	SP = base * 100.0 / expUnit(receiver) * share * Window * pc[0x1cdc] * Diff
//	SP = 1 when it is below 1.0; ftol (int32, 0x9fbb40) otherwise
//
// base is the same slot332 * slot359 product ContributorExp starts from.
func ContributorSP(in RewardInput) int64 {
	if in.Share <= 0 || in.ExpUnitReceiver <= 0 {
		return 0
	}
	base := u32AsFloat(in.Base) * in.MonsterFactor * SPPerExpUnit / u32AsFloat(in.ExpUnitReceiver)
	window := ExpWindowScale32(in.ReceiverLevel, in.VictimLevel)
	lag := float32(in.SPLag)
	diff := ExpDiffScale32(in.ReceiverLevel, in.VictimLevel, in.ExpShareParty, in.Europe)
	// The product is stored to a float32 (`fstp DWORD [esp+0x24]`,
	// 0x41083e) before the floor and the ftol.
	v := float32(base * float64(in.Share) * float64(window) * float64(lag) * float64(diff))
	if v < 1 {
		return 1
	}
	return int64(int32(v))
}

// KillBase is the FALLBACK base for a monster whose reference data has no
// col 79 (a monsters CSV exported before round 712): the level table's EXP
// unit at the lower of the receiver's and the victim's levels, what KillExp
// always paid. OURS: the engine's base is the victim's ExpToGive
// (RewardInput.Base), which for an ordinary monster equals this unit at its
// OWN level (MEASURED, 95.3 % of MOB rows) -- so the fallback agrees with the
// engine for a receiver at or above the monster's level and underpays one
// below it. The min-level rule itself is Formula_MonsterExpReward's
// (0x4105d0), which needs both sides to be PCs (0x4105d9/0x4105e8): the PvP
// formula.
func (t *Table) KillBase(receiverLevel, victimLevel int) (int64, bool) {
	lvl := receiverLevel
	if victimLevel < lvl {
		lvl = victimLevel
	}
	return t.ExpUnit(lvl)
}

// ApplyRewardMultiplier is vslot_420's first step (READ, 0x4ea7d9-0x4ea88b):
// EXP and SP are each stored to a float32, multiplied by the award's
// multiplier -- itself a float32 argument (`fld DWORD [ebp+0x10]`, 0x4ea863)
// -- and truncated (ftol).
func ApplyRewardMultiplier(exp, sp int64, multiplier float32) (int64, int64) {
	m := float64(multiplier)
	e := int64(float64(float32(exp)) * m)
	s := int64(float64(float32(sp)) * m)
	return e, s
}

// RateBonusFloor is the 1.01 below which the server's EXP rate pays nothing at
// all (`fld DWORD 0xb46178`, a float; READ 0x4ea892-0x4ea8e3).
const RateBonusFloor float32 = 1.0099999904632568

// ApplyRateBonus is vslot_420's rate step (READ, 0x4ea892-0x4ea8e3): r is
// ExpRatioParty for a receiver in any party, ExpRatio otherwise (the caller
// picks); at r >= 1.01 it ADDS ftol(EXP*(r-1)) to the EXP and ftol(SP*(r-1))
// to the SP; below 1.01 nothing changes, so a rate under 1 lowers nothing.
func ApplyRateBonus(exp, sp int64, r float64) (int64, int64) {
	rf := float32(r)
	if rf < RateBonusFloor {
		return exp, sp
	}
	k := float64(rf) - 1
	return exp + int64(float64(exp)*k), sp + int64(float64(sp)*k)
}

// FreeForAllMultiplier is FUN_004c4820's multiplier for one contributor not in
// an exp-share group (READ, 0x4c4820-0x4c48c8): 1.0, or 1 + (members-1)*0.03
// in a party (members = party+0x1c, every member wherever he is), halved when
// the victim is a party monster below the receiver's level (FUN_00410fd0,
// 0.5 at 0xb45b68). The multiplier is a float32 (vslot_420's argument).
func FreeForAllMultiplier(partyMembers int, partyMonsterBelowReceiver bool) float32 {
	m := float32(1)
	if partyMembers > 0 {
		m = float32(PartyExpBonus(partyMembers))
	}
	if partyMonsterBelowReceiver {
		m *= PartyMonsterHalf
	}
	return m
}

// PartyMonsterHalf is the 0.5 a party monster's reward takes when its killers
// out-level it (0xb45b68 in FUN_00410fd0, a float; the party share's 0.5 at
// 0x5bcda0-0x5bce06). READ.
const PartyMonsterHalf = 0.5

// The party share's constants (GObjPC::FUN_005bca60, READ, all doubles):
const (
	PartyShareChinaPerMember  = 0.1  // 0xb45ec0
	PartyShareEuropePerMember = 0.2  // 0xb45ee8
	PartyShareDampThreshold   = 0.7  // 0xb46050
	PartyShareDampMinMembers  = 3    // eligibleCount >= 3
	PartyShareDampMinTopLevel = 21   // maxLevel >= 0x15
	PartyShareDampFactor      = 0.5  // 0xb45c50
	PartyShareRange           = 1000 // 0xb45c68, horizontal, inclusive
)

// PartyShareBonus is FUN_005bca60's bonus (READ, 0x5bcd38-0x5bcd9c), from the
// eligible members' Countries: chinese with Country 0, others with any other.
//
//	others > 0:   f32((1 + (others-1)*0.2) + f32(chinese*0.1))   ; 0x5bcd62, 0x5bcd6a
//	chinese > 0:  f32(1 + (chinese-1)*0.1)                       ; 0x5bcd98
//	else:         1
func PartyShareBonus(chinese, others int) float32 {
	switch {
	case others > 0:
		c := float32(float64(chinese) * PartyShareChinaPerMember)
		return float32(1 + float64(others-1)*PartyShareEuropePerMember + float64(c))
	case chinese > 0:
		return float32(1 + float64(chinese-1)*PartyShareChinaPerMember)
	}
	return 1
}

// PartySharePenalty is FUN_005bca60's party-monster penalty (READ,
// 0x5bcda0-0x5bce06): 0.5 when the victim is a party monster whose level is
// below the eligible members' average (Σlevel / count, integer division),
// else 1 -- a float32 (0x5bce06).
func PartySharePenalty(partyMonster bool, victimLevel int, levels []int) float32 {
	if !partyMonster || len(levels) == 0 {
		return 1
	}
	sum := 0
	for _, l := range levels {
		sum += l
	}
	if victimLevel < sum/len(levels) {
		return PartyMonsterHalf
	}
	return 1
}

// PartyShareMultipliers is FUN_005bca60's split (READ, 0x5bce20-0x5bcee4): for
// eligible member i, s_i = f32(level_i / Σlevel) (0x5bce5f), and the bonus --
// a float32 -- is damped to f32((bonus-1)*0.5+1) (0x5bcea3) for a member whose
// s_i exceeds 0.7 in a party of three or more eligible whose top level is 21
// or more. The award's multiplier is f32(s_i * b_i * penalty) (0x5bcec8), and
// every member's award is for the WHOLE group's damage.
func PartyShareMultipliers(levels []int, bonus, penalty float32) []float32 {
	out := make([]float32, len(levels))
	sum, top := 0, 0
	for _, l := range levels {
		sum += l
		if l > top {
			top = l
		}
	}
	if sum <= 0 {
		return out
	}
	for i, l := range levels {
		s := float32(float64(l) / float64(sum))
		b := bonus
		if float64(s) > PartyShareDampThreshold && len(levels) >= PartyShareDampMinMembers && top >= PartyShareDampMinTopLevel {
			b = float32((float64(bonus)-1)*PartyShareDampFactor + 1)
		}
		out[i] = float32(float64(s) * float64(b) * float64(penalty))
	}
	return out
}
