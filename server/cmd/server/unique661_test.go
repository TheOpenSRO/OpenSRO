package main

import (
	"io"
	"log/slog"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/nest"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/spawn"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
)

// Round 661: the uniques on the full map, on SYNTHETIC rows only.

// synthSpeciesSkills is synthSpecies with each row's ten skill columns.
func synthSpeciesSkills(t *testing.T, rows []([6]string), skills [][species.NumSkills]int64) *species.Table {
	t.Helper()
	var b strings.Builder
	b.WriteString(strings.Join(species.CSVColumns[:species.RequiredCSVColumns], ",") + "\n") // a pre-712 CSV: no ExpToGive
	for i, r := range rows {
		rec := []string{r[0], r[1], "", "0", "SN_" + r[1], "Synthetic " + r[1], r[5], r[2], r[3], r[4], "10", "40", "5"}
		for k := 0; k < species.NumParams; k++ {
			rec = append(rec, "0")
		}
		for k := 0; k < species.NumSkills; k++ {
			rec = append(rec, strconv.FormatInt(skills[i][k], 10))
		}
		rec = append(rec, "xxx", "0", "10", "20")
		b.WriteString(strings.Join(rec, ",") + "\n")
	}
	tab, err := species.Read(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return tab
}

// uniqueWorld661 is a Summon_A unique (tactics 33) with three spots in a
// total-1 hive, its _STR twin's hive on the same spots, and its minion.
func uniqueWorld661(t *testing.T) (spawn.Table, *species.Table, species.SkillLookup, *nest.DB) {
	t.Helper()
	tab := synthSpeciesSkills(t, [][6]string{
		{"7101", "MOB_CH_SYNTIGER", "3", "110", "299360", "1"},
		{"7102", "MOB_CH_SYNTIGER_STR", "3", "110", "299360", "1"},
		{"7201", "MOB_CH_SYNWHITETIGER", "0", "30", "2000", "1"},
	}, [][species.NumSkills]int64{{196, 3049, 3050, 3051, 3052, 12087}, {196}, {160}})
	skills := map[int64]species.SkillRow{
		196:  {ReuseMs: 3000, Range: 10, AttMin: 5, AttMax: 6, Chance: 100, ChanceKnown: true},
		160:  {ReuseMs: 3000, Range: 10, AttMin: 1, AttMax: 2, Chance: 100, ChanceKnown: true},
		3049: {ReuseMs: 500, Chance: 80, ChanceKnown: true}, 3050: {ReuseMs: 500, Chance: 60, ChanceKnown: true},
		3051: {ReuseMs: 500, Chance: 40, ChanceKnown: true}, 3052: {ReuseMs: 500, Chance: 0, ChanceKnown: true},
		12087: {ReuseMs: 2666, Range: 10, AttMin: 9, AttMax: 9, Chance: 100, ChanceKnown: true},
	}
	lookup := func(id int64) (species.SkillRow, bool) { r, ok := skills[id]; return r, ok }
	const tac = "dwTacticsID,dwObjID,nSightRange,btAggressType,AggressData,btChangeTarget,btTraceBoundary,TraceData,btHomingType,HomingData,btAggressTypeOnHoming,btFleeType,dwChampionTacticsID,AdditionOptionFlag\n" +
		"33,7101,140,0,0,2,1,500,0,0,1,0,0,112\n43891,7102,140,0,0,2,1,500,0,0,1,0,0,112\n500,7201,100,1,0,2,1,500,0,0,1,0,0,0\n"
	var ns strings.Builder
	ns.WriteString("dwNestID,dwHiveID,dwTacticsID,nRegionDBID,fLocalPosX,fLocalPosY,fLocalPosZ,wInitialDir,nRadius,nGenerateRadius,nChampionGenPercentage,dwDelayTimeMin,dwDelayTimeMax,dwMaxTotalCount,btFlag,btRespawn,btType\n")
	npcs := spawn.Table{}
	for i, x := range []float64{100, 700, 1300} {
		ns.WriteString("" + strconv.Itoa(1+i) + ",193,33,23198," + strconv.FormatFloat(x, 'f', -1, 64) + ",0,400,16384,1000,0,0,1200,1400,1,0,1,0\n")
		ns.WriteString("" + strconv.Itoa(11+i) + ",1579,43891,23198," + strconv.FormatFloat(x, 'f', -1, 64) + ",0,400,0,1000,0,0,1200,1400,1,0,1,0\n")
		npcs[7101] = append(npcs[7101], spawn.Placement{ObjectID: 7101, RegionID: 23198, LocalX: x, LocalZ: 400})
	}
	const hives = "dwHiveID,btKeepMonsterCountType,dwOverwriteMaxTotalCount,fMonsterCountPerPC,dwSpawnSpeedIncreaseRate,dwMaxIncreaseRate,btFlag,GameWorldID,HatchObjType\n" +
		"193,0,1,0,0,0,0,1,1\n1579,0,1,0,0,0,0,1,1\n"
	tr, err := nest.ReadTactics(strings.NewReader(tac))
	if err != nil {
		t.Fatal(err)
	}
	nr, err := nest.ReadNests(strings.NewReader(ns.String()))
	if err != nil {
		t.Fatal(err)
	}
	hr, err := nest.ReadHives(strings.NewReader(hives))
	if err != nil {
		t.Fatal(err)
	}
	db := nest.NewDB(tr, nr, hr)
	db.SetSkills(map[int64]*nest.SkillRow{
		196:   {ID: 196, Code: "MSKILL_SYN_ATTACK01"},
		12087: {ID: 12087, Code: "MSKILL_SYN_ATTACK05"},
		3049:  {ID: 3049, Code: "MSKILL_SYN_SUMMON01", Summon: true, Tuples: []nest.SummonTuple{{RefObjID: 7201}, {RefObjID: 7201, Class: 1}, {}}},
		3050:  {ID: 3050, Code: "MSKILL_SYN_SUMMON02", Summon: true, Tuples: []nest.SummonTuple{{RefObjID: 7201, Min: 2, Max: 3}}},
		3051:  {ID: 3051, Code: "MSKILL_SYN_SUMMON03", Summon: true, Tuples: []nest.SummonTuple{{RefObjID: 7201, Class: 4}}},
		3052:  {ID: 3052, Code: "MSKILL_SYN_SUMMON04", Summon: true, Tuples: []nest.SummonTuple{{RefObjID: 9999}}},
	})
	db.AISkills = map[int64][]nest.AISkillRow{33: {{TacticsID: 33, SkillCode: "MSKILL_SYN_ATTACK05", Type: 0, Data: 50}}}
	return npcs, tab, lookup, db
}

// The unique's three spots are three nests of its total-1 hive -- never the
// twin's -- with the hive's window, the nest row's direction, and the unique's
// own skills filed as its selector files them: the attack list without the
// summons and the trigger skill, Summon_A's four slots by AI_AttackChance,
// the trigger from the tactics' _RefAISkill row, and every tuple's count as
// its row gives it (0..0 kept: the executor spawns nothing for it).
func TestFullMapPlacesTheUniqueRotation(t *testing.T) {
	npcs, tab, lookup, db := uniqueWorld661(t)
	slots, rep := fullMapSlots(npcs, tab, lookup, db)
	if len(slots) != 3 || len(rep.uniques) != 1 || rep.uniques[0].spots != 3 || rep.join.UniqueSpots[7101] != 3 {
		t.Fatalf("%d slots, uniques %+v, join %+v", len(slots), rep.uniques, rep.join)
	}
	h := slots[0].Hive
	for i, sl := range slots {
		d := sl.Data.(*hatchData)
		if !d.rotation || sl.Hive != h || h.ID != 193 || h.TotalCap != 1 || sl.DelayMin != 1200 || sl.DelayMax != 1400 || sl.ID != int64(1+i) {
			t.Fatalf("slot %d: %+v rotation %v hive %+v", i, sl, d.rotation, sl.Hive)
		}
		if math.Abs(d.heading-math.Pi/2) > 1e-3 {
			t.Fatalf("slot %d faces %.4f rad, want the row's 16384 = 90 degrees", i, d.heading)
		}
	}
	sp := slots[0].Data.(*hatchData).species
	if len(sp.Skills) != 1 || sp.Skills[0].ID != 196 || sp.AttackMin != 5 {
		t.Fatalf("the attack list %+v, want only 196", sp.Skills)
	}
	if sp.Summon == nil || sp.Summon.Kind != combat.SummonKindA || len(sp.Summon.Skills) != 4 {
		t.Fatalf("summon %+v", sp.Summon)
	}
	for k, want := range []int64{3049, 3050, 3051, 3052} {
		if got := sp.Summon.Skills[k].Skill.ID; got != want {
			t.Fatalf("Summon_A slot %d holds %d, want %d", k, got, want)
		}
	}
	s1 := sp.Summon.Skills[0].Tuples
	if len(s1) != 2 || s1[0].Min != 0 || s1[0].Max != 0 || s1[1].Class != 1 || s1[0].Minion == nil {
		t.Fatalf("slot 0 tuples %+v: want the two non-zero-id tuples kept at the rows' 0..0 (READ: they spawn nothing) with a minion", s1)
	}
	if m := s1[0].Minion; m.Species.RefObjID != 7201 || m.Tactics == nil || m.Tactics.ID != 500 || m.MaxHP != 2000 {
		t.Fatalf("minion spec %+v", m)
	}
	if s2 := sp.Summon.Skills[1].Tuples; s2[0].Min != 2 || s2[0].Max != 3 {
		t.Fatalf("a real count was replaced: %+v", s2)
	}
	if s4 := sp.Summon.Skills[3].Tuples; s4[0].Minion != nil || len(rep.uniques[0].missingMinionSpecs) != 1 {
		t.Fatalf("an unknown minion species: %+v, report %v", s4, rep.uniques[0].missingMinionSpecs)
	}
	if len(sp.Triggers) != 1 || sp.Triggers[0].Skill.ID != 12087 || sp.Triggers[0].Data != 50 {
		t.Fatalf("triggers %+v", sp.Triggers)
	}
}

// -unique-respawn replaces the uniques' window; -nest-respawn does not reach
// them.
func TestUniqueRespawnOverride(t *testing.T) {
	for _, c := range []struct {
		nestOver, uniqueOver time.Duration
		min, max             int
	}{{5 * time.Second, 0, 1200, 1400}, {5 * time.Second, 60 * time.Second, 60, 60}, {0, 90 * time.Second, 90, 90}} {
		npcs, tab, lookup, db := uniqueWorld661(t)
		slots, _ := fullMapSlots(npcs, tab, lookup, db)
		s := newRespawnScheduler(combat.NewHub(), slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
		s.delayOverride, s.uniqueOverride = c.nestOver, c.uniqueOver
		for _, sl := range slots {
			s.addSlot(sl)
		}
		for _, sl := range slots {
			if sl.DelayMin != c.min || sl.DelayMax != c.max {
				t.Fatalf("-nest-respawn %v -unique-respawn %v: window %d..%d, want %d..%d", c.nestOver, c.uniqueOver,
					sl.DelayMin, sl.DelayMax, c.min, c.max)
			}
		}
	}
}

// The rotation in the running scheduler: one unique alive; killed, it comes
// back after the window at one of its spots, through the spawn hook -- which
// announces it -- exactly once.
func TestUniqueRotationRespawnAnnouncedOnce(t *testing.T) {
	npcs, tab, lookup, db := uniqueWorld661(t)
	slots, _ := fullMapSlots(npcs, tab, lookup, db)
	monsters := combat.NewHub()
	hatches := map[int64]int{}
	announced := 0
	// main's hook: the spawn push, then AnnounceUniqueSpawn(hub, m, true),
	// which sends the notice for exactly the monsters UniqueNoticeFor names
	// (session's own tests send it).
	s := newRespawnScheduler(monsters, slog.New(slog.NewTextHandler(io.Discard, nil)), func(id int64) {
		hatches[id]++
		if m, ok := monsters.Get(id); ok && session.UniqueNoticeFor(m.Rarity) {
			announced++
		}
	})
	s.uniqueOverride = 60 * time.Second
	for _, sl := range slots {
		s.addSlot(sl)
	}
	t0 := time.Date(2026, 9, 30, 18, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		s.check(t0.Add(time.Duration(i) * time.Second))
	}
	all := monsters.AppendAll(nil)
	if len(all) != 1 || len(hatches) != 1 || announced != 1 {
		t.Fatalf("%d uniques alive, %d hatched, announced %d times: want one of each", len(all), len(hatches), announced)
	}
	first := all[0]
	if _, died, _ := monsters.ApplyDamage(first.ID, first.MaxHP); !died {
		t.Fatal("the unique did not die")
	}
	died := t0.Add(10 * time.Second)
	s.check(died)
	s.check(died.Add(59 * time.Second))
	if monsters.Count() != 0 {
		t.Fatalf("%d alive before the 60 s window ran out", monsters.Count())
	}
	s.check(died.Add(60 * time.Second))
	s.check(died.Add(61 * time.Second))
	all = monsters.AppendAll(nil)
	if len(all) != 1 || all[0].ID == first.ID || all[0].RefObjID != 7101 {
		t.Fatalf("after the window: %+v, want the unique back, once", all)
	}
	if len(hatches) != 2 || hatches[all[0].ID] != 1 || announced != 2 {
		t.Fatalf("hatches %v, announced %d: want the respawn through the hook once, announced once", hatches, announced)
	}
	onSpot := false
	for _, sl := range slots {
		d := sl.Data.(*hatchData)
		if math.Hypot(all[0].X-d.homeX, all[0].Z-d.homeZ) < 1e-6 {
			onSpot = true
		}
	}
	if !onSpot {
		t.Fatalf("the unique came back at (%.1f, %.1f), not one of its spots", all[0].X, all[0].Z)
	}
}

// Round 661's review, L3: a -unique-respawn under 1 s would truncate to a 0 s
// wait; it is refused at boot, as -nest-respawn is.
func TestUniqueRespawnUnderASecondIsRefused(t *testing.T) {
	for _, c := range []struct {
		d  time.Duration
		ok bool
	}{{0, true}, {time.Second, true}, {60 * time.Second, true}, {500 * time.Millisecond, false}, {-time.Second, false}} {
		if err := checkUniqueRespawn(c.d); (err == nil) != c.ok {
			t.Errorf("checkUniqueRespawn(%v) = %v, want ok %v", c.d, err, c.ok)
		}
	}
}
