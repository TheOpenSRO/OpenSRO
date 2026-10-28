package buff

// The stat writes of a buff, debuff or passive (round 785):
// ApplySkillParamsToChar (0x594ac0, READ) writes each stat code's values
// into the target's ParamKeeper keyed by the record, so the record's end
// removes them; FUN_004b2e60 / EvaluateParam (0x4b3740, READ) combine a
// param's entries as
//
//	value = S0 x (1 + S1/100) x M x S3/100
//
// S0 the flat (slot 0) sum, S1 the percent (slot 1) sum, M the product of
// (1 + e/100) over slot 2, S3 compounding from 100 -- then clamped to the
// registry's min/max. docs/protocol/skill_stats.md has the table and its
// addresses. These replace skillparam.Contributions for the stat codes,
// whose proximity join carried wrong rows (hr's p9, defr's p7/8, dcri's
// 136..139, a missing 'cr'; round 785's read).

import (
	"github.com/TheOpenSRO/OpenSRO/server/internal/skillparam"
)

// Param ids the stat writes and their readers use (param_registry.md).
const (
	ParamStr          = 1
	ParamInt          = 2
	ParamMaxHP        = 3
	ParamMaxMP        = 4
	ParamPhysDefFlat  = 5
	ParamMagDefFlat   = 6
	ParamPhysDefPct   = 7
	ParamMagDefPct    = 8
	ParamParry        = 9
	ParamBlock        = 10
	ParamHitRate      = 11
	ParamCritical     = 12
	ParamPhysAtkMin   = 13
	ParamPhysAtkMax   = 14
	ParamMagAtkMin    = 15
	ParamMagAtkMax    = 16
	ParamHPRegen      = 25
	ParamMPRegen      = 26
	ParamRange        = 33
	ParamEvadeCrit    = 57
	ParamDamagePhysA  = 128 // attacker damage %, physical, axis 1
	ParamDamagePhysB  = 129
	ParamDamageMagA   = 130
	ParamDamageMagB   = 131
	ParamBlockByType  = 136 // 136..139, the block bonus by damage type
	ParamHealHP       = 170
	ParamHealMP       = 171
	ParamAttackerMult = 178 // 178 physical, 179 magical: x on the attacker's blow
	ParamDefenderMult = 174 // 174..177 by type: x on the blow taken
	ParamThreat       = 187
	// ParamUniqueDamage is 'umdu' (MATTR_NASRUN_UMDU, the devil's spirit
	// magic stone): a damage percent against a class-3 (unique) monster,
	// added to 128..131's in Formula_Mitigate* (0x40e5ba..0x40e5de, READ;
	// round 838).
	ParamUniqueDamage = 259
	// ParamIgnoreDefence is p188 ('msid', 'mdia'): the chance a player's
	// blow skips a monster's defence (round 838).
	ParamIgnoreDefence = 188
)

// typeSelect is the 2x2 selector (0x410bb0 / 0x410c20, READ): a mask's
// damage-type bit (4 physical, 8 magical) and its axis bit (1, 2) pick one
// of four consecutive params from base. A mask may name several.
func typeSelect(base int, mask int32) []int {
	var out []int
	for ti, t := range []int32{4, 8} {
		for ai, a := range []int32{1, 2} {
			if mask&t != 0 && mask&a != 0 {
				out = append(out, base+ti*2+ai)
			}
		}
	}
	return out
}

func val(v []int32, i int) float64 {
	if i < 0 || i >= len(v) {
		return 0
	}
	return float64(v[i])
}

// StatContributions returns the ParamKeeper writes of a row's stat codes, as
// ApplySkillParamsToChar makes them (READ round 785). actionKind is the
// row's Param1 and activity its Basic_Activity: 'cr' writes only on a passive
// row (Activity 0) and 'tant' only on an action-kind-3 row. The speed codes
// ('hste'/'hst2'/'hst3') are not here: Books.Start keeps its own holder for
// them.
func StatContributions(r skillparam.Runs, actionKind, activity int) []Contribution {
	var out []Contribution
	add := func(param int, slot skillparam.Slot, v float64) {
		if v != 0 {
			out = append(out, Contribution{Param: param, Slot: slot, Value: v})
		}
	}
	base, pct, mult := skillparam.SlotBase, skillparam.SlotPct, skillparam.SlotMult
	if v, ok := r.Values("defp"); ok {
		// p5/p6 slot 0 = v0/v1 (+ the context's +0x34/+0x38, 0 for a
		// skill's own cast). v2's cap is OPEN and not applied.
		add(ParamPhysDefFlat, base, val(v, 0))
		add(ParamMagDefFlat, base, val(v, 1))
	}
	if v, ok := r.Values("defr"); ok {
		add(ParamPhysDefFlat, pct, val(v, 0))
		add(ParamMagDefFlat, pct, val(v, 1))
	}
	if v, ok := r.Values("ar"); ok {
		add(ParamPhysDefPct, base, val(v, 0))
		add(ParamMagDefPct, base, val(v, 1))
	}
	if v, ok := r.Values("hr"); ok { // asm 0x595825..0x595875
		add(ParamHitRate, base, val(v, 0))
		add(ParamHitRate, pct, val(v, 1))
	}
	if v, ok := r.Values("er"); ok {
		add(ParamParry, base, val(v, 0))
		add(ParamParry, pct, val(v, 1))
	}
	if v, ok := r.Values("terd"); ok {
		add(ParamParry, base, -val(v, 0))
	}
	if v, ok := r.Values("thrd"); ok {
		add(ParamHitRate, base, -val(v, 0))
	}
	if v, ok := r.Values("cr"); ok && activity == 0 {
		add(ParamCritical, base, val(v, 0))
		add(ParamCritical, pct, val(v, 1))
	}
	if v, ok := r.Values("br"); ok {
		for _, p := range typeSelect(ParamBlockByType, int32(val(v, 0))) {
			add(p, base, val(v, 1))
		}
	}
	if v, ok := r.Values("hpi"); ok {
		add(ParamMaxHP, base, val(v, 0))
		add(ParamMaxHP, pct, val(v, 1))
	}
	if v, ok := r.Values("mpi"); ok {
		add(ParamMaxMP, base, val(v, 0))
		add(ParamMaxMP, pct, val(v, 1))
	}
	for _, code := range []skillparam.Code{"apau", "apru"} {
		if v, ok := r.Values(code); ok {
			slot := base
			if code == "apru" {
				slot = pct
			}
			add(ParamPhysAtkMin, slot, val(v, 0))
			add(ParamPhysAtkMax, slot, val(v, 0))
			add(ParamMagAtkMin, slot, val(v, 1))
			add(ParamMagAtkMax, slot, val(v, 1))
		}
	}
	if v, ok := r.Values("tpad"); ok {
		add(ParamPhysAtkMin, pct, -val(v, 0))
		add(ParamPhysAtkMax, pct, -val(v, 0))
	}
	if v, ok := r.Values("tpdd"); ok {
		add(ParamPhysDefFlat, pct, -val(v, 0))
	}
	if v, ok := r.Values("dru"); ok { // asm 0x595a97..
		add(ParamDamagePhysA, base, val(v, 0))
		add(ParamDamagePhysB, base, val(v, 0))
		add(ParamDamageMagA, base, val(v, 1))
		add(ParamDamageMagB, base, val(v, 1))
	}
	if v, ok := r.Values("dru2"); ok {
		for _, p := range typeSelect(ParamDamagePhysA, int32(val(v, 0))) {
			add(p, base, val(v, 1))
		}
	}
	if v, ok := r.Values("odar"); ok {
		for _, p := range typeSelect(ParamDefenderMult, int32(val(v, 0))) {
			add(p, mult, -val(v, 1))
		}
	}
	if v, ok := r.Values("irgc"); ok {
		add(ParamHPRegen, pct, val(v, 0))
		add(ParamMPRegen, pct, val(v, 1))
	}
	if v, ok := r.Values("ru"); ok {
		add(ParamRange, base, val(v, 0))
	}
	// Round 838: 'msid' (the devil's spirit's MOBDEFENCEIGNORE skills) puts
	// value[0] in p188 slot 0, the chance to skip a monster's defence
	// (ApplySkillParamsToChar 0x596747, READ; session's ignoreDefenceRoll).
	if v, ok := r.Values("msid"); ok {
		add(ParamIgnoreDefence, base, val(v, 0))
	}
	if v, ok := r.Values("dcri"); ok {
		add(ParamEvadeCrit, base, val(v, 0))
	}
	if v, ok := r.Values("stri"); ok {
		add(ParamStr, base, val(v, 0))
	}
	if v, ok := r.Values("inti"); ok {
		add(ParamInt, base, val(v, 0))
	}
	if v, ok := r.Values("tant"); ok && actionKind == 3 {
		add(ParamThreat, base, val(v, 1))
	}
	// The penalty runs whose mode (value[3]) is 2 are written as plain
	// params for the record's life (aspc 890..975, READ); every player row is
	// mode 2 (MEASURED).
	if v, ok := r.Values("pmhp"); ok && val(v, 3) == 2 {
		if val(v, 1) != 0 {
			add(ParamMaxHP, base, -val(v, 1))
		} else {
			add(ParamMaxHP, pct, -val(v, 2))
		}
	}
	if v, ok := r.Values("pmmp"); ok && val(v, 3) == 2 {
		if val(v, 1) != 0 {
			add(ParamMaxMP, base, -val(v, 1))
		} else {
			add(ParamMaxMP, pct, -val(v, 2))
		}
	}
	if v, ok := r.Values("pmdg"); ok && val(v, 3) == 2 {
		add(ParamAttackerMult, mult, -val(v, 1))
		add(ParamAttackerMult+1, mult, -val(v, 2))
	}
	if v, ok := r.Values("pmdp"); ok && val(v, 3) == 2 {
		add(ParamPhysDefFlat, pct, -val(v, 1))
		add(ParamMagDefFlat, pct, -val(v, 2))
	}
	if v, ok := r.Values("rhru"); ok {
		add(ParamHealHP, base, val(v, 0))
		add(ParamHealMP, base, val(v, 1))
	}
	return out
}

// Totals is one param's sum over an owner's records.
type Totals struct {
	Flat    float64 // slot 0
	Pct     float64 // slot 1
	Mult    float64 // slot 2's product of (1 + e/100); 1 when none
	HasMult bool
}

// Apply is EvaluateParam's combination for a param whose other entries (the
// character's own, the gear's) sum to base: (base + Flat) x (1 + Pct/100)
// x Mult.
func (t Totals) Apply(base float64) float64 {
	v := (base + t.Flat) * (1 + t.Pct/100)
	if t.HasMult {
		v *= t.Mult
	}
	return v
}

// Factor is a multiplier param's value (174..181): with no other entry M
// stands alone (FUN_004b2e60: a zero S0 x S1 is replaced by M, READ), 1
// when the param has none.
func (t Totals) Factor() float64 {
	if !t.HasMult {
		return 1
	}
	return t.Mult
}

// ParamTotals is ownerID's stat sums over its active records. It takes no
// lock: the snapshot is refreshed whenever the records change
// (refreshStatsLocked), so a stat can be read from inside a book operation.
func (b *Books) ParamTotals(ownerID int64) map[int]Totals {
	v, ok := b.stats.Load(ownerID)
	if !ok {
		return nil
	}
	return v.(map[int]Totals)
}

// refreshStatsLocked recomputes ownerID's snapshot from bk. Called with mu.
func (b *Books) refreshStatsLocked(ownerID int64, bk *book) {
	if bk == nil || len(bk.records) == 0 {
		b.stats.Delete(ownerID)
		return
	}
	out := map[int]Totals{}
	for _, r := range bk.records {
		for _, c := range r.Stats {
			t, seen := out[c.Param]
			if !seen {
				t.Mult = 1
			}
			switch c.Slot {
			case skillparam.SlotBase:
				t.Flat += c.Value
			case skillparam.SlotPct:
				t.Pct += c.Value
			case skillparam.SlotMult:
				t.Mult *= 1 + c.Value/100
				t.HasMult = true
			}
			out[c.Param] = t
		}
	}
	if len(out) == 0 {
		b.stats.Delete(ownerID)
		return
	}
	b.stats.Store(ownerID, out)
}
