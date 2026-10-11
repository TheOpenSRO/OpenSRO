package alchemy

import (
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/magicopt"
)

// script is a rand() that answers from a list, failing the test when a draw
// is out of the range asked for or the list runs out.
type script struct {
	t    *testing.T
	vals []int
}

func (s *script) Intn(n int) int {
	s.t.Helper()
	if len(s.vals) == 0 {
		s.t.Fatalf("rand(): no scripted value left for Intn(%d)", n)
	}
	v := s.vals[0]
	s.vals = s.vals[1:]
	if v < 0 || v >= n {
		s.t.Fatalf("rand(): scripted %d is outside Intn(%d)", v, n)
	}
	return v
}

func (s *script) done() {
	s.t.Helper()
	if len(s.vals) != 0 {
		s.t.Errorf("rand(): %d scripted values never drawn: %v", len(s.vals), s.vals)
	}
}

func roll(t *testing.T, v ...int) *script { return &script{t: t, vals: v} }

// A small table in the retail file's shape (values MEASURED where the row
// is named: STR level 1 {1,2,3}, DEC_MAXDUR level 3 36..50).
func testTable() *magicopt.Table {
	row := func(id uint16, code string, level int, tag string, p8, p9, p10 uint32, kinds string) *magicopt.Row {
		r := &magicopt.Row{ID: id, Code: code, Level: level, Prob: 1, Tag: magicopt.PackTag(tag), Params: [4]uint32{p8, p9, p10, 0}}
		for _, k := range strings.Split(kinds, "|") {
			t, _ := magicopt.LoadCSV(strings.NewReader("1,X,1,1,1,0,0,0,0," + k + "\n"))
			r.Kinds = append(r.Kinds, t.ByID(1).Kinds...)
		}
		return r
	}
	return magicopt.New([]*magicopt.Row{
		row(10, "MATTR_STR", 1, "str", 0x00010002, 0x00030000, 0, "weapon|armor|shield|accessory"),
		row(11, "MATTR_STR", 2, "str", 0x00010002, 0x00030004, 0, "weapon|armor|shield|accessory"),
		row(20, "MATTR_DEC_MAXDUR", 3, "dura", 0, 36, 50, "weapon|armor|shield"),
		row(30, "MATTR_ATHANASIA", 1, "atha", 0x00010002, 0x00030004, 0x00050006, "weapon|armor|shield|accessory"),
		row(31, "MATTR_ASTRAL", 1, "astr", 0x00010002, 0x00030004, 0x00050006, "weapon|armor|shield|accessory"),
		row(32, "MATTR_LUCK", 1, "luck", 0x00010002, 0x00030004, 0x00050006, "weapon|armor|shield|accessory"),
		row(33, "MATTR_REPAIR", 1, "rep", 0x00010002, 0, 0, "weapon"),
		row(40, "MATTR_BLOCKRATE", 1, "bri", 0x00010002, 0, 0, "shield"),
	})
}

// A degree-1 sword (ItemClass 1 -> degree 1), nine options at most.
func sword(plus int) *Target {
	return &Target{TypeID3: 6, TypeID4: 2, ItemClass: 1, MaxOptions: 9, OptLevel: plus, Durability: 40}
}

var weaponElixir = [3]uint32{0x19140F0A, 0x0A0A0A0A, 0x0A050505} // MEASURED, WEAPON_A

func TestReinforceSuccessRaisesThePlusByOne(t *testing.T) {
	tg := sword(3)
	r := roll(t, 9) // +3 reads 10 %: 9 < 10 wins
	res := Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if !res.Success || res.Rate != 10 || tg.OptLevel != 4 {
		t.Fatalf("got %+v plus %d, want success at 10%% to +4", res, tg.OptLevel)
	}
}

func TestReinforceFailureBelowFiveOnlyResetsThePlus(t *testing.T) {
	tg := sword(3)
	r := roll(t, 10) // 10 is not < 10: lost; n < 5 draws nothing more
	res := Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if res.Success || res.Destroyed || tg.OptLevel != 0 {
		t.Fatalf("got %+v plus %d, want a failure back to +0", res, tg.OptLevel)
	}
}

func TestReinforceAstralKeepsPlusFour(t *testing.T) {
	tg := sword(4)
	tg.Options = []Option{{ID: 31, Tag: TagAstral, Value: 2}}
	r := roll(t, 99)
	Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if tg.OptLevel != 4 || tg.Options[0].Value != 1 {
		t.Fatalf("plus %d options %+v, want +4 and one Astral charge spent", tg.OptLevel, tg.Options)
	}
}

func TestReinforceFromFiveDestroysHalfTheTime(t *testing.T) {
	tg := sword(6)
	r := roll(t, 99, 49) // lost, then the 50 % branch
	res := Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if !res.Destroyed {
		t.Fatalf("got %+v, want the item destroyed", res)
	}

	// A cash item is never destroyed: the same draws only cost the plus.
	tg = sword(6)
	tg.Cash = true
	r = roll(t, 99, 49)
	res = Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if res.Destroyed || tg.OptLevel != 0 || len(tg.Options) != 0 {
		t.Fatalf("cash: got %+v plus %d options %+v, want survival at +0, no flaw", res, tg.OptLevel, tg.Options)
	}

	// Immortal spends a charge instead.
	tg = sword(6)
	tg.Options = []Option{{ID: 30, Tag: combat.PackTag("atha"), Value: 1}}
	r = roll(t, 99, 0)
	res = Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if res.Destroyed || len(tg.Options) != 0 || tg.OptLevel != 0 {
		t.Fatalf("immortal: got %+v plus %d options %+v, want survival at +0 and the charge gone", res, tg.OptLevel, tg.Options)
	}
}

func TestReinforceFlawAddsDecMaxDurFromLevelThree(t *testing.T) {
	tg := sword(5)
	// lost, the other 50 %, then the range draw: 32767 -> 50 (the level-3 max)
	r := roll(t, 99, 50, durability.RandMax)
	res := Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if res.Destroyed || tg.OptLevel != 0 {
		t.Fatalf("got %+v plus %d", res, tg.OptLevel)
	}
	if len(tg.Options) != 1 || tg.Options[0].Tag != TagDecDur || tg.Options[0].Value != 50 || tg.Options[0].ID != 20 {
		t.Fatalf("options %+v, want one MATTR_DEC_MAXDUR (id 20) of 50", tg.Options)
	}
	// A second flaw adds to the first and clamps at 99.
	tg.OptLevel = 5
	r = roll(t, 99, 50, durability.RandMax)
	Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if len(tg.Options) != 1 || tg.Options[0].Value != 99 {
		t.Fatalf("options %+v, want the flaw clamped to 99", tg.Options)
	}
	// Steady spends a charge instead.
	tg = sword(5)
	tg.Options = []Option{{Tag: TagSolid, Value: 2}}
	r = roll(t, 99, 50)
	Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if len(tg.Options) != 1 || tg.Options[0].Value != 1 {
		t.Fatalf("steady: options %+v, want no flaw and one charge spent", tg.Options)
	}
}

// The MEASURED lucky powder table (PROB_UP_A_02..12): +1..+4 100, 100, 100,
// 80. With the weapon elixir's 25 at +0 a powder makes the attempt certain.
func TestThePowderAddsItsOwnTable(t *testing.T) {
	powder := [3]uint32{0x64646450, 0x41321e13, 0x0a040201}
	if got := ReinforceRate(sword(0), weaponElixir, &powder, 0); got != MaxRate {
		t.Errorf("+0 with powder: %d, want 100", got)
	}
	if got := ReinforceRate(sword(8), weaponElixir, &powder, 0); got != 10+10 {
		t.Errorf("+8 with powder: %d, want 20 (10 + 10)", got)
	}
}

func stone(code string, degree int) Stone {
	return Stone{Param1: degree, Rate: 50, Desc1: code}
}

func TestMagicStoneRollAndRefusals(t *testing.T) {
	tbl := testTable()
	// The stones' roll fails iff rate < rand()%100: 50 wins, 51 loses.
	r := roll(t, 51)
	if got := MagicStone(sword(0), stone("MATTR_STR", 1), 0, tbl, r); got.Code != ErrEnchantFailed {
		t.Errorf("roll 51 against 50: %+v, want 0x5423", got)
	}
	r.done()
	for _, c := range []struct {
		name string
		s    Stone
		tg   *Target
		want int
	}{
		{"no such option in the table", stone("MATTR_NOPE", 1), sword(0), NothingWritten},
		{"the wrong degree", stone("MATTR_STR", 2), sword(0), ErrTargetCannotBeReinforced},
		{"not allowed on a weapon", stone("MATTR_BLOCKRATE", 1), sword(0), ErrRecipeMismatch},
		{"no record for the degree", stone("MATTR_STR", 3), &Target{TypeID3: 6, ItemClass: 7, MaxOptions: 9}, ErrRecipeMismatch},
		{"repair needs an existing option", stone("MATTR_REPAIR", 1), sword(0), ErrHonorItem},
		{"astral needs more immortal", stone("MATTR_ASTRAL", 1), sword(0), ErrAstralAlt},
	} {
		r := roll(t, 50)
		if got := MagicStone(c.tg, c.s, 0, tbl, r); got.Code != c.want {
			t.Errorf("%s: code %#x, want %#x", c.name, got.Code, c.want)
		}
		r.done()
	}
}

func TestMagicStoneWritesAFreshValue(t *testing.T) {
	tbl := testTable()
	tg := sword(0)
	r := roll(t, 0, 2) // win; then the third of {1, 2, 3}
	res := MagicStone(tg, stone("MATTR_STR", 1), 0, tbl, r)
	r.done()
	if res.Code != Success || len(tg.Options) != 1 || tg.Options[0] != (Option{ID: 10, Tag: combat.PackTag("str"), Value: 3}) {
		t.Fatalf("got %+v options %+v, want STR 3 (id 10)", res, tg.Options)
	}
	// A second STR stone overwrites in place, and may go down.
	r = roll(t, 0, 0)
	res = MagicStone(tg, stone("MATTR_STR", 1), 0, tbl, r)
	r.done()
	if len(tg.Options) != 1 || tg.Options[0].Value != 1 || res.Before != 3 || res.After != 1 {
		t.Fatalf("got %+v options %+v, want STR overwritten 3 -> 1", res, tg.Options)
	}
	// With the item full, a new option is not written (2).
	full := sword(0)
	full.MaxOptions = 1
	full.Options = []Option{{ID: 40, Tag: combat.PackTag("bri"), Value: 1}}
	r = roll(t, 0, 0)
	if got := MagicStone(full, stone("MATTR_STR", 1), 0, tbl, r); got.Code != NothingWritten || len(full.Options) != 1 {
		t.Fatalf("full: %+v options %+v, want 2 and nothing added", got, full.Options)
	}
	r.done()
}

func TestBlessStonesCountCharges(t *testing.T) {
	tbl := testTable()
	tg := sword(0)
	for i := 1; i <= 5; i++ {
		r := roll(t, 0)
		if got := MagicStone(tg, stone("MATTR_ATHANASIA", 1), 0, tbl, r); got.Code != Success {
			t.Fatalf("immortal %d: %+v", i, got)
		}
		r.done()
	}
	if tg.Options[0].Value != 5 {
		t.Fatalf("five Immortal stones: %+v, want 5 charges", tg.Options)
	}
	r := roll(t, 0)
	if got := MagicStone(tg, stone("MATTR_ATHANASIA", 1), 0, tbl, r); got.Code != ErrMagicStone2Max {
		t.Fatalf("a sixth: %+v, want 0x5422", got)
	}
	r.done()
	// Astral now passes: 5 Immortal > 0 Astral.
	r = roll(t, 0)
	if got := MagicStone(tg, stone("MATTR_ASTRAL", 1), 0, tbl, r); got.Code != Success {
		t.Fatalf("astral: %+v", got)
	}
	r.done()
}

func TestAttrStoneSetsItsGroup(t *testing.T) {
	tg := sword(0)
	s := Stone{Param1: 1, Rate: 50, Desc1: "NATTR_PA", Desc4: "weapon"}
	// Win, then four draws of rand()%6; the minimum 3 -> 63 % of 31 = 19.
	r := roll(t, 0, 5, 3, 4, 5)
	res := AttrStone(tg, s, 0, testTable(), r)
	r.done()
	if res.Code != Success || durability.Group(tg.Variance, durability.WeaponPhysDamageGroup) != 19 {
		t.Fatalf("got %+v variance %#x, want PA (group 4) = 19", res, tg.Variance)
	}
	// The wrong class or degree refuses before the roll.
	for _, bad := range []Stone{{Param1: 1, Rate: 50, Desc1: "NATTR_PA", Desc4: "armor,shield"}, {Param1: 2, Rate: 50, Desc1: "NATTR_PA", Desc4: "weapon"}} {
		if got := AttrStone(sword(0), bad, 0, testTable(), roll(t)); got.Code != ErrEnchantEquipClassMismatch {
			t.Errorf("%+v: code %#x, want 0x5421", bad, got.Code)
		}
	}
}

func TestWhiteValuesAreTheBinarysTable(t *testing.T) {
	want := []int{0, 7, 13, 19, 25, 31}
	for k, w := range want {
		if got := whitePct[k] * durability.GroupMax / 100; got != w {
			t.Errorf("k %d: %d, want %d", k, got, w)
		}
	}
}

func TestApeAbsorbsTheAssimilation(t *testing.T) {
	tg := sword(0)
	tg.Options = []Option{{Tag: TagApe, Value: 1}}
	s := stone("MATTR_STR", 1)
	s.Assimilation = 100
	r := roll(t, 0, 0, 0) // win, STR 1, then rand()%101 = 0 < 100
	res := MagicStone(tg, s, 0, testTable(), r)
	r.done()
	if res.Assimilated != Protected || tg.Find(TagApe) >= 0 {
		t.Fatalf("got %+v options %+v, want the ape charge spent instead", res, tg.Options)
	}
}

func TestMaxDurabilityOptions(t *testing.T) {
	opts := []Option{{Tag: TagDur, Value: 20}, {Tag: TagDecDur, Value: 50}}
	if got := MaxDurability(100, opts, nil); got != 70 {
		t.Errorf("+20 %% -50 %%: %d, want 70", got)
	}
	if got := MaxDurability(1, []Option{{Tag: TagDecDur, Value: 99}}, nil); got != 1 {
		t.Errorf("a result of 0 becomes 1: got %d", got)
	}
	if got := MaxDurability(80, nil, nil); got != 80 {
		t.Errorf("no options: %d", got)
	}
}

func TestClassOfAndAttrGroups(t *testing.T) {
	if ClassOf(6) != ClassWeapon || ClassOf(4) != ClassShield || ClassOf(10) != ClassArmour || ClassOf(12) != ClassAccessory || ClassOf(7) != ClassNone {
		t.Error("ClassOf")
	}
	if AttrGroup(ClassShield, "NATTR_BR") != durability.ShieldBlockGroup || AttrGroup(ClassArmour, "NATTR_ER") != durability.ArmourParryGroup ||
		AttrGroup(ClassWeapon, "NATTR_CRITICAL") != durability.WeaponCriticalGroup {
		t.Error("the NATTR lists do not land on durability's groups")
	}
	if !AttrStoneSuits("armor,shield", ClassShield) || AttrStoneSuits("armor", ClassShield) {
		t.Error("AttrStoneSuits")
	}
}

// Review F1: an overwritten option keeps its own id -- a STR option of
// another level, overwritten by a degree-1 stone, stays that level's row.
func TestOverwriteKeepsTheOptionsID(t *testing.T) {
	tg := sword(0)
	tg.Options = []Option{{ID: 11, Tag: combat.PackTag("str"), Value: 4}}
	r := roll(t, 0, 0)
	if res := MagicStone(tg, stone("MATTR_STR", 1), 0, testTable(), r); res.Code != Success {
		t.Fatalf("%+v", res)
	}
	r.done()
	if tg.Options[0].ID != 11 || tg.Options[0].Value != 1 {
		t.Fatalf("options %+v, want id 11 kept with the new value 1", tg.Options)
	}
	// The flaw too: an existing 'dura' keeps its id.
	tg = sword(5)
	tg.Options = []Option{{ID: 99, Tag: TagDecDur, Value: 10}}
	r = roll(t, 99, 50, 0)
	Reinforce(tg, weaponElixir, nil, 0, testTable(), r)
	r.done()
	if tg.Options[0].ID != 99 || tg.Options[0].Value != 46 {
		t.Fatalf("options %+v, want id 99 kept and 10 + 36", tg.Options)
	}
}

// The assimilation step's two branches (slots 10/11).
func TestAssimilationBranches(t *testing.T) {
	tbl := testTable()
	// White: a magic stone on an item with no options -- every draw is white.
	tg := sword(0)
	s := stone("MATTR_STR", 1)
	s.Assimilation = 100
	// win, STR value, assimilate (0 < 100), k = 4 of 7+1, then four draws -> 5 -> 31
	r := roll(t, 0, 0, 0, 4, 5, 5, 5, 5)
	res := MagicStone(tg, s, 0, tbl, r)
	r.done()
	if res.Assimilated != 4 || durability.Group(tg.Variance, 4) != 31 {
		t.Fatalf("white: %+v variance %#x, want group 4 re-rolled to 31", res, tg.Variance)
	}
	// Blue: an attribute stone's draw past the white groups re-rolls that
	// option from its own record.
	tg = sword(0)
	tg.Options = []Option{{ID: 10, Tag: combat.PackTag("str"), Value: 1}}
	a := Stone{Param1: 1, Rate: 50, Desc1: "NATTR_PA", Desc4: "weapon", Assimilation: 100}
	// win, four draws for PA, assimilate, k = 7 (blue 0), the new value: the third of {1,2,3}
	r = roll(t, 0, 0, 0, 0, 0, 0, 7, 2)
	res = AttrStone(tg, a, 0, tbl, r)
	r.done()
	if res.Assimilated != 7 || tg.Options[0].Value != 3 {
		t.Fatalf("blue: %+v options %+v, want option 0 re-rolled to 3", res, tg.Options)
	}
	// Review F2: at the cap the blue re-roll is refused for both stones.
	tg.MaxOptions = 1
	r = roll(t, 0, 0, 0, 0, 0, 0, 7)
	res = AttrStone(tg, a, 0, tbl, r)
	r.done()
	if res.Assimilated != -1 || tg.Options[0].Value != 3 {
		t.Fatalf("capped: %+v options %+v, want nothing re-rolled", res, tg.Options)
	}
}
