package session

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// Round 882: a skill's required gear after the cast (gearreqs.go). The rows
// and items are SYNTHETIC, shaped like the table's: a weapon passive `defp
// 224 0 0; reqi 6 7`, a set passive `defp 168 0 0; reqi 10 0; reqi 6 15;
// reqn`, a passive variable `setv E1SA 4; reqi 6 7`, a buff asking for any of
// three weapons, a buff asking for one.

// wornEq882 is a worn set a test changes in place.
type wornEq882 struct {
	mu   sync.Mutex
	worn map[equipment.Slot]equipment.Equipped
}

func (w *wornEq882) Get(context.Context, int64) ([]equipment.Equipped, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]equipment.Equipped, 0, len(w.worn))
	for _, s := range []equipment.Slot{0, 1, 2, 3, 4, 5, 6, 7} {
		if e, ok := w.worn[s]; ok {
			out = append(out, e)
		}
	}
	return out, nil
}
func (w *wornEq882) Equip(context.Context, int64, equipment.Slot, int) error { return nil }
func (w *wornEq882) Unequip(context.Context, int64, equipment.Slot) error    { return nil }
func (w *wornEq882) SetDurability(_ context.Context, _ int64, s equipment.Slot, d int) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.worn[s]
	e.Durability = d
	w.worn[s] = e
	return nil
}

// put wears item (0 takes the slot's item off).
func (w *wornEq882) put(s equipment.Slot, item int64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if item == 0 {
		delete(w.worn, s)
		return
	}
	w.worn[s] = equipment.Equipped{Slot: s, ItemID: item, Durability: 50}
}

// The synthetic items: a weapon of TypeID4 n is 88200+n, a shield 88230, a
// body piece of kind k for part p (1..6) is 88300 + 10k + p.
func weapon882(n int) int64      { return int64(88200 + n) }
func piece882(kind, p int) int64 { return int64(88300 + 10*kind + p) }

func items882() stubCombatItems {
	items := stubCombatItems{88230: {ID: 88230, TypeID3: 4, TypeID4: 2}}
	for n := 2; n <= 15; n++ {
		items[weapon882(n)] = &refdata.Item{ID: weapon882(n), TypeID3: 6, TypeID4: n}
	}
	for _, k := range []int{9, 10, 11} {
		for p := 1; p <= 6; p++ {
			items[piece882(k, p)] = &refdata.Item{ID: piece882(k, p), TypeID3: k, TypeID4: p}
		}
	}
	return items
}

// wearSet882 puts a whole body set of kind on (the part order of the
// engine's table: head, shoulder, chest, legs, hands, feet).
func wearSet882(w *wornEq882, kind int) {
	for p := 1; p <= 6; p++ {
		w.put(armourPartSlots[p], piece882(kind, p))
	}
}

func TestGearListWalk882(t *testing.T) {
	parse := combat.ParseCastRequirements
	set := func(kind int, weapon int) gearState {
		var w []wornKind
		for p := 1; p <= 6; p++ {
			w = append(w, wornKind{slot: armourPartSlots[p], typeID3: kind, typeID4: p})
		}
		if weapon != 0 {
			w = append(w, wornKind{slot: equipment.SlotWeapon, typeID3: 6, typeID4: weapon})
		}
		return gearOf(w...)
	}
	mixed := set(10, 15)
	mixed.worn[2].typeID3 = 11 // the chest piece is another kind
	short := set(10, 15)
	short.worn = short.worn[1:] // no head piece
	shield := gearOf(wornKind{slot: equipment.SlotWeapon, typeID3: 6, typeID4: 7}, wornKind{slot: equipment.SlotShield, typeID3: 4, typeID4: 2})
	spirit := gearState{known: true, spirit: true}
	cases := []struct {
		name   string
		packed string
		all    bool
		g      gearState
		want   bool
	}{
		{"the weapon", "6:7", false, shield, true},
		{"another weapon", "6:8", false, shield, false},
		{"no weapon", "6:7", false, gearOf(), false},
		{"any of three weapons, the second", "6:7;6:8;6:9", false, set(9, 8), true},
		{"any of three weapons, none", "6:7;6:8;6:9", false, set(9, 15), false},
		{"the shield", "4:2", false, shield, true},
		{"another shield", "4:1", false, shield, false},
		{"a weapon or a shield, the shield", "6:4;6:5;4:2", false, shield, true},
		{"a whole set and the rod", "10:0;6:15", true, set(10, 15), true},
		{"a whole set, another weapon", "10:0;6:15", true, set(10, 8), false},
		{"the rod, a set of another kind", "10:0;6:15", true, set(9, 15), false},
		{"one piece of another kind", "10:0;6:15", true, mixed, false},
		{"a piece missing", "10:0;6:15", true, short, false},
		// A value N reads the part at index N and compares its TypeID4 only.
		{"armour part 3, the chest", "10:3", false, set(10, 0), true},
		{"armour part 3, another kind's chest", "10:3", false, set(9, 0), true},
		{"armour part 7", "10:7", false, set(10, 0), false},
		{"kind 14 with the spirit", "14:1", false, spirit, true},
		{"kind 14 without", "14:1", false, gearOf(), false},
		// Five filled entries that all hold: the engine's loop leaves with
		// the answer cleared.
		{"all of five", "6:7;4:2;6:7;4:2;6:7", true, shield, false},
		{"all of four", "6:7;4:2;6:7;4:2", true, shield, true},
		{"no list", "", true, gearOf(), true},
		// The worn items unreadable: an equipment entry holds, as before the
		// round; kind 14 is still asked.
		{"unknown gear", "6:7", false, gearState{}, true},
		{"unknown gear, kind 14", "14:1", false, gearState{}, false},
	}
	for _, c := range cases {
		if got := gearReqsHold(parse(c.packed), c.all, c.g); got != c.want {
			t.Errorf("%s (%q all=%v): %v, want %v", c.name, c.packed, c.all, got, c.want)
		}
	}
}

// fixture882 is a character with a changeable worn set, the three synthetic
// passives learned, and the gear source installed.
func fixture882(t *testing.T) (context.Context, int64, *wornEq882) {
	t.Helper()
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Geared")
	if err != nil {
		t.Fatal(err)
	}
	skills := skill.NewMemStore()
	ref := mapSkillRef{
		// defp 224 0 0; reqi 6 7
		882001: {ID: 882001, GroupID: 882001, BasicLevel: 18, ActionKind: 4,
			ParamWords: []int32{4, word881("defp"), 224, 0, 0, word881("reqi"), 6, 7}, ReqCastList: "6:7", ReqCastListCount: 1},
		// defp 168 0 0; reqi 10 0; reqi 6 15; reqn
		882002: {ID: 882002, GroupID: 882002, BasicLevel: 14, ActionKind: 4,
			ParamWords:  []int32{4, word881("defp"), 168, 0, 0, word881("reqi"), 10, 0, word881("reqi"), 6, 15, word881("reqn")},
			ReqCastList: "10:0;6:15", ReqCastListCount: 2, ReqCastAll: true},
		// setv E1SA 4; reqi 6 7
		882003: {ID: 882003, GroupID: 882003, BasicLevel: 1, ActionKind: 4,
			ParamWords: []int32{4, word881("setv"), word881("E1SA"), 4, word881("reqi"), 6, 7}, ReqCastList: "6:7", ReqCastListCount: 1},
		// a passive with no list: cr 11
		882004: {ID: 882004, GroupID: 882004, BasicLevel: 1, ActionKind: 4,
			ParamWords: []int32{4, word881("cr"), 11}},
	}
	for id := range ref {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	eq := &wornEq882{worn: map[equipment.Slot]equipment.Equipped{}}
	items := items882()
	passives.Lock()
	oldSkills, oldRef := passives.skills, passives.ref
	passives.skills, passives.ref = skills, ref
	passives.m = map[int64]passiveState{}
	passives.Unlock()
	SetGearRequirementSource(chars, eq, skills, items)
	t.Cleanup(func() {
		SetGearRequirementSource(nil, nil, nil, nil)
		passives.Lock()
		passives.skills, passives.ref = oldSkills, oldRef
		passives.m = map[int64]passiveState{}
		passives.Unlock()
		buffBooks.EndAll(c.ID)
		forgetRows(false, c.ID)
	})
	return ctx, c.ID, eq
}

// physDef882 is what the passives and buffs add to the physical defence.
func physDef882(id int64) float64 {
	t, _ := buffTotal(id, buff.ParamPhysDefFlat)
	return t.Flat
}

// MEASURED: bare-handed and with a cleric rod the panel reads the same; a
// one-handed sword adds the weapon passive's 224; a two-handed sword takes it
// off again; the set passive (a whole light-armour set AND a rod) adds
// nothing in a robe set with the rod.
func TestPassiveCountsOnlyWithItsGear882(t *testing.T) {
	ctx, id, eq := fixture882(t)
	wearSet882(eq, 9) // a robe set
	step := func(name string, weapon int, want float64, wantVar int) {
		t.Helper()
		if weapon == 0 {
			eq.put(equipment.SlotWeapon, 0)
		} else {
			eq.put(equipment.SlotWeapon, weapon882(weapon))
		}
		gearChanged(ctx, nil, id)
		if got := physDef882(id); got != want {
			t.Errorf("%s: the passives add %v to the phy def, want %v", name, got, want)
		}
		if got := passiveVar(id, "E1SA"); got != wantVar {
			t.Errorf("%s: the passive variable reads %d, want %d", name, got, wantVar)
		}
		// The passive with no list counts whatever is worn.
		if c, _ := buffTotal(id, buff.ParamCritical); c.Flat != 11 {
			t.Errorf("%s: the unlisted passive adds %v critical, want 11", name, c.Flat)
		}
	}
	step("bare-handed", 0, 0, 0)
	step("a cleric rod, a robe set", 15, 0, 0)
	step("a one-handed sword", 7, 224, 4)
	step("a two-handed sword", 8, 0, 0)
	step("the one-handed sword again", 7, 224, 4)
	// The light set: the set passive needs the rod as well.
	wearSet882(eq, 10)
	step("a light set, the one-handed sword", 7, 224, 4)
	step("a light set, the rod", 15, 168, 0)
	// One piece of the set taken off.
	eq.put(equipment.SlotBoots, 0)
	step("five light pieces, the rod", 15, 0, 0)
}

// A worn item at durability 0 answers no list (the getters' +0x190), and
// answers again once mended; a worn item that fails its own requirement
// still answers.
func TestBrokenAndHeldGearAndTheList882(t *testing.T) {
	ctx, id, eq := fixture882(t)
	eq.put(equipment.SlotWeapon, weapon882(7))
	gearChanged(ctx, nil, id)
	if got := physDef882(id); got != 224 {
		t.Fatalf("the sword worn: %v, want 224", got)
	}
	_ = eq.SetDurability(ctx, id, equipment.SlotWeapon, 0)
	gearChanged(ctx, nil, id)
	if got := physDef882(id); got != 0 {
		t.Errorf("the sword broken: %v, want 0", got)
	}
	_ = eq.SetDurability(ctx, id, equipment.SlotWeapon, 30)
	gearChanged(ctx, nil, id)
	if got := physDef882(id); got != 224 {
		t.Errorf("the sword mended: %v, want 224", got)
	}
	// Held (round 877): the sword counts for no stat, and still holds the
	// list.
	gearGate.Lock()
	gearGate.entries[id] = &gearEntry{held: map[equipment.Slot]int64{equipment.SlotWeapon: weapon882(7)}}
	gearGate.Unlock()
	gearChanged(ctx, nil, id)
	worn, _ := eq.Get(ctx, id)
	if n := len(gearCounted(ctx, id, worn)); n != 0 {
		t.Fatalf("the held sword still counts among %d items", n)
	}
	if got := physDef882(id); got != 224 {
		t.Errorf("the sword held by its own requirement: %v, want 224", got)
	}
}

// A passive set is counted over the gear worn at a world entry: no stale
// answer is kept from before.
func TestPassiveCountedAtEntry882(t *testing.T) {
	_, id, eq := fixture882(t)
	eq.put(equipment.SlotWeapon, weapon882(7))
	if got := physDef882(id); got != 224 { // first read, nothing cached
		t.Errorf("entered with the sword worn: %v, want 224", got)
	}
}

func startBuff882(t *testing.T, owner, caster int64, row *refdata.Skill) {
	t.Helper()
	rememberRow(false, owner, row)
	spec := buff.Spec{SkillID: row.ID, GroupID: row.ID, CasterID: caster, DuraMs: 900000, Activity: row.Activity}
	if _, _, refused, _ := buffBooks.Start(owner, spec, time.Now()); refused != buff.NotRefused {
		t.Fatalf("start %d refused: %v", row.ID, refused)
	}
}

func running882(owner int64) map[int64]bool {
	out := map[int64]bool{}
	for _, r := range buffBooks.Active(owner) {
		out[r.SkillID] = true
	}
	return out
}

// MEASURED: a buff asking for a two-handed sword ends at the swap to a
// one-handed one (its end 34 ms after the move's request); a buff asking for
// any of the three warrior weapons stays through the swap between two of
// them and ends at the swap to a cleric rod (96 ms after the request); a
// buff with no list, cast with the rod, stays through every swap.
func TestBuffEndsWhenItsGearGoes882(t *testing.T) {
	ctx, id, eq := fixture882(t)
	one := &refdata.Skill{ID: 882101, BasicCode: "SKILL_T882_ONE_01", Activity: 2, ReqCastList: "6:8"}
	any := &refdata.Skill{ID: 882102, BasicCode: "SKILL_T882_ANY_01", Activity: 2, ReqCastList: "6:7;6:8;6:9"}
	free := &refdata.Skill{ID: 882103, BasicCode: "SKILL_T882_FREE_01", Activity: 2}
	shield := &refdata.Skill{ID: 882104, BasicCode: "SKILL_CH_FIRE_SHIELD_T882_01", Activity: 2, ReqCastList: "6:8"}
	others := &refdata.Skill{ID: 882105, BasicCode: "SKILL_T882_OTHERS_01", Activity: 2, ReqCastList: "6:8"}

	eq.put(equipment.SlotWeapon, weapon882(8))
	startBuff882(t, id, id, one)
	startBuff882(t, id, id, any)
	startBuff882(t, id, id, free)
	startBuff882(t, id, id, shield)
	startBuff882(t, id, id+1, others) // cast by another character

	if n := gearChanged(ctx, nil, id); n != 0 {
		t.Fatalf("nothing changed, yet %d buffs ended", n)
	}
	eq.put(equipment.SlotWeapon, weapon882(7))
	if n := gearChanged(ctx, nil, id); n != 1 {
		t.Errorf("the swap to a one-handed sword ended %d buffs, want 1", n)
	}
	got := running882(id)
	if got[one.ID] || !got[any.ID] || !got[free.ID] || !got[shield.ID] || !got[others.ID] {
		t.Errorf("after the swap to a one-handed sword: %v", got)
	}
	eq.put(equipment.SlotWeapon, weapon882(15))
	if n := gearChanged(ctx, nil, id); n != 1 {
		t.Errorf("the swap to a rod ended %d buffs, want 1", n)
	}
	got = running882(id)
	if got[any.ID] || !got[free.ID] || !got[shield.ID] || !got[others.ID] {
		t.Errorf("after the swap to a rod: %v", got)
	}
	// The weapon taken off altogether changes nothing more: the list-free
	// buff, the fire shield and another's cast are never ended.
	eq.put(equipment.SlotWeapon, 0)
	if n := gearChanged(ctx, nil, id); n != 0 {
		t.Errorf("the weapon taken off ended %d buffs, want 0", n)
	}
}

// A buff whose weapon breaks ends (ChangeItemDurability's re-check).
func TestBuffEndsWhenItsWeaponBreaks882(t *testing.T) {
	ctx, id, eq := fixture882(t)
	row := &refdata.Skill{ID: 882201, BasicCode: "SKILL_T882_ONE_01", Activity: 2, ReqCastList: "6:8"}
	eq.put(equipment.SlotWeapon, weapon882(8))
	_ = eq.SetDurability(ctx, id, equipment.SlotWeapon, 1)
	startBuff882(t, id, id, row)
	if broke := wearOneSlot(ctx, eq, id, equipment.SlotWeapon); !broke {
		t.Fatal("the weapon did not break")
	}
	// The walk runs off the blow's stack (gearBroke).
	deadline := time.Now().Add(2 * time.Second)
	for running882(id)[row.ID] && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if running882(id)[row.ID] {
		t.Error("the buff outlived its broken weapon")
	}
}
