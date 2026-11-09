package gameworld

// Round 869 lane W3 (forgotten_world.md 11 SERVER item 1): the hole items'
// reading, the INS_GOD_* codenames, and -- with the operator's export
// (OPENSRO_GAMEWORLD_DIR) -- the 22 worlds, their group and the ENVY_DROP
// pillars' assigned drops.

import (
	"os"
	"testing"
	"time"
)

// The measured row of ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_1 (35883:
// TypeID 3/3/12/7, Param1 1, Param3/4 35/50, Param5 4, Param6 6, Desc2 the
// world, COOLTIME 0x71 18,000,000 ms).
func holeRow() HoleItem {
	return HoleItem{ID: 35883, TypeID1: 3, TypeID2: 3, TypeID3: 12, TypeID4: 7, Code: "ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_1",
		Desc2: "INS_GOD_TOGUI_35_50_LEVEL_1", Param1: 1, Param3: 35, Param4: 50, Param5: 4, Param6: 6, CoolGroup: 0x71, CoolMs: 18000000}
}

func TestHoleOf(t *testing.T) {
	h, ok := HoleOf(holeRow())
	if !ok {
		t.Fatal("the hole row is not a hole")
	}
	if h.RefID != 35883 || h.World != "INS_GOD_TOGUI_35_50_LEVEL_1" || h.Grade != 1 || h.LevelMin != 35 || h.LevelMax != 50 ||
		h.MaxPlayers != 4 || h.Access != AccessOwner || h.CoolGroup != HoleCoolGroup || h.CoolTime != HoleCoolTime {
		t.Fatalf("hole %+v", h)
	}
	if HoleCoolTime != 5*time.Hour {
		t.Fatalf("cool time %v, want 5 h", HoleCoolTime)
	}
	p := holeRow()
	p.Param6 = 7
	if h, _ := HoleOf(p); h.Access != AccessParty {
		t.Errorf("Param6 7 read as %d", h.Access)
	}
	p.Param6 = 0
	if h, _ := HoleOf(p); h.Access != AccessOwner {
		t.Errorf("Param6 0 read as %d, want the owner only", h.Access)
	}
	p = holeRow()
	p.TypeID4 = 6
	if _, ok := HoleOf(p); ok {
		t.Error("TypeID 3/3/12/6 read as a hole")
	}
	p = holeRow()
	p.Desc2 = "xxx"
	if _, ok := HoleOf(p); ok {
		t.Error("a hole naming no world read as one")
	}
}

func TestParseGodWorld(t *testing.T) {
	for code, want := range map[string]GodWorld{
		"INS_GOD_TOGUI_35_50_LEVEL_1":       {ThemeTogui, 35, 50, 1},
		"INS_GOD_FLAME_81_90_LEVEL_4":       {ThemeFlame, 81, 90, 4},
		"INS_GOD_WRECK_IN_100_110_LEVEL_2":  {ThemeWreckIn, 100, 110, 2},
		"INS_GOD_WRECK_OUT_91_100_LEVEL_3":  {ThemeWreckOut, 91, 100, 3},
		"ins_god_wreck_out_100_110_level_4": {ThemeWreckOut, 100, 110, 4},
	} {
		if got, ok := ParseGodWorld(code); !ok || got != want {
			t.Errorf("%s: %+v %v, want %+v", code, got, ok, want)
		}
	}
	for _, code := range []string{"INS_DEFAULT", "INS_GOD_MOON_1_2_LEVEL_1", "INS_GOD_TOGUI_35_50", "INS_JUPITER_A"} {
		if _, ok := ParseGodWorld(code); ok {
			t.Errorf("%s parsed as a Forgotten World", code)
		}
	}
	if !IsPillar("MOB_GOD_PILLAR_TOGUI_35_50") || IsPillar("MOB_GOD_PILLAR_ENVY_DROP_35_50") || IsPillar("MOB_GOD_PILLAR_ENVY_35_50") {
		t.Error("IsPillar")
	}
}

// TestFGWExport reads the operator's export: 22 INS_GOD_* worlds in group 1
// (300 minutes), each band's hole world present, and the 22 assigned drops of
// the seven ENVY_DROP pillars at 0.3 / 0.2 / 0.2 / 0.1, 0..1 attempts.
func TestFGWExport(t *testing.T) {
	dir := os.Getenv("OPENSRO_GAMEWORLD_DIR")
	if dir == "" {
		t.Skip("OPENSRO_GAMEWORLD_DIR not set")
	}
	ref, err := LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	god := 0
	for id := uint16(63); id <= 84; id++ {
		w := ref.World(id)
		if !w.IsGodWorld() || !w.Instanced() || w.MaxCount != 50 || w.Duration != 2*time.Hour || w.EmptyRemain != 10*time.Minute {
			t.Errorf("world %d: %+v", id, w)
			continue
		}
		if w.Group == nil || w.Group.ID != 1 || w.Group.CoolTime != 300*time.Minute {
			t.Errorf("world %d group %+v", id, w.Group)
		}
		gw, _ := ParseGodWorld(w.Code)
		if w.Config.LevelMax != gw.Hi || (w.Config.LevelMin != gw.Lo && !(gw.Lo == 100 && w.Config.LevelMin == 101)) {
			t.Errorf("world %d %s: band %d..%d", id, w.Code, w.Config.LevelMin, w.Config.LevelMax)
		}
		god++
	}
	if god != 22 {
		t.Errorf("%d Forgotten Worlds, want 22", god)
	}
	if w := ref.WorldByCode("INS_GOD_TOGUI_35_50_LEVEL_1"); w == nil || w.ID != 63 {
		t.Errorf("hole 35883's world: %+v", w)
	}
	if len(ref.AssignedDrops) == 0 {
		t.Skip("no _RefMonster_AssignedItemDrop.csv in the export")
	}
	n := 0
	for m := int64(36048); m <= 36054; m++ {
		for i, d := range ref.AssignedDrops[m] {
			n++
			want := []float64{0.3, 0.2, 0.2, 0.1}[i]
			if d.AmountMin != 0 || d.AmountMax != 1 || float32(d.Ratio) != float32(want) || d.Item < 35883 || d.Item > 35904 {
				t.Errorf("monster %d drop %d: %+v, want 0..1 at %v of a hole", m, i, d, want)
			}
		}
	}
	if n != 22 {
		t.Errorf("%d ENVY_DROP rows, want 22", n)
	}
}
