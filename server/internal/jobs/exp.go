package jobs

// MaxLevel is the job level's cap: FUN_0060dd90 levels up only while the
// level is below 7 (s:0x60de69 `cmp bx,7; jge`), and the exp past it keeps
// growing with no cap (READ: no clamp on that path).
const MaxLevel = 7

// MaxContribution is TrijobMgr::FUN_0060e0a0's clamp (s:0x60e0a0, the CLAMP
// assert's 2,000,000,000).
const MaxContribution = 2000000000

// NeedFunc is the job exp a level needs to level up: leveldata's job column
// for kind at level (READ FUN_0060dd90: the level record of row level-1,
// +0x20 trader, +0x24 robber, +0x28 hunter -- leveldata.txt columns 6, 7, 8).
// ok is false when the table has no such row: no level-up then.
type NeedFunc func(level int, kind Kind) (need uint32, ok bool)

// GainExp is GObjPC::FUN_004e2830 -> FUN_0060dd90 (READ s:0x4e2830,
// s:0x60dd90): a job exp change of amount on r. It reports whether the record
// changed and 0x30E6 goes out (FUN_004e2830 sends it whenever FUN_0060dd90
// answers non-zero).
//
//   - amount 0: nothing.
//   - A positive amount is first multiplied by the player's float +0x2280
//     (zero: nothing). OURS: that factor (written by s:0x4dee90 from a play
//     time test, INFERRED the play-time fatigue) is 1.0 here.
//   - A robber's or hunter's contribution moves with every change, both ways,
//     clamped to [0, 2e9] (TrijobMgr::FUN_0060e0a0); a trader's comes from
//     sales instead (AddTraderContribution).
//   - A loss with exp 0 changes nothing (and sends nothing); otherwise exp
//     falls to at least 0. The level never goes down.
//   - A gain while level < 7 that brings exp + amount to the need (an
//     unsigned compare: a need of -1 is never reached) levels up once, exp =
//     exp + amount - need; otherwise exp += amount.
func GainExp(r *Record, amount int64, need NeedFunc) bool {
	if amount == 0 || !r.Kind.Valid() {
		return false
	}
	if r.Kind != KindTrader {
		r.Contribution = clampContribution(r.Contribution + amount)
	}
	if amount < 0 {
		if r.Exp == 0 {
			return false
		}
		r.Exp += amount
		if r.Exp < 0 {
			r.Exp = 0
		}
		return true
	}
	sum := r.Exp + amount
	if r.Level < MaxLevel && need != nil {
		if n, ok := need(r.Level, r.Kind); ok && sum >= 0 && uint64(sum) >= uint64(n) {
			r.Level++
			r.Exp = sum - int64(n)
			return true
		}
	}
	r.Exp = sum
	return true
}

// AddTraderContribution is a trader's specialty sale: contribution +=
// trunc(gold x 0.1) (FUN_006194e0 s:0x6194e0, 0.1 at s:0xb462f8), clamped as
// every contribution change is.
func AddTraderContribution(r *Record, saleShare int64) {
	if r.Kind == KindTrader {
		r.Contribution = clampContribution(r.Contribution + saleShare)
	}
}

// SaleShare is trunc(gold x 0.1): the trader's contribution and the reward
// pool's share of a sale (READ, the same value goes to _AddTrijobReward).
func SaleShare(gold int64) int64 { return int64(float64(gold) * 0.1) }

func clampContribution(v int64) int64 {
	if v < 0 {
		return 0
	}
	if v > MaxContribution {
		return MaxContribution
	}
	return v
}

// RewardPool is _AddTrijobReward's first argument for a sale by kind (READ
// AQ_Trijob type 3, s:0x465220): a trader's sale feeds pool 3 (the hunters',
// "Trader Contributed to hunter guild"), a robber's pool 2 (the robbers').
// ok is false for any other kind (retail asserts).
func RewardPool(k Kind) (Kind, bool) {
	switch k {
	case KindTrader:
		return KindHunter, true
	case KindThief:
		return KindThief, true
	}
	return 0, false
}

// Unit is the job formulas' level unit: trunc(LevelGold_GetMin(level) x 10 x
// 0.125) -- the int x10 (`lea eax,[eax+eax*4]; add eax,eax`), then fild and
// fmul by 0.125 (s:0xb45fa8) and a truncation (_ftol2, s:0x9fbb40). READ in
// FUN_00410370 (the job death's loss), FUN_004103e0 (a job kill's exp), the
// trade scale and the transport's bag.
func Unit(levelGoldMin int64) int64 {
	return int64(float64(int32(levelGoldMin*10)) * 0.125)
}

// DeathLoss is FUN_00410370: the job exp a job death costs, 3 x Unit at the
// victim's level (READ s:0x4103cd `lea eax,[eax+eax*2]`).
func DeathLoss(victimGoldMin int64) int64 { return 3 * Unit(victimGoldMin) }

// KillExp is FUN_004103e0 (READ s:0x4103e0..0x410511): a job kill's exp for
// the killer.
//
//	a = Unit(victim level), b = Unit(killer level)
//	r = clamp(a / b, 0.5, 1.5)          (float32; 0.5 at 0xb45b68, 1.5 at 0xb45c10)
//	v = a x r, x 0.5 when the killer is a trader (0xb45c50)
//	v <= 0 -> 1; the result is truncated
func KillExp(victimGoldMin, killerGoldMin int64, killerTrader bool) int64 {
	a := float32(Unit(victimGoldMin))
	b := float32(Unit(killerGoldMin))
	r := float32(float64(a) / float64(b))
	// The two fcom tests (s:0x4104a0, 0x4104b9): below 0.5 takes 0.5; 1.5 or
	// above, or unordered (0/0), takes 1.5.
	switch {
	case r < 0.5:
		r = 0.5
	case !(r < 1.5):
		r = 1.5
	}
	v := a * r
	if killerTrader {
		v = float32(float64(v) * 0.5)
	}
	if v <= 0 { // fldz; fcomp: not 0 < v
		v = 1
	}
	return int64(v)
}
