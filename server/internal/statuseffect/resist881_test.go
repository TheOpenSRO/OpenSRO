package statuseffect

import "testing"

// Round 881. Synthetic rows shaped like the table's: a weakness
// `csmd:15000,30,10,3020`, a resist buff's `real <mask>,50,<level>`, an
// earring's sleep option.

// weak is a weakness of level 10 with a 30 % chance, on a level-110 target:
// ten levels past its reach, so it rolls ftol(30 x 0.5) = 15.
var weak = Run{Code: "csmd", Values: []int{15000, 30, 10, 3020}}

func catOf(t *testing.T, code string) int {
	t.Helper()
	st, _ := StateByCode(code)
	c, ok := ResistCategory(st.Bit)
	if !ok {
		t.Fatalf("%s has no resist record", code)
	}
	return c
}

// The seventeen records, in the order FUN_0059df20 walks its mask, and the
// category each state's block passes in EAX (s:0x591011 xor eax,eax for
// sleep ... s:0x59267d 0xc for 'cssr', s:0x592886 0xd 'csit', s:0x592a8f 0xa
// 'cspd', s:0x592c98 0xb 'csmd', s:0x592ea8 0xe 'cshp', s:0x5930c4 0xf
// 'csmp', s:0x59327d 0x10 'tb').
func TestResistCategoryPerState(t *testing.T) {
	want := map[string]int{
		"se": 0, "rt": 1, "sl": 2, "fe": 3, "my": 4, "bl": 5, "dn": 6, "st": 7, "ds": 8, "ca": 9,
		"cspd": 10, "csmd": 11, "cssr": 12, "csit": 13, "cshp": 14, "csmp": 15, "tb": 16,
	}
	for code, cat := range want {
		if got := catOf(t, code); got != cat {
			t.Errorf("%s reads record %d; want %d", code, got, cat)
		}
	}
	for _, code := range []string{"fz", "fb", "es", "bu", "ps", "zb"} {
		st, _ := StateByCode(code)
		if _, ok := ResistCategory(st.Bit); ok {
			t.Errorf("%s has a resist record; the elemental six read params 27..32", code)
		}
	}
	// A mask of bleeding, darkness and the four stat curses (0x1e2800)
	// names six records; one of everything but stun (0x17fafc0) sixteen.
	if got := ResistCategoriesOfMask(0x1e2800); len(got) != 6 || got[0] != 5 || got[1] != 6 || got[5] != 13 {
		t.Errorf("mask 0x1e2800 names %v", got)
	}
	if got := ResistCategoriesOfMask(0x17fafc0); len(got) != 16 {
		t.Errorf("mask 0x17fafc0 names %d records; want 16 (no stun)", len(got))
	}
}

// The landing roll with a resist: the whole probability at or above the
// state's level, halved once per level below it, the items' percent last.
func TestResistedChance(t *testing.T) {
	cases := []struct {
		name               string
		chance, stateLevel int
		r                  CatResist
		disease            int
		want               int
	}{
		{"no resist", 15, 10, CatResist{}, 0, 15},
		{"resist a level above the state: all 50 off", 15, 10, CatResist{Level: 11, Prob: 50}, 0, -35},
		{"the same level: all 50 off", 15, 10, CatResist{Level: 10, Prob: 50}, 0, -35},
		{"the state one level above: 25 off", 30, 11, CatResist{Level: 10, Prob: 50}, 0, 5},
		{"two levels above: 12 off", 30, 12, CatResist{Level: 10, Prob: 50}, 0, 18},
		{"six levels above: nothing left of 50", 30, 16, CatResist{Level: 10, Prob: 50}, 0, 30},
		{"an odd probability halves toward zero", 30, 12, CatResist{Level: 11, Prob: 45}, 0, 8},
		{"the items' percent cuts what is left", 30, 5, CatResist{Cut: 20}, 0, 24},
		{"the percent truncates", 15, 5, CatResist{Cut: 25}, 0, 11},
		{"the percent leaves a chance of 0 or less alone", 15, 10, CatResist{Level: 10, Prob: 50, Cut: 20}, 0, -35},
		{"a disease adds its value", 15, 10, CatResist{Level: 10, Prob: 20}, 40, 35},
	}
	for _, c := range cases {
		if got := ResistedChance(c.chance, c.stateLevel, c.r, c.disease); got != c.want {
			t.Errorf("%s: %d; want %d", c.name, got, c.want)
		}
	}
}

// FUN_005999e0 reads back the highest level filed and the highest
// probability at it: a lower-level buff adds nothing, whatever its
// probability.
func TestFileKeepsTheHighestLevel(t *testing.T) {
	var c CatResist
	c.File(9, 60)
	c.File(11, 50)
	c.File(10, 90)
	c.File(11, 40)
	if c.Level != 11 || c.Prob != 50 {
		t.Errorf("filed %+v; want level 11, probability 50", c)
	}
}

// Resolve asks the dice for the resisted chance, and the target's level
// overshoot comes first.
func TestResolveRollsTheResistedChance(t *testing.T) {
	r := &recorder{answer: true}
	if _, ok := Resolve(weak, Target{Level: 110}, 0, r.roll); !ok || r.chances[0] != 15 {
		t.Fatalf("an unresisted weakness rolled %v; want 15", r.chances)
	}
	tg := Target{Level: 110}
	tg.Resist[catOf(t, "csmd")] = CatResist{Level: 11, Prob: 50}
	r = &recorder{answer: false}
	if _, ok := Resolve(weak, tg, 0, r.roll); ok || r.chances[0] != -35 {
		t.Errorf("a weakness against a level-11 50 %% resist rolled %v; want -35 and no state", r.chances)
	}
	// A resist filed under another state's record does nothing here.
	tg = Target{Level: 110}
	tg.Resist[catOf(t, "cspd")] = CatResist{Level: 11, Prob: 50}
	r = &recorder{answer: true}
	if _, ok := Resolve(weak, tg, 0, r.roll); !ok || r.chances[0] != 15 {
		t.Errorf("a decay resist changed a weakness's roll: %v", r.chances)
	}
}

// A disease on the target: every state rolls its value more, and a
// non-elemental one reaches ten levels further (s:0x5906e6..0x590717).
func TestDiseaseRaisesEveryChance(t *testing.T) {
	r := &recorder{answer: true}
	rec, _ := Resolve(weak, Target{Level: 110, Disease: 40}, 0, r.roll)
	// Level 10 + 1 reaches 110: no overshoot, the whole 30, + 40.
	if r.chances[0] != 70 || rec.DurationMs != 15000 {
		t.Errorf("a diseased target's weakness rolled %v for %d ms; want 70 and the whole 15000", r.chances, rec.DurationMs)
	}
	r = &recorder{answer: true}
	Resolve(Run{Code: "bu", Values: []int{100, 10, 20}}, Target{Disease: 40}, 0, r.roll)
	if r.chances[0] != 50 {
		t.Errorf("a diseased target's burn rolled %v; want 10 + 40", r.chances)
	}
}

// The elemental six: the percent (params 27..32) cuts the strength and so
// the duration, the flat (145..150) comes off after, and both are indexed by
// the state's client bit -- electric shock is bit 2 (param 29) and burn bit 3
// (param 30) although their slots are 3 and 2.
func TestElementalResists(t *testing.T) {
	tg := Target{}
	tg.ResistPercent[3] = 40 // burn
	rec, ok := Resolve(Run{Code: "bu", Values: []int{100, 100, 20}}, tg, 0, always)
	if !ok || rec.Strength != 60 || rec.DurationMs != 60*750 {
		t.Errorf("a burn of 100 against 40 %%: %+v; want strength 60, 45 s", rec)
	}
	if rec, _ := Resolve(Run{Code: "es", Values: []int{100, 100, 20}}, tg, 0, always); rec.Strength != 100 {
		t.Errorf("a burn resist cut an electric shock: strength %d", rec.Strength)
	}
	tg.ResistFlat[3] = 232
	if _, ok := Resolve(Run{Code: "bu", Values: []int{198, 100, 89}}, tg, 0, always); ok {
		t.Error("a burn of 198 landed through 40 % and a flat 232")
	}
	tg = Target{}
	tg.ResistPercent[4] = 100
	if _, ok := Resolve(Run{Code: "ps", Values: []int{34, 100, 16}}, tg, 0, always); ok {
		t.Error("a poison landed on a 100 % resist")
	}
	if s, ok := ElementalStrength(34, 80, 0); !ok || s != 6 {
		t.Errorf("34 against 80 %%: %d, %v; want ftol(6.8) = 6", s, ok)
	}
}

// What each curse writes (effects.go).
func TestCurseEffects(t *testing.T) {
	var h Holder
	put := func(run Run) {
		rec, ok := Resolve(run, Target{Level: 1}, 0, always)
		if !ok {
			t.Fatalf("%s did not land", run.Code)
		}
		h.Put(rec)
	}
	if h.HitRatePercent() != 0 || h.DealtFactor() != 1 || h.TakenFactor() != 1 || h.MaxHPScale() != 100 || h.MaxMPScale() != 100 || h.Disease() != 0 {
		t.Fatal("an empty holder changes something")
	}
	put(Run{Code: "dn", Values: []int{15000, 30, 10, 30}})
	put(Run{Code: "ds", Values: []int{15000, 30, 8, 40}})
	put(Run{Code: "cssr", Values: []int{15000, 20, 10, 20}})
	put(Run{Code: "csit", Values: []int{15000, 30, 10, 30}})
	put(Run{Code: "cshp", Values: []int{20000, 80, 12, 40, 50, 5}})
	put(Run{Code: "csmp", Values: []int{15000, 100, 6, 30, 50, 5}})
	if got := h.HitRatePercent(); got != -30 {
		t.Errorf("darkness: attack rate %d %%; want -30", got)
	}
	if got := h.Disease(); got != 40 {
		t.Errorf("disease: param 169 = %d; want 40", got)
	}
	if got := h.DealtFactor(); got != 0.8 {
		t.Errorf("powerless: blows dealt x %v; want 0.8", got)
	}
	if got := h.TakenFactor(); got != 1.3 {
		t.Errorf("dissociation: blows taken x %v; want 1.3", got)
	}
	if h.MaxHPScale() != 60 || h.MaxMPScale() != 70 {
		t.Errorf("panic / combustion leave %d %% / %d %%; want 60 / 70", h.MaxHPScale(), h.MaxMPScale())
	}
	if h.RecoverCut(false) != 50 || h.RecoverCut(true) != 50 {
		t.Errorf("recover cuts %d / %d; want 50 / 50", h.RecoverCut(false), h.RecoverCut(true))
	}
	if got := Recovered(1325, 50); got != 662 {
		t.Errorf("1325 recovered under a 50 %% cut: %d; want 662", got)
	}
	// The drain: 5 % of the max as cut, its low word, every tick past 2000 ms.
	if got := DrainOf(15214, 5); got != 760 {
		t.Errorf("drain of 5 %% of 15214: %d; want 760", got)
	}
	if got := DrainOf(2000000, 5); got != 100000&0xffff {
		t.Errorf("the drain keeps the low word: %d", got)
	}
	v5, on := h.DrainSpec(SlotCombustion)
	if !on || v5 != 5 {
		t.Fatalf("combustion's value[5]: %d, %v", v5, on)
	}
	h.SetDrain(SlotCombustion, 760)
	if ticks, _ := h.Step(2000, 1000, nil); len(ticks) != 0 {
		t.Errorf("a drain ticked at exactly 2000 ms: %+v", ticks)
	}
	ticks, _ := h.Step(2001, 1000, nil)
	if len(ticks) != 1 || ticks[0].DrainMP != 760 || ticks[0].Damage != 0 || ticks[0].Code != "csmp" {
		t.Errorf("the tick at 2001 ms: %+v; want one MP drain of 760", ticks)
	}
}

// A burn tick carries its table value so the dealer can divide by the
// owner's param 8.
func TestBurnTickCarriesItsTableValue(t *testing.T) {
	SetBurnTable([]int{0, 8, 9, 11, 500})
	defer SetBurnTable(nil)
	var h Holder
	rec, _ := Resolve(Run{Code: "bu", Values: []int{100, 100, 4}}, Target{}, 0, always)
	h.Put(rec)
	ticks, _ := h.Step(TickIntervalMs, 10000, nil)
	if len(ticks) != 1 || ticks[0].BurnTable != 500 || ticks[0].Damage != 500 {
		t.Fatalf("burn tick %+v; want table 500", ticks)
	}
	if got := BurnTickDamage(ticks[0].BurnTable, 119, 1.0); got != 228 {
		t.Errorf("500 behind a magical absorption of 119 %%: %d; want ftol(500 / 2.19) = 228", got)
	}
}
