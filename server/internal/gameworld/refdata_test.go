package gameworld

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

// writeTable writes t as dir/<name>.csv.
func writeTable(t *testing.T, dir, name string, tab *reftable.Table) {
	t.Helper()
	f, err := os.Create(filepath.Join(dir, name+".csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := tab.WriteCSV(f); err != nil {
		t.Fatal(err)
	}
}

// synthGodDir writes a synthetic export shaped like the spec's
// (game_worlds.md 1, forgotten_world.md 1): the open world, 22 GOD worlds
// 63..84 (50 layers, 4 or 8 players, 2 h, 10 min), their configs with the
// three warnings, the one world group at 300 minutes, the 48 Togui regions
// rows 0x79..0x7E x columns 0xE1..0xE8 for worlds 63..68, and one start
// position per world. Built from the spec's numbers, not from game files.
func synthGodDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	w := reftable.New("ID", "WorldCodeName128", "Type", "WorldMaxCount", "WorldMaxUserCount", "WorldEntryType",
		"WorldEntranceType", "WorldLeaveType", "WorldDurationTime", "WorldEmptyRemainTime", "ConfigGroupCodeName128")
	w.Append("1", "INS_DEFAULT", "0", "1", "0", "0", "0", "0", "0", "0", "xxx")
	cfg := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	bind := reftable.New("Service", "ID", "GameWorldID", "GameWorldGroupID")
	start := reftable.New("WorldID", "RegionID", "PosX", "PosY", "PosZ", "Param")
	n := 0
	for id := 63; id <= 84; id++ {
		users := "4"
		if (id >= 71 && id <= 72) || (id >= 75 && id <= 76) || (id >= 79 && id <= 80) || id >= 83 {
			users = "8"
		}
		g := fmt.Sprintf("GROUP_GOD_%d", id)
		w.Append(fmt.Sprint(id), fmt.Sprintf("INS_GOD_W%d", id), "1", "50", users, "0", "0", "0", "7200000", "600000", g)
		lo, hi := "35", "50"
		for _, kv := range [][2]string{{"GAME_WORLD_NORMALIZE_TYPE", "GAME_WORLD_NORMALIZE_TYPE_A"},
			{"ENTER_LIMIT_CONDITION_LEVEL_MINIMUM_NUM", lo}, {"ENTER_LIMIT_CONDITION_LEVEL_MAXIMUM_NUM", hi},
			{"ENTER_LIMIT_CONDITION_JOB_CLOTHES_TAKE_OFF", "ON"}, {"ENTER_LIMIT_CONDITION_RIDE_COS_NOT_RIDING", "ON"},
			{"ENTER_LIMIT_CONDITION_TRADE_COS_NOT_RIDING", "ON"}, {"PARTYMONSTER_SPAWN", "OFF"},
			{"GAMEWORLD_DISAPPEARANCE_TIME", "3600000"}, {"GAMEWORLD_DISAPPEARANCE_TIME", "600000"},
			{"GAMEWORLD_DISAPPEARANCE_TIME", "300000"}} {
			n++
			cfg.Append("1", fmt.Sprint(n), g, kv[0], kv[1], "INT32")
		}
		bind.Append("1", fmt.Sprint(id-62), fmt.Sprint(id), "1")
		start.Append(fmt.Sprint(id), "32484", "1063", "693", "1125", "0")
	}
	regions := reftable.New("WorldID", "RegionID")
	for id := 63; id <= 68; id++ {
		for row := 0x79; row <= 0x7E; row++ {
			for col := 0xE1; col <= 0xE8; col++ {
				regions.Append(fmt.Sprint(id), fmt.Sprint(row<<8|col))
			}
		}
	}
	group := reftable.New("ID", "CodeName128", "ObjName128", "ConfigGroupCodeName128")
	group.Append("1", "GROUP_INS_GOD", "x", "GROUP_CONFIG_INS_GOD")
	gcfg := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	gcfg.Append("1", "1", "GROUP_CONFIG_INS_GOD", "ENTER_WORLD_GROUP_COOL_TIME", "300", "INT32")
	gcfg.Append("1", "2", "GROUP_CONFIG_INS_GOD", "TIMEDJOB_COOL_TIME_FORCLIENT", "300", "CLIENT_DATA")
	writeTable(t, dir, TableWorld, w)
	writeTable(t, dir, TableWorldConfig, cfg)
	writeTable(t, dir, TableGroup, group)
	writeTable(t, dir, TableGroupConfig, gcfg)
	writeTable(t, dir, TableGroupBind, bind)
	writeTable(t, dir, TableRegion, regions)
	writeTable(t, dir, TableStartPos, start)
	return dir
}

// checkGodRef asserts the spec's numbers on a loaded Ref (game_worlds.md 14
// item 1's test): 22 GOD worlds, 48 Togui regions, start 0x7EE4, the group
// cool time 300 -> 18,000 s, three warning thresholds.
func checkGodRef(t *testing.T, ref *Ref, godPrefix string) {
	t.Helper()
	god := 0
	for _, id := range ref.IDs() {
		w := ref.World(id)
		if id >= 63 && id <= 84 {
			god++
			if !w.Instanced() || w.MaxCount != 50 || w.Duration != 2*time.Hour || w.EmptyRemain != 10*time.Minute {
				t.Errorf("world %d %s: type %d, %d layers, %v / %v; want 1, 50, 2h / 10m", id, w.Code, w.Type, w.MaxCount, w.Duration, w.EmptyRemain)
			}
			if w.MaxUsers != 4 && w.MaxUsers != 8 {
				t.Errorf("world %d: %d players, want 4 or 8", id, w.MaxUsers)
			}
			if got := w.Config.Warnings; len(got) != 3 || got[0] != time.Hour || got[1] != 10*time.Minute || got[2] != 5*time.Minute {
				t.Errorf("world %d: warnings %v, want [1h 10m 5m]", id, got)
			}
			if w.Group == nil || w.Group.CoolTime != 18000*time.Second {
				t.Errorf("world %d: group %+v, want the 18,000 s cool time", id, w.Group)
			}
			if len(w.Starts) == 0 {
				t.Errorf("world %d: no start position", id)
			}
		}
	}
	if god != 22 {
		t.Errorf("%d GOD worlds, want 22", god)
	}
	for id := uint16(63); id <= 68; id++ {
		w := ref.World(id)
		if len(w.Regions) != 48 || !w.HasRegion(0x79E1) || !w.HasRegion(0x7EE8) || w.HasRegion(0x7AE9) {
			t.Errorf("world %d: %d regions (0x79E1 %v, 0x7EE8 %v), want the 48 of 0x79E1..0x7EE8", id, len(w.Regions), w.HasRegion(0x79E1), w.HasRegion(0x7EE8))
		}
		s := w.Starts[0]
		if s.Region != 0x7EE4 || s.X != 1063 || s.Y != 693 || s.Z != 1125 {
			t.Errorf("world %d: start %+v, want 0x7EE4 (1063, 693, 1125)", id, s)
		}
		if w.Config.LevelMin == 0 || w.Config.LevelMax == 0 || !w.Config.JobSuitOff || !w.Config.NotRiding || !w.Config.NoTradeCOS || w.Config.PartyMonsterSpawn {
			t.Errorf("world %d: config %+v", id, w.Config)
		}
	}
	if g := ref.Groups[1]; g == nil || len(g.Worlds) != 22 || g.Code != "GROUP_INS_GOD" {
		t.Errorf("group 1: %+v, want GROUP_INS_GOD over 22 worlds", g)
	}
}

func TestRefdataSynthetic(t *testing.T) {
	ref, err := LoadDir(synthGodDir(t))
	if err != nil {
		t.Fatal(err)
	}
	checkGodRef(t, ref, "INS_GOD_W")
	if w := ref.World(1); w == nil || w.Instanced() || w.Code != "INS_DEFAULT" {
		t.Errorf("world 1: %+v", w)
	}
}

// TestRefdataExport runs on an operator's real export (OPENSRO_GAMEWORLD_DIR,
// cmd/export-refdata -mode gameworlds): skipped without one.
func TestRefdataExport(t *testing.T) {
	dir := os.Getenv("OPENSRO_GAMEWORLD_DIR")
	if dir == "" {
		t.Skip("OPENSRO_GAMEWORLD_DIR not set (the export of cmd/export-refdata -mode gameworlds)")
	}
	ref, err := LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	checkGodRef(t, ref, "INS_GOD_")
	if w := ref.World(63); w.Code != "INS_GOD_TOGUI_35_50_LEVEL_1" || w.Config.LevelMin != 35 || w.Config.LevelMax != 50 {
		t.Errorf("world 63: %s %d..%d", w.Code, w.Config.LevelMin, w.Config.LevelMax)
	}
	if n := len(ref.Triggers.ForWorld(63)); n != 17 {
		t.Errorf("world 63: %d triggers, want 17 (forgotten_world.md 1)", n)
	}
	if n := len(ref.Triggers.ForWorld(1)); n != 7 {
		t.Errorf("world 1: %d triggers, want the 7 pillars", n)
	}
}
