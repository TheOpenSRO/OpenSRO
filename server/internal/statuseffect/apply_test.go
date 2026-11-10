package statuseffect

import "testing"

// Round 659. The rows below are SYNTHETIC, shaped like the real ones this
// round measured in skilldata (ps:34,100,16 on MSKILL_CH_WATERGHOST_ATTACK02;
// fz:30,5 on SKILL_CH_COLD_GIGONGTA_A_01; st:5000,20,2 on
// SKILL_CH_SPEAR_STUN_A_01; bl:30000,18,8,156,20 on SKILL_CH_SWORD_SMASH_D_01).

// always and never are dice that do not roll.
func always(int, int) bool { return true }
func never(int, int) bool  { return false }

// recorder remembers what the dice were asked.
type recorder struct {
	chances, kinds []int
	answer         bool
}

func (r *recorder) roll(chance, kind int) bool {
	r.chances = append(r.chances, chance)
	r.kinds = append(r.kinds, kind)
	return r.answer
}

// THE CORRECTION: an elemental run's value[1] is the chance the dice roll,
// under the state's kind, and value[0] is the strength the duration
// multiplies. A 5 % freeze of strength 30 asks the dice for 5 (not 30), and
// lasts 30 x 97 ms.
func TestElementalValueOneIsTheChanceAndValueZeroTheStrength(t *testing.T) {
	r := &recorder{answer: true}
	rec, ok := Resolve(Run{Code: "fz", Values: []int{30, 5}}, Target{Level: 40}, 1000, r.roll)
	if !ok {
		t.Fatal("a freeze the dice let through did not land")
	}
	if len(r.chances) != 1 || r.chances[0] != 5 || r.kinds[0] != 1 {
		t.Fatalf("the dice were asked %v under kinds %v; want one roll of 5 under kind 1 (freeze)", r.chances, r.kinds)
	}
	if rec.Strength != 30 || rec.DurationMs != 30*97 || rec.Slot != SlotFreeze || rec.Bit != 0 {
		t.Errorf("freeze record %+v; want strength 30, 2910 ms, slot 0, bit 0", rec)
	}
	// And the dice decide: the same run with the dice against it lands nothing.
	if _, ok := Resolve(Run{Code: "fz", Values: []int{30, 5}}, Target{}, 1000, never); ok {
		t.Error("a freeze landed although the dice said no")
	}
}

// The elemental strength is cut by the target's resist percent and flat
// resist, and a full resist stops it -- after the roll, the engine's order.
func TestElementalResistCutsTheStrengthAfterTheRoll(t *testing.T) {
	r := &recorder{answer: true}
	var tg Target
	tg.ResistPercent[SlotPoison] = 50
	tg.ResistFlat[SlotPoison] = 2
	rec, ok := Resolve(Run{Code: "ps", Values: []int{34, 100, 16}}, tg, 0, r.roll)
	if !ok || rec.Strength != 34/2-2 || rec.DurationMs != uint32((34/2-2)*1000) || rec.TickValue != 16 {
		t.Fatalf("poison under 50%%/2 resist: %+v (ok %v); want strength 15, 15 s, 16 a tick", rec, ok)
	}
	tg.ResistPercent[SlotPoison] = 100
	r2 := &recorder{answer: true}
	if _, ok := Resolve(Run{Code: "ps", Values: []int{34, 100, 16}}, tg, 0, r2.roll); ok || len(r2.chances) != 1 {
		t.Errorf("a full resist: landed %v after %d rolls; want no state, and the roll still taken", ok, len(r2.chances))
	}
}

// A non-elemental run: value[0] the duration, value[1] the chance, value[2]
// the level -- the level byte the client reads -- with the falloff past the
// level reach.
func TestNonElementalStun(t *testing.T) {
	r := &recorder{answer: true}
	rec, ok := Resolve(Run{Code: "st", Values: []int{5000, 20, 2}}, Target{Level: 20}, 7, r.roll)
	if !ok || rec.DurationMs != 5000 || rec.Level != 2 || rec.Slot != SlotStun || rec.Bit != 14 {
		t.Fatalf("stun on a level-20 target: %+v (ok %v)", rec, ok)
	}
	if r.chances[0] != 20 || r.kinds[0] != 15 {
		t.Errorf("stun rolled %v under %v; want 20 under kind 15", r.chances, r.kinds)
	}
	// Ten levels past its reach: 25 % off the duration, 50 % off the chance.
	r = &recorder{answer: true}
	rec, _ = Resolve(Run{Code: "st", Values: []int{5000, 20, 2}}, Target{Level: 30}, 7, r.roll)
	if rec.DurationMs != 3750 || r.chances[0] != 10 {
		t.Errorf("ten levels over: %d ms, chance %d; want 3750 and 10", rec.DurationMs, r.chances[0])
	}
}

// 'tb' is not applied (its block is unread; 'csmp' is from round 881),
// and a code that is no state is ignored.
func TestUnreadStatesAreNotApplied(t *testing.T) {
	for _, code := range []string{"tb", "att", "puls"} {
		if _, ok := Resolve(Run{Code: code, Values: []int{10000, 100, 1, 5}}, Target{}, 0, always); ok {
			t.Errorf("%q landed", code)
		}
	}
}

func TestParseRunsAndPuls(t *testing.T) {
	runs := ParseRuns("bl:30000,18,8,156,20;puls:3000; junk ;fz:30,x")
	if len(runs) != 2 || runs[0].Code != "bl" || runs[0].Value(3) != 156 || runs[1].Code != "puls" {
		t.Fatalf("parsed %+v", runs)
	}
	if ms, ok := PulsMs(runs); !ok || ms != 3000 {
		t.Errorf("puls %d %v", ms, ok)
	}
	recs := ResolveAll(runs, Target{}, 0, always)
	if len(recs) != 1 || recs[0].TickIntervalMs != 3000 || recs[0].TickValue != 156 || recs[0].DefenceCut != 20 {
		t.Errorf("bleeding with puls: %+v", recs)
	}
}

// A slot holds one state: a second freeze replaces the first.
func TestASlotHoldsOneState(t *testing.T) {
	var h Holder
	a, _ := Resolve(Run{Code: "fz", Values: []int{30, 100}}, Target{}, 0, always)
	b, _ := Resolve(Run{Code: "fz", Values: []int{10, 100}}, Target{}, 500, always)
	h.Put(a)
	h.Put(b)
	got, _ := h.Get(SlotFreeze)
	if got.Strength != 10 || got.StartMs != 500 || h.Mask() != 0x1 {
		t.Errorf("after two freezes: %+v, mask %#x; want the second, alone", got, h.Mask())
	}
}

// Apply, tick, expire: poison ticks once 2001 ms have passed, stops at 1 HP,
// and is gone once its duration has passed -- removed before its tick.
func TestPoisonTicksAndExpires(t *testing.T) {
	var h Holder
	rec, _ := Resolve(Run{Code: "ps", Values: []int{5, 100, 16}}, Target{}, 1000, always) // 5 s
	h.Put(rec)
	if h.Mask() != 0x10 {
		t.Fatalf("poison mask %#x, want 0x10", h.Mask())
	}
	if ticks, _ := h.Step(3000, 100, nil); len(ticks) != 0 {
		t.Errorf("a tick at 2000 ms: %+v; the engine waits for 2001", ticks)
	}
	ticks, changed := h.Step(3001, 100, nil)
	if len(ticks) != 1 || ticks[0].Damage != 16 || ticks[0].Source != SourceNone || changed {
		t.Fatalf("at 2001 ms: %+v changed %v; want one 16 naming nobody (no caster)", ticks, changed)
	}
	if ticks, _ := h.Step(5002, 10, nil); len(ticks) != 1 || ticks[0].Damage != 9 {
		t.Errorf("poison at 10 HP dealt %+v; want 9 -- it stops at 1", ticks)
	}
	if ticks, changed := h.Step(6001, 1, nil); len(ticks) != 0 || !changed || h.Mask() != 0 {
		t.Errorf("past 5000 ms: ticks %+v changed %v mask %#x; want the state removed, no tick", ticks, changed, h.Mask())
	}
}

// Bleeding ticks its value[3] every MORE than its interval. Round 659's
// review (M2): a LIVING caster is named on every tick, fatal or not; a dead
// one latches the record, after which only a fatal tick names it.
func TestBleedingNamesALivingCasterEveryTick(t *testing.T) {
	var h Holder
	rec, _ := Resolve(Run{Code: "bl", Values: []int{30000, 100, 1, 200, 0}}, Target{}, 0, always)
	rec.SourceID = 42
	h.Put(rec)
	state := CasterAlive
	caster := func(id int64, _ bool) CasterState {
		if id != 42 {
			return CasterGone
		}
		return state
	}
	if ticks, _ := h.Step(2000, 500, caster); len(ticks) != 0 {
		t.Errorf("a bleeding tick at exactly its interval: %+v", ticks)
	}
	ticks, _ := h.Step(2001, 500, caster)
	if len(ticks) != 1 || ticks[0].Damage != 200 || ticks[0].Source != SourceKept || ticks[0].SourceID != 42 || !ticks[0].Credited(false) {
		t.Fatalf("a non-fatal bleed from a living caster: %+v; want 200 naming 42", ticks)
	}
	state = CasterDead
	ticks, _ = h.Step(4002, 500, caster)
	if len(ticks) != 1 || ticks[0].Source != SourceIfFatal || ticks[0].Credited(false) || !ticks[0].Credited(true) {
		t.Fatalf("the caster dead: %+v; want the source only for a fatal tick", ticks)
	}
	state = CasterAlive // revived: the latch holds
	if ticks, _ = h.Step(6003, 500, caster); len(ticks) != 1 || ticks[0].Source != SourceIfFatal {
		t.Errorf("the latch let go when the caster revived: %+v", ticks)
	}
}

// Poison names a living caster too, and nobody once it has latched; a caster
// who is gone is named by no damage applier.
func TestPoisonSourceRule(t *testing.T) {
	var h Holder
	rec, _ := Resolve(Run{Code: "ps", Values: []int{60, 100, 5}}, Target{}, 0, always)
	rec.SourceID = 7
	rec.SourceIsMonster = true
	h.Put(rec)
	alive := func(int64, bool) CasterState { return CasterAlive }
	if ticks, _ := h.Step(2001, 100, alive); len(ticks) != 1 || ticks[0].Source != SourceKept || !ticks[0].SourceIsMonster || !ticks[0].NeverKills {
		t.Fatalf("poison from a living monster: %+v", ticks)
	}
	dead := func(int64, bool) CasterState { return CasterDead }
	if ticks, _ := h.Step(4002, 100, dead); len(ticks) != 1 || ticks[0].Source != SourceNone {
		t.Errorf("poison from a dead caster: %+v; want nobody", ticks)
	}
	var g Holder
	b, _ := Resolve(Run{Code: "bl", Values: []int{30000, 100, 1, 200, 0}}, Target{}, 0, always)
	b.SourceID = 9
	g.Put(b)
	if ticks, _ := g.Step(2001, 100, func(int64, bool) CasterState { return CasterGone }); len(ticks) != 1 || ticks[0].Source != SourceNone || ticks[0].Credited(true) {
		t.Errorf("a bleed whose caster is gone: %+v; want nobody, even fatal", ticks)
	}
}

// A freeze that ends holds its owner FROZEN for 1.5 s more (L4).
func TestFreezeThawHoldsFor1500ms(t *testing.T) {
	var h Holder
	rec, _ := Resolve(Run{Code: "fz", Values: []int{10, 100}}, Target{}, 0, always) // 970 ms
	h.Put(rec)
	if h.CanActAt(500) {
		t.Fatal("frozen, yet able to act")
	}
	h.Step(971, 100, nil)
	if h.Mask() != 0 {
		t.Fatalf("the freeze outlived its 970 ms: mask 0x%x", h.Mask())
	}
	if h.CanActAt(1000) || h.CanActAt(2470) || h.Idle(2000) {
		t.Error("the thaw let go before 1.5 s")
	}
	if !h.CanActAt(2471) || !h.Idle(2471) {
		t.Error("still held 1.5 s after the freeze ended")
	}
}

// The mask, the level bytes, and what the states stop.
func TestMaskLevelsAndWhatTheyStop(t *testing.T) {
	var h Holder
	for _, run := range []Run{{"bu", []int{10, 100, 1}}, {"st", []int{5000, 100, 3}}, {"sl", []int{5000, 100, 4}}} {
		r, ok := Resolve(run, Target{}, 0, always)
		if !ok {
			t.Fatalf("%s did not land", run.Code)
		}
		h.Put(r)
	}
	// burn is slot 2 but the client's bit 3 (0x8); stun 0x4000; slow 0x100.
	if h.Mask() != 0x8|0x4000|0x100 {
		t.Errorf("mask %#x", h.Mask())
	}
	// Levels in bit order for the bits that carry one: slow (bit 8) then stun (bit 14).
	if lv := h.Levels(); len(lv) != 2 || lv[0] != 4 || lv[1] != 3 {
		t.Errorf("levels %v; want [4 3]", lv)
	}
	if h.CanMove() || h.CanAct() || h.SpeedPercent() != 75 {
		t.Errorf("stunned and slowed: move %v act %v speed %d", h.CanMove(), h.CanAct(), h.SpeedPercent())
	}
	fb, _ := Resolve(Run{Code: "fb", Values: []int{10, 100}}, Target{}, 0, always)
	h.Put(fb)
	if h.SpeedPercent() != 50 {
		t.Errorf("frostbite over slow: %d%%, want 50", h.SpeedPercent())
	}
	var root Holder
	rt, _ := Resolve(Run{Code: "rt", Values: []int{10000, 100, 2}}, Target{}, 0, always)
	root.Put(rt)
	if root.CanMove() || !root.CanAct() {
		t.Errorf("rooted: move %v act %v; want no move, but acting", root.CanMove(), root.CanAct())
	}
}
