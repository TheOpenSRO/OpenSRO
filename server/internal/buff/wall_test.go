package buff

import (
	"testing"
	"time"
)

// Round 640: the protection walls and the toggles, on the book alone. The
// numbers are Fire Wall - Tower lv1 (SKILL_CH_FIRE_HWABYEOK_A_01, id 136):
// 'onff' 5000,58 and 'pw' 11,1159,0,17, and Crystal Wall lv1
// (SKILL_CH_COLD_BINGBYEOK_A_01, id 99): 'onff' 5000,41, 'pw' 7,824,0,11 --
// MEASURED on the RE box's export; the rest of each spec is SYNTHETIC.

func fireWallSpec(caster int64) Spec {
	return Spec{SkillID: 136, GroupID: 283, Level: 1, CasterID: caster, ActionOverlap: 11, Activity: 2,
		HasOnff: true, OnffMs: 5000, OnffMP: 58,
		HasWall: true, Wall: Wall{Mask: 11, HP: 1159, Def: 0, DefPct: 17}}
}

func coldWallSpec(caster int64) Spec {
	return Spec{SkillID: 99, GroupID: 246, Level: 1, CasterID: caster, ActionOverlap: 11, Activity: 2,
		HasOnff: true, OnffMs: 5000, OnffMP: 41,
		HasWall: true, Wall: Wall{Mask: 7, HP: 824, Def: 0, DefPct: 11}}
}

// The absorb test of Combat_ResolveDamage (0x58f03e..0x58f0a6): a wall takes
// a blow whose every type bit it carries. Fire Wall (11 = 1|2|8) takes the
// magical monster skills (att 9, 10) and not the physical ones (5, 6);
// Crystal Wall (7 = 1|2|4) the other way round.
func TestWallAbsorbsTheTypesItCovers(t *testing.T) {
	for _, c := range []struct {
		mask, att uint32
		want      bool
	}{
		{11, 5, false}, {11, 6, false}, {11, 9, true}, {11, 10, true},
		{7, 5, true}, {7, 6, true}, {7, 9, false}, {7, 10, false},
		{11, 0, true}, {7, 0, true}, // no 'att' passes both clauses
	} {
		if got := WallAbsorbs(c.mask, c.att); got != c.want {
			t.Errorf("WallAbsorbs(pw %d, att %d) = %v, want %v", c.mask, c.att, got, c.want)
		}
	}
}

// A wall takes the blow off its own HP -- 1159 for Fire Wall lv1 -- clamped at
// 0 (Combat_ApplyActionEffects' wall branch), and the blow that takes it to 0
// or below is the break (the entry's 0x80); a blow of a type it does not
// cover leaves it untouched.
func TestHitWallTakesDamageOffItsHP(t *testing.T) {
	b := NewBooks(50)
	now := time.Unix(1000, 0)
	rec, _, ref, _ := b.Start(7, fireWallSpec(7), now)
	if ref != NotRefused || !rec.HasWall || rec.WallHP != 1159 {
		t.Fatalf("start: %+v %v", rec, ref)
	}
	if _, ok := b.HitWall(7, TypePhysical, func(Wall) int { return 100 }); ok {
		t.Fatal("a physical blow met Fire Wall")
	}
	var seen Wall
	hit, ok := b.HitWall(7, TypeMagical, func(w Wall) int { seen = w; return 400 })
	if !ok || hit.Damage != 400 || hit.HP != 759 || hit.Max != 1159 || hit.Broke {
		t.Fatalf("the first magical blow: %+v %v", hit, ok)
	}
	if seen.Def != 0 || seen.DefPct != 17 {
		t.Fatalf("the blow was resolved against %+v, want the wall's own defence 0 / 17%%", seen)
	}
	hit, ok = b.HitWall(7, TypeMagical, func(Wall) int { return 759 })
	if !ok || hit.HP != 0 || !hit.Broke {
		t.Fatalf("the breaking blow: %+v %v", hit, ok)
	}
	if _, ok := b.HitWall(7, TypeMagical, func(Wall) int { return 1 }); ok {
		t.Fatal("a broken wall absorbed another blow")
	}
	if ended, _ := b.EndBrokenWalls(7, time.Now().Add(-BrokenGrace)); len(ended) != 0 {
		t.Fatal("the ticker's cutoff ended a wall broken just now (the strike's report must go first)")
	}
	if due := b.DueToggles(time.Unix(1001, 0)); len(due) != 0 { // no drain due yet at 1 s
		t.Fatalf("a wall broken just now is due to the ticker: %v", due)
	}
	ended, _ := b.EndBrokenWalls(7, time.Now())
	if len(ended) != 1 || ended[0].Token != rec.Token {
		t.Fatalf("EndBrokenWalls: %+v", ended)
	}
	if len(b.Active(7)) != 0 {
		t.Fatal("the wall outlived its end")
	}
}

// An overflowing blow empties the wall and no more: the clamp `if (HP < dmg)
// HP = 0`.
func TestHitWallClampsAtZero(t *testing.T) {
	b := NewBooks(50)
	b.Start(7, coldWallSpec(7), time.Unix(1000, 0))
	hit, ok := b.HitWall(7, TypePhysical, func(Wall) int { return 5000 })
	if !ok || hit.HP != 0 || !hit.Broke || hit.Damage != 5000 {
		t.Fatalf("%+v %v", hit, ok)
	}
}

// Any end of a 'pw' record empties book+0x1dc (SkillAction_BuffEnd), and a
// cancel is one.
func TestWallHolderClearsOnCancel(t *testing.T) {
	b := NewBooks(50)
	b.Start(7, fireWallSpec(7), time.Unix(1000, 0))
	if _, res, _ := b.Cancel(7, 136, 0); res != Cancelled {
		t.Fatalf("cancel: %v", res)
	}
	if _, ok := b.HitWall(7, TypeMagical, func(Wall) int { return 1 }); ok {
		t.Fatal("a cancelled wall still absorbs")
	}
}

// The drain is due only when MORE than onff[0] ms have passed since the last
// (`cmp eax,[onff]; jbe`, 0x585268): at exactly 5000 ms it is not.
func TestDrainDueIsStrictlyAfterTheInterval(t *testing.T) {
	b := NewBooks(50)
	start := time.Unix(1000, 0)
	rec, _, _, _ := b.Start(7, fireWallSpec(7), start)
	if rec.DrainDue(start.Add(5000 * time.Millisecond)) {
		t.Fatal("due at exactly 5000 ms")
	}
	if !rec.DrainDue(start.Add(5001 * time.Millisecond)) {
		t.Fatal("not due at 5001 ms")
	}
	if got := b.DueDrains(7, start.Add(5001*time.Millisecond)); len(got) != 1 {
		t.Fatalf("DueDrains: %d records", len(got))
	}
	b.Drained(7, rec.Token, start.Add(5001*time.Millisecond))
	if got := b.DueDrains(7, start.Add(10001*time.Millisecond)); len(got) != 0 {
		t.Fatal("due again before a second interval passed")
	}
	if got := b.DueDrains(7, start.Add(10002*time.Millisecond)); len(got) != 1 {
		t.Fatal("not due after a second interval")
	}
}

// Only a toggle its owner cast and with no 'dura' drains (0x58522e..0x585242).
func TestDrainAppliesOnlyToAnOwnUntimedToggle(t *testing.T) {
	b := NewBooks(50)
	start := time.Unix(1000, 0)
	s := fireWallSpec(9) // cast by someone else
	rec, _, _, _ := b.Start(7, s, start)
	if rec.DrainDue(start.Add(time.Hour)) {
		t.Fatal("a toggle cast by another character drains its owner")
	}
	s = fireWallSpec(8)
	s.DuraMs = 60000
	rec, _, _, _ = b.Start(8, s, start)
	if rec.DrainDue(start.Add(30 * time.Second)) {
		t.Fatal("a toggle with a 'dura' drains")
	}
}

// Recasting a running toggle ends it (Tick_UseSkill's phase 0): the first
// record of the skill, when the owner cast it; a record cast by someone else
// is left for the cast to go ahead.
func TestToggleOffEndsTheOwnersOwnRecord(t *testing.T) {
	b := NewBooks(50)
	now := time.Unix(1000, 0)
	rec, _, _, _ := b.Start(7, fireWallSpec(7), now)
	got, _, ok := b.ToggleOff(7, 136)
	if !ok || got.Token != rec.Token {
		t.Fatalf("ToggleOff: %+v %v", got, ok)
	}
	if len(b.Active(7)) != 0 {
		t.Fatal("the toggle is still active")
	}
	if _, _, ok := b.ToggleOff(7, 136); ok {
		t.Fatal("a toggle-off with nothing running")
	}
	b.Start(8, fireWallSpec(9), now)
	if _, _, ok := b.ToggleOff(8, 136); ok {
		t.Fatal("toggled off a record another character cast")
	}
}

// The wall rows share state byte 11: a second wall of the other element is
// refused 0x300c while one stands (the recast rule's bit test), and the same
// wall's recast is a toggle-off before the rule is ever reached.
func TestASecondWallIsRefusedByTheStateByte(t *testing.T) {
	b := NewBooks(50)
	now := time.Unix(1000, 0)
	b.Start(7, fireWallSpec(7), now)
	if r := b.CheckOverlap(7, coldWallSpec(7)); r != RefusedOverlap {
		t.Fatalf("Crystal Wall over Fire Wall: %v, want RefusedOverlap", r)
	}
}

// Round 640's review: the wall's damage is accumulated before the absorb
// test (0x58f00b / 0x58f015 precede 0x58f03e). A blow sharing no type with
// the wall never asks for its damage; a mixed 4|8 blow on a one-type wall
// costs the wall the shared half and is not absorbed.
func TestTheWallIsChargedBeforeTheAbsorbTest(t *testing.T) {
	b := NewBooks(50)
	b.Start(7, fireWallSpec(7), time.Unix(1000, 0))
	asked := false
	if _, ok := b.HitWall(7, TypePhysical, func(Wall) int { asked = true; return 100 }); ok || asked {
		t.Fatalf("a physical blow on Fire Wall: touched %v, damage asked %v", ok, asked)
	}
	hit, ok := b.HitWall(7, TypePhysical|TypeMagical, func(Wall) int { return 100 })
	if !ok || hit.Absorbed || hit.Damage != 100 || hit.HP != 1059 {
		t.Fatalf("a mixed blow on Fire Wall: %+v %v, want the wall charged 100 and nothing absorbed", hit, ok)
	}
	hit, ok = b.HitWall(7, 0, func(Wall) int { return 100 })
	if !ok || !hit.Absorbed || hit.Damage != 0 || hit.HP != 1059 {
		t.Fatalf("a blow with no 'att' type: %+v %v, want absorbed at no cost to the wall (both twins return 0)", hit, ok)
	}
}
