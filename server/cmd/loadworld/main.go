// Command loadworld writes a synthetic game for the multi-process load test
// (round 869 lane W2, OURS, docs/protocol/game_worlds.md 12.7): every table
// a lane server needs to run instances with monsters in them, made up here
// -- no game file is read and nothing written is the game's.
//
//	loadworld -out DIR [-nests 58] [-per-nest 2]
//
// DIR gets:
//
//	gw/            the game-world tables: the open world and -worlds
//	               instanced worlds 63.. (each 50 layers of 4 players, 2 h, a
//	               10 min empty close, one start point: the spec's numbers
//	               for a GOD world, game_worlds.md 1 -- the real data has 22
//	               of them);
//	nest/          tab_refhive, tab_refnest, Tab_RefTactics: one hive per
//	               world with -nests nests of -per-nest monsters each around
//	               the start (58 x 2 = 116 slots: the nest count of world 63
//	               MEASURED in round 869 lane W1's export, so an instance
//	               holds about as many monsters as the real one);
//	monsters.csv   the synthetic species (level 40, 40 HP -- the bots' bare
//	               swings kill it -- walk 16 / run 50) the nests hatch, each
//	               nest again 10..20 s after a kill;
//	chargen.csv    a creatable catalogue for partybot's China kit ids;
//	leveldata.csv  levels 1..80 at 1,000 x level EXP each.
//
// The numbers other than the nest count are OURS (a load, not a game).
package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

func write(path string, rows [][]string) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fail(err)
	}
	f, err := os.Create(path)
	if err != nil {
		fail(err)
	}
	w := csv.NewWriter(f)
	if err := w.WriteAll(rows); err != nil {
		fail(err)
	}
	if err := f.Close(); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "loadworld:", err)
	os.Exit(1)
}

func itoa(i int) string { return strconv.Itoa(i) }

func main() {
	out := flag.String("out", "", "the directory to write")
	nests := flag.Int("nests", 58, "nests in world 63's hive")
	perNest := flag.Int("per-nest", 2, "monsters per nest")
	worlds := flag.Int("worlds", 10, "instanced worlds 63.. (50 layers each)")
	flag.Parse()
	if *out == "" {
		fail(fmt.Errorf("-out is required"))
	}
	gw := filepath.Join(*out, "gw")
	ws := [][]string{
		{"ID", "WorldCodeName128", "Type", "WorldMaxCount", "WorldMaxUserCount", "WorldEntryType", "WorldEntranceType",
			"WorldLeaveType", "WorldDurationTime", "WorldEmptyRemainTime", "ConfigGroupCodeName128"},
		{"1", "INS_DEFAULT", "0", "1", "0", "0", "0", "0", "0", "0", "xxx"},
	}
	regions := [][]string{{"WorldID", "RegionID"}}
	starts := [][]string{{"WorldID", "RegionID", "PosX", "PosY", "PosZ", "Param"}}
	hives := [][]string{{"dwHiveID", "btKeepMonsterCountType", "dwOverwriteMaxTotalCount", "fMonsterCountPerPC",
		"dwSpawnSpeedIncreaseRate", "dwMaxIncreaseRate", "btFlag", "GameWorldID", "HatchObjType"}}
	const species, tactics, hive = 990001, 990001, 990001
	for k := 0; k < *worlds; k++ {
		id := itoa(63 + k)
		ws = append(ws, []string{id, "INS_LOAD_" + id, "1", "50", "4", "0", "0", "0", "7200000", "600000", "G" + id})
		regions = append(regions, []string{id, itoa(0x7EE4)}, []string{id, itoa(0x7EE3)})
		starts = append(starts, []string{id, itoa(0x7EE4), "1063", "693", "1125", "0"})
		hives = append(hives, []string{itoa(hive + k), "0", "0", "0", "0", "0", "0", id, "1"})
	}
	write(filepath.Join(gw, "_RefGame_World.csv"), ws)
	write(filepath.Join(gw, "_RefInstance_World_Region.csv"), regions)
	write(filepath.Join(gw, "_RefInstance_World_Start_Pos.csv"), starts)
	write(filepath.Join(*out, "nest", "tab_refhive.csv"), hives)
	write(filepath.Join(*out, "nest", "Tab_RefTactics.csv"), [][]string{
		{"dwTacticsID", "dwObjID", "nSightRange", "btAggressType", "AggressData", "btChangeTarget", "btTraceBoundary",
			"TraceData", "btHomingType", "HomingData", "btAggressTypeOnHoming", "btFleeType", "dwChampionTacticsID",
			"AdditionOptionFlag"},
		{itoa(tactics), itoa(species), "200", "1", "0", "0", "0", "500", "0", "0", "0", "0", "0", "0"},
	})
	nestRows := [][]string{{"dwNestID", "dwHiveID", "dwTacticsID", "nRegionDBID", "fLocalPosX", "fLocalPosY", "fLocalPosZ",
		"wInitialDir", "nRadius", "nGenerateRadius", "nChampionGenPercentage", "dwDelayTimeMin", "dwDelayTimeMax",
		"dwMaxTotalCount", "btFlag", "btRespawn", "btType"}}
	for k := 0; k < *worlds; k++ {
		for i := 0; i < *nests; i++ {
			// A grid of nests around the start (1063, 1125), 40 units apart.
			x := 900 + float64(i%10)*40
			z := 950 + float64(i/10)*40
			nestRows = append(nestRows, []string{itoa(990001 + k*1000 + i), itoa(hive + k), itoa(tactics), itoa(0x7EE4),
				fmt.Sprintf("%.0f", x), "693", fmt.Sprintf("%.0f", z), "0", "60", "30", "0", "10", "20",
				itoa(*perNest), "0", "1", "0"})
		}
	}
	write(filepath.Join(*out, "nest", "tab_refnest.csv"), nestRows)

	head := []string{"ID", "CodeName", "OrgCodeName", "OrgID", "NameKey", "Name", "TypeID4", "Rarity",
		"Level", "MaxHP", "WalkSpeed", "RunSpeed", "BCRadius",
		"Col71", "Col72", "Col73", "Col74", "Col75", "Col76", "Col77", "Col78",
		"Skill1", "Skill2", "Skill3", "Skill4", "Skill5", "Skill6", "Skill7", "Skill8", "Skill9", "Skill10",
		"Model", "ModelFromOrg", "GoldMin", "GoldMax", "ExpToGive"}
	row := []string{itoa(species), "MOB_LOAD_SYNTH", "xxx", "0", "xxx", "Load Synth", "1", "0",
		"40", "40", "16", "50", "10",
		"100", "100", "20", "20", "0", "0", "0", "0",
		"0", "0", "0", "0", "0", "0", "0", "0", "0", "0",
		"xxx", "0", "10", "20", "500"}
	write(filepath.Join(*out, "monsters.csv"), [][]string{head, row})

	write(filepath.Join(*out, "chargen.csv"), [][]string{
		{"ID", "Code", "Kind", "Country", "Sex", "TypeID1", "TypeID2", "TypeID3", "TypeID4", "TwoHanded", "MaxStack"},
		{"1909", "CHAR_LOAD_MODEL", "model", "0", "0", "1", "1", "0", "0", "0", "0"},
		{"3643", "ITEM_LOAD_CHEST_A_DEF", "item", "0", "0", "3", "1", "1", "3", "0", "1"},
		{"3644", "ITEM_LOAD_LEGS_A_DEF", "item", "0", "0", "3", "1", "1", "4", "0", "1"},
		{"3645", "ITEM_LOAD_FEET_A_DEF", "item", "0", "0", "3", "1", "1", "6", "0", "1"},
		{"3632", "ITEM_LOAD_SWORD_A_DEF", "item", "0", "2", "3", "1", "6", "2", "0", "1"},
	})
	lv := [][]string{{"level", "exp"}}
	for i := 1; i <= 80; i++ {
		lv = append(lv, []string{itoa(i), itoa(1000 * i)})
	}
	write(filepath.Join(*out, "leveldata.csv"), lv)
	fmt.Printf("loadworld: wrote %s (%d worlds, %d nests x %d monsters each)\n", *out, *worlds, *nests, *perNest)
}
