package session

import (
	"context"
	"math/rand"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skillparam"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
)

// Round 881: a character's own resists. The rows are SYNTHETIC, shaped like
// the table's: a resist buff `reat 63 228; real 0x17fafc0 50 11` (every
// non-elemental state but stun), a resist passive `reat 28 116; real
// 0x1e2800 50 11` gated by `reqi 10 0; reqi 6 15; reqn`, accessories with a
// 20 % option each, a weakness `csmd:15000,30,10,3020`.

const (
	maskAllButStun881 = 0x17fafc0
	maskCurses881     = 0x1e2800
)

func word881(code string) int32 { return skillparam.WordOf(skillparam.Code(code)) }

// runs881 parses a synthetic Param block.
func runs881(t *testing.T, words ...int32) skillparam.Runs {
	t.Helper()
	return skillparam.WalkRuns(words[1:]) // the first word is the action kind
}

func catOf881(code string) int {
	st, _ := statuseffect.StateByCode(code)
	c, _ := statuseffect.ResistCategory(st.Bit)
	return c
}

// A running resist buff files its probability and level in every record its
// mask names, and its flat elemental resists in params 145..150.
func TestResistBuffReachesTheTarget(t *testing.T) {
	const id = 881001
	r := runs881(t, 3, word881("dura"), 300000, word881("reat"), 63, 228, word881("real"), maskAllButStun881, 50, 11)
	spec := buff.Spec{SkillID: 88101, GroupID: 88101, CasterID: id, DuraMs: 300000,
		Stats: buff.StatContributions(r, 3, 2), Resists: buff.StateResists(r)}
	if len(spec.Resists) != 1 || spec.Resists[0] != (buff.StateResist{Mask: maskAllButStun881, Prob: 50, Level: 11}) {
		t.Fatalf("the row's state resists: %+v", spec.Resists)
	}
	if _, _, refused, _ := buffBooks.Start(id, spec, time.Now()); refused != 0 {
		t.Fatalf("the buff was refused: %v", refused)
	}
	t.Cleanup(func() { buffBooks.EndAll(id) })

	tg := statusTargetOf(context.Background(), id, 110, nil, nil)
	if got := tg.Resist[catOf881("csmd")]; got.Level != 11 || got.Prob != 50 || got.Cut != 0 {
		t.Errorf("weakness record %+v; want level 11, probability 50", got)
	}
	if got := tg.Resist[catOf881("st")]; got != (statuseffect.CatResist{}) {
		t.Errorf("the mask leaves stun out, yet its record reads %+v", got)
	}
	for bit, v := range tg.ResistFlat {
		if v != 228 {
			t.Errorf("elemental flat resist %d = %d; want 228", bit, v)
		}
	}
	// The weakness on a level-110 character: ftol(30 x 0.5) = 15, less 50.
	var asked []int
	roll := func(chance, kind int) bool { asked = append(asked, chance); return false }
	statuseffect.Resolve(statuseffect.Run{Code: "csmd", Values: []int{15000, 30, 10, 3020}}, tg, 0, roll)
	if len(asked) != 1 || asked[0] != -35 {
		t.Errorf("the weakness rolled %v; want -35", asked)
	}
	// The buff over: nothing left.
	buffBooks.EndAll(id)
	if got := statusTargetOf(context.Background(), id, 110, nil, nil).Resist[catOf881("csmd")]; got != (statuseffect.CatResist{}) {
		t.Errorf("the record after the buff's end: %+v", got)
	}
}

// 'bgra' writes the percent params by its mask's bits.
func TestBgraWritesThePercentParams(t *testing.T) {
	cs := buff.StatContributions(runs881(t, 3, word881("bgra"), 0b001010, 58), 3, 2)
	got := map[int]float64{}
	for _, c := range cs {
		got[c.Param] = c.Value
	}
	if len(got) != 2 || got[28] != 58 || got[30] != 58 {
		t.Errorf("bgra mask 0b001010 wrote %v; want params 28 and 30 = 58", got)
	}
}

// A passive's resists count only while its own list holds: a whole
// light-armour set AND a cleric rod here (FUN_0059f0e0).
func TestPassiveResistNeedsItsList(t *testing.T) {
	reqs := []combat.CastRequirement{{Kind: 10, Value: 0}, {Kind: 6, Value: 15}}
	set := func(kind int, weapon int) []wornKind {
		var w []wornKind
		for _, s := range equipment.ArmorSlots {
			w = append(w, wornKind{slot: s, typeID3: kind, typeID4: 1})
		}
		return append(w, wornKind{slot: equipment.SlotWeapon, typeID3: 6, typeID4: weapon})
	}
	for _, tc := range []struct {
		name string
		worn []wornKind
		want bool
	}{
		{"light armour and a cleric rod", set(10, 15), true},
		{"light armour and a two-handed sword", set(10, 8), false},
		{"a robe and a cleric rod", set(9, 15), false},
		{"five light pieces and a rod", set(10, 15)[1:], false},
	} {
		if got := passiveReqsHold(reqs, true, tc.worn); got != tc.want {
			t.Errorf("%s: %v; want %v", tc.name, got, tc.want)
		}
	}
	// Without 'reqn' one entry is enough; an empty list always holds.
	if !passiveReqsHold([]combat.CastRequirement{{Kind: 6, Value: 9}, {Kind: 6, Value: 8}}, false, set(9, 8)) {
		t.Error("an any-of list refused a matching weapon")
	}
	if !passiveReqsHold(nil, true, nil) {
		t.Error("an empty list failed")
	}

	// The split: the passive's elemental writes and its 'real' leave the
	// ungated stats.
	row := &refdata.Skill{ReqCastList: "10:0;6:15", ReqCastAll: true}
	r := runs881(t, 4, word881("reat"), 28, 116, word881("real"), maskCurses881, 50, 11, word881("hr"), 10, 0)
	rest, pr := splitPassiveResists(row, buff.StatContributions(r, 4, 0), buff.StateResists(r))
	if pr == nil || len(pr.resists) != 1 || pr.flat != [6]int{0, 0, 116, 116, 116, 0} || !pr.all || len(pr.reqs) != 2 {
		t.Fatalf("the gated part: %+v", pr)
	}
	if len(rest) != 1 || rest[0].Param != buff.ParamHitRate {
		t.Errorf("the ungated stats: %+v; want the hit rate alone", rest)
	}

	// Through statusTargetOf: with the rod and the light set the weakness
	// record is filed; with a sword it is not.
	const id = 881002
	items := stubCombatItems{}
	wear := func(weaponType int) fixedEquipment {
		var worn []equipment.Equipped
		for i, s := range equipment.ArmorSlots {
			iid := int64(88200 + i)
			items[iid] = &refdata.Item{ID: iid, TypeID3: 10, TypeID4: i + 1}
			worn = append(worn, equipment.Equipped{Slot: s, ItemID: iid, Durability: 100})
		}
		wid := int64(88210 + weaponType)
		items[wid] = &refdata.Item{ID: wid, TypeID3: 6, TypeID4: weaponType}
		return fixedEquipment{worn: append(worn, equipment.Equipped{Slot: equipment.SlotWeapon, ItemID: wid, Durability: 100})}
	}
	passives.Lock()
	passives.m[id] = passiveState{at: time.Now(), resists: []passiveResist{*pr}}
	passives.Unlock()
	t.Cleanup(func() { invalidatePassives(id) })
	if got := statusTargetOf(context.Background(), id, 110, wear(15), items); got.Resist[catOf881("csmd")].Prob != 50 || got.ResistFlat[3] != 116 {
		t.Errorf("with the rod: weakness %+v, burn flat %d; want 50 and 116", got.Resist[catOf881("csmd")], got.ResistFlat[3])
	}
	if got := statusTargetOf(context.Background(), id, 110, wear(8), items); got.Resist[catOf881("csmd")] != (statuseffect.CatResist{}) || got.ResistFlat[3] != 0 {
		t.Errorf("with a sword the passive still counted: %+v, flat %d", got.Resist[catOf881("csmd")], got.ResistFlat[3])
	}
}

// The worn items' options: four accessories with 20 % each of freezing /
// frostbite ('fz' writes both), electric shock, burn, poison and zombie give
// 80 %; a sleep option goes to sleep's percent list; a set's 'rals' to all
// six params and to combustion, disease, sleep and fear.
func TestItemOptionsReachTheTarget(t *testing.T) {
	const id = 881003
	row := func(oid uint16, tag string) *magicopt.Row {
		return &magicopt.Row{ID: oid, Code: "MATTR_T881_" + tag, Level: 11, Tag: magicopt.PackTag(tag)}
	}
	SetMagicOptions(magicopt.New([]*magicopt.Row{
		row(8811, "fz"), row(8812, "es"), row(8813, "bu"), row(8814, "ps"), row(8815, "zb"),
		row(8816, "rsli"), row(8817, "rals"), row(8818, "rsti"),
	}))
	t.Cleanup(func() { SetMagicOptions(nil) })
	var worn []equipment.Equipped
	for i, s := range equipment.AccessorySlots {
		e := equipment.Equipped{Slot: s, ItemID: int64(88300 + i), Durability: -1}
		for _, oid := range []uint16{8811, 8812, 8813, 8814, 8815} {
			e.MagParams = append(e.MagParams, inventory.MagParam(oid, 20))
		}
		worn = append(worn, e)
	}
	worn[0].MagParams = append(worn[0].MagParams, inventory.MagParam(8816, 40))
	worn[1].MagParams = append(worn[1].MagParams, inventory.MagParam(8818, 12))
	tg := statusTargetOf(context.Background(), id, 110, fixedEquipment{worn: worn}, nil)
	if tg.ResistPercent != [6]int{80, 80, 80, 80, 80, 80} {
		t.Errorf("elemental percents %v; want 80 each", tg.ResistPercent)
	}
	if tg.Resist[statuseffect.ResistCatSleep].Cut != 40 || tg.Resist[statuseffect.ResistCatStun].Cut != 12 || tg.Resist[catOf881("csmd")].Cut != 0 {
		t.Errorf("percent lists: sleep %d, stun %d, weakness %d; want 40, 12, 0",
			tg.Resist[statuseffect.ResistCatSleep].Cut, tg.Resist[statuseffect.ResistCatStun].Cut, tg.Resist[catOf881("csmd")].Cut)
	}
	// A poison of strength 60 lasts 60 s; behind 80 % it is 12 s.
	rec, ok := statuseffect.Resolve(statuseffect.Run{Code: "ps", Values: []int{60, 100, 500}}, tg, 0, func(int, int) bool { return true })
	if !ok || rec.DurationMs != 12000 {
		t.Errorf("a 60 s poison behind 80 %%: %d ms, landed %v; want 12000", rec.DurationMs, ok)
	}
	// 'rals' on top: capped at 100, and four lists.
	worn[2].MagParams = append(worn[2].MagParams, inventory.MagParam(8817, 30))
	tg = statusTargetOf(context.Background(), id, 110, fixedEquipment{worn: worn}, nil)
	if tg.ResistPercent != [6]int{100, 100, 100, 100, 100, 100} {
		t.Errorf("with 'rals' 30 the percents are %v; want the cap, 100", tg.ResistPercent)
	}
	for _, cat := range []int{statuseffect.ResistCatCombustion, statuseffect.ResistCatDisease, statuseffect.ResistCatFear} {
		if tg.Resist[cat].Cut != 30 {
			t.Errorf("'rals' in record %d: %d; want 30", cat, tg.Resist[cat].Cut)
		}
	}
	if tg.Resist[statuseffect.ResistCatSleep].Cut != 70 {
		t.Errorf("sleep's list: %d; want 40 + 30", tg.Resist[statuseffect.ResistCatSleep].Cut)
	}
}

// The dice with a chance below zero (FUN_00599cc0): clamped to 0 and rolled
// against the caster's accumulator -- at most once per caster, and only when
// the roll is 0.
func TestNegativeChanceRollsAgainstTheAccumulator(t *testing.T) {
	tr := combat.NewChanceTracker()
	r := rand.New(rand.NewSource(881))
	const rolls = 101 * 400
	landed := 0
	for caster := int64(1); caster <= rolls; caster++ {
		if combat.RollChanceClamped(-35, r, tr, caster, combat.ChanceStatus(22)) {
			landed++
			if acc, _ := tr.Accumulated(caster, combat.ChanceStatus(22)); acc != -100 {
				t.Fatalf("after landing the accumulator is %d; want -100", acc)
			}
			for i := 0; i < 50; i++ {
				if combat.RollChanceClamped(-35, r, tr, caster, combat.ChanceStatus(22)) {
					t.Fatal("a caster landed a fully resisted state twice")
				}
			}
		}
	}
	// One first roll in 101 comes up 0: about 400 of 40,400.
	if landed < 320 || landed > 480 {
		t.Errorf("%d of %d fresh casters landed a resisted state; want about one in 101", landed, rolls)
	}
	// A chance of exactly 0 never rolls and never lands.
	for caster := int64(1); caster <= 2000; caster++ {
		if combat.RollChanceClamped(0, r, tr, -caster, combat.ChanceStatus(22)) {
			t.Fatal("a chance of 0 landed")
		}
		if _, seen := tr.Accumulated(-caster, combat.ChanceStatus(22)); seen {
			t.Fatal("a chance of 0 touched the accumulator")
		}
	}
	// A caster whose accumulator earlier rolls built up can land it.
	tr2 := combat.NewChanceTracker()
	lands := 0
	for i := 0; i < 4000; i++ {
		c := int64(i + 1)
		combat.RollChanceTracked(15, rand.New(rand.NewSource(int64(i))), tr2, c, combat.ChanceStatus(22))
		if acc, _ := tr2.Accumulated(c, combat.ChanceStatus(22)); acc == 30 { // the first roll failed: 15 + 15
			if combat.RollChanceClamped(-35, r, tr2, c, combat.ChanceStatus(22)) {
				lands++
			}
		}
	}
	// 31 of 101 rolls are at or under 30.
	if lands < 800 || lands > 1300 {
		t.Errorf("%d of ~3400 casters with 30 banked landed the resisted state; want about 31 in 101", lands)
	}
}

func put881(t *testing.T, id int64, run statuseffect.Run) {
	t.Helper()
	rec, ok := statuseffect.Resolve(run, statuseffect.Target{Level: 1}, 0, func(int, int) bool { return true })
	if !ok {
		t.Fatalf("%s did not land", run.Code)
	}
	statusFX.mu.Lock()
	h := statusFX.pcs[id]
	if h == nil {
		h = &statuseffect.Holder{}
		statusFX.pcs[id] = h
	}
	h.Put(rec)
	statusFX.mu.Unlock()
	t.Cleanup(func() {
		statusFX.mu.Lock()
		delete(statusFX.pcs, id)
		statusFX.mu.Unlock()
	})
}

// What the curses do to a character's numbers.
func TestCursesOnACharacter(t *testing.T) {
	const id = 881010
	if applyPlayerTaken(id, true, 1000) != 1000 || applyBuffDamage(id, false, 1000) != 1000 || attackRateStat(id, 200) != 200 {
		t.Fatal("an unafflicted character's numbers moved")
	}
	// Dissociation 30: every blow taken x 1.3.
	put881(t, id, statuseffect.Run{Code: "csit", Values: []int{15000, 30, 10, 30}})
	if got := applyPlayerTaken(id, true, 1000); got != 1300 {
		t.Errorf("a 1000 blow on a dissociated character: %d; want 1300", got)
	}
	if got := applyPlayerTaken(id, false, 1001); got != 1301 {
		t.Errorf("a physical 1001: %d; want ftol(1301.3)", got)
	}
	// Powerless 20: every blow dealt x 0.8.
	put881(t, id, statuseffect.Run{Code: "cssr", Values: []int{15000, 20, 10, 20}})
	if got := applyBuffDamage(id, false, 1000); got != 800 {
		t.Errorf("a powerless character's 1000 blow: %d; want 800", got)
	}
	// Darkness 30: the attack rate x 0.7.
	put881(t, id, statuseffect.Run{Code: "dn", Values: []int{15000, 30, 10, 30}})
	if got := attackRateStat(id, 200); got != 140 {
		t.Errorf("a darkened attack rate of 200: %v; want 140", got)
	}
	// Disease 40 is the target's param 169.
	put881(t, id, statuseffect.Run{Code: "ds", Values: []int{15000, 30, 8, 40}})
	if got := statusTargetOf(context.Background(), id, 110, nil, nil).Disease; got != 40 {
		t.Errorf("the diseased target's param 169: %d; want 40", got)
	}
	// Combustion 30 / 50 / 5: the max MP x 0.7, MP recovered x 0.5; panic
	// 40 / 50 / 5 the same on HP.
	put881(t, id, statuseffect.Run{Code: "csmp", Values: []int{15000, 100, 6, 30, 50, 5}})
	put881(t, id, statuseffect.Run{Code: "cshp", Values: []int{20000, 80, 12, 40, 50, 5}})
	b := liveBonus(id)
	if b.HPScale != 60 || b.MPScale != 70 {
		t.Errorf("the max scales: HP %v %%, MP %v %%; want 60 and 70", b.HPScale, b.MPScale)
	}
	if got := statusFX.recovered(id, 1325, false); got != 662 {
		t.Errorf("1325 HP recovered under a panic: %d; want 662", got)
	}
	if got := statusFX.recovered(id, 500, true); got != 250 {
		t.Errorf("500 MP recovered under a combustion: %d; want 250", got)
	}
}
