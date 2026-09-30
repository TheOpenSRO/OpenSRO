package nest

import (
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Round 661's summon rules and loaders, on synthetic rows. These name
// functions the base revision does not have; the behaviour tests the
// negative runs are in rotation661_test.go.

const ssouWord = 0x73736f75

// The 'ssou' block: the tuples are the words after the code, four apiece
// {id, class, min, max}; the class keeps its low nibble; nine at most.
func TestParseSummonTuples(t *testing.T) {
	words := make([]int32, 50)
	words[0] = ssouWord
	copy(words[1:], []int32{1953, 0, 0, 0, 1952, 0x16, 2, 3, 0, 0, 3, 0})
	tuples, ok := ParseSummon(words)
	if !ok || len(tuples) != SummonTuplesMax {
		t.Fatalf("ok %v, %d tuples; want %d", ok, len(tuples), SummonTuplesMax)
	}
	if tuples[0] != (SummonTuple{RefObjID: 1953}) || tuples[1] != (SummonTuple{RefObjID: 1952, Class: 6, Min: 2, Max: 3}) {
		t.Fatalf("tuples %+v", tuples[:3])
	}
	if tuples[2].RefObjID != 0 || tuples[2].Min != 3 {
		t.Fatalf("a zero-id tuple is kept as read (the executor skips it): %+v", tuples[2])
	}
	if _, ok := ParseSummon(make([]int32, 50)); ok {
		t.Fatal("a block with no 'ssou' parsed as a summon")
	}
}

// The executor's count: min + rand % (max - min + 1), capped at 50, nothing
// below 1.
func TestMinionCountAndCap(t *testing.T) {
	if n := MinionCount(script(t, 0), 2, 3); n != 2 {
		t.Fatalf("throw 0 over 2..3: %d", n)
	}
	if n := MinionCount(script(t, 1), 2, 3); n != 3 {
		t.Fatalf("throw 1 over 2..3: %d", n)
	}
	if n := MinionCount(script(t, 7), 0, 0); n != 0 {
		t.Fatalf("a 0..0 tuple spawned %d", n)
	}
	if n := MinionCount(script(t, 5), 60, 90); n != SummonCountCap {
		t.Fatalf("60..90 spawned %d, want the cap %d", n, SummonCountCap)
	}
	if n := MinionCount(script(t, 0), 50, 50); n != 50 {
		t.Fatalf("50..50 spawned %d", n)
	}
}

// Summon_A's slots by AI_AttackChance, and the selector by TacticsID.
func TestSummonASlotAndSelector(t *testing.T) {
	for chance, want := range map[int]int{80: 0, 100: 0, 79: 1, 60: 1, 40: 2, 59: 2, 39: 3, 20: 3, 0: 3} {
		if got := SummonASlot(chance); got != want {
			t.Errorf("chance %d -> slot %d, want %d", chance, got, want)
		}
	}
	for id, want := range map[int64]SummonKind{33: SummonA, 63: SummonA, 229: SummonA, 26600: SummonA, 113: SummonB,
		154: SummonB, 185: SummonB, 0x970e: SummonC, 43891: SummonNone, 1: SummonNone} {
		if got := SummonKindFor(id); got != want {
			t.Errorf("tactics %d -> %v, want %v", id, got, want)
		}
	}
}

// A minion lands exactly at the minimum -- the unique's radius + 30 + its
// own -- since the ring's radius is at most 2 pi.
func TestMinionsLandAtTheSummonDistance(t *testing.T) {
	min := SummonDistance(28, 12)
	if min != 70 {
		t.Fatalf("distance %g, want 28 + 30 + 12", min)
	}
	for _, throws := range [][]int{{CRandMax}, {0}, {16000}} {
		r := SummonRadius(script(t, throws...))
		if r < 0 || r > 2*math.Pi+1e-5 {
			t.Fatalf("radius %g outside [0, 2pi]", r)
		}
		if r <= 1e-6 {
			continue // no offset at all (FUN_00531240's first test)
		}
		dx, dz := HatchOffsetMin(script(t, 0, CRandMax, 9000), r, min)
		if d := math.Hypot(dx, dz); math.Abs(d-min) > 1e-4 {
			t.Fatalf("radius %g: the minion stands %g off, want %g", r, d, min)
		}
	}
}

// Repin's dice, in the engine's order: the pick, then per nest the pinned
// nest's discarded roll before its re-arm roll -- a strict script fails on
// any other count.
func TestRepinDiceOrder(t *testing.T) {
	h := &Hive{TotalCap: 1}
	for i := 0; i < 3; i++ {
		sl := &Slot{Cap: 1, DelayMin: 10, DelayMax: 20, Hive: h}
		sl.Index = i
		h.nests = append(h.nests, sl)
	}
	now := time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
	rot := Repin(script(t, 7, 0, CRandMax, 0, 0), h, now) // k = 7 % 4 = 3 -> 2
	if rot.Roll != 2 || h.Pinned != h.nests[2] || rot.Pinned != h.nests[2] {
		t.Fatalf("roll %d, pinned %p, want nest 2", rot.Roll, h.Pinned)
	}
	if rot.WaitMs != 10000 || h.nests[0].baseMs != 10000 || h.nests[1].baseMs != 20000 {
		t.Fatalf("waits %d / %d / %d, want the scripted 10 s, 20 s, and the pinned 10 s", h.nests[0].baseMs, h.nests[1].baseMs, rot.WaitMs)
	}
}

// The two optional files load from the directory; their absence is not an
// error, a malformed one is.
func TestLoadOptionalSkillFiles(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{TacticsFile: tacticsCSV, NestFile: nestCSV, HiveFile: hiveCSV} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	db, err := LoadDir(dir)
	if err != nil || db.Skills != nil || db.AISkills != nil {
		t.Fatalf("without the optional files: err %v, skills %v, ai %v", err, db.Skills, db.AISkills)
	}
	params := make([]string, 50)
	for i := range params {
		params[i] = "0"
	}
	params[0] = "1936945013"
	params[1], params[2], params[3], params[4] = "5001", "1", "2", "3"
	skills := "Service,ID,GroupID,Basic_Code,AI_AttackChance," + func() string {
		var h []string
		for i := 1; i <= 50; i++ {
			h = append(h, "Param"+strconv.Itoa(i))
		}
		return strings.Join(h, ",")
	}() + "\n" +
		"1,3049,0,MSKILL_SYN_SUMMON01,80," + strings.Join(params, ",") + "\n" +
		"1,196,0,MSKILL_SYN_ATTACK01,100," + strings.Repeat("0,", 49) + "0\n"
	ai := "TacticsID,SkillCodeName,ExcuteConditionType,ExcuteConditionData,Option\n26600,MSKILL_SYN_ATTACK01,0,50,0\n"
	os.WriteFile(filepath.Join(dir, SkillFile), []byte(skills), 0o644)
	os.WriteFile(filepath.Join(dir, AISkillFile), []byte(ai), 0o644)
	db, err = LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if r := db.Skills[3049]; r == nil || !r.Summon || r.Tuples[0] != (SummonTuple{RefObjID: 5001, Class: 1, Min: 2, Max: 3}) {
		t.Fatalf("summon row %+v", r)
	}
	if r := db.Skills[196]; r == nil || r.Summon {
		t.Fatalf("attack row %+v", r)
	}
	if db.Skills[196].Code != "MSKILL_SYN_ATTACK01" {
		t.Fatalf("code %q", db.Skills[196].Code)
	}
	if rows := db.AISkills[26600]; len(rows) != 1 || rows[0].Type != 0 || rows[0].Data != 50 {
		t.Fatalf("ai rows %+v", rows)
	}
	os.WriteFile(filepath.Join(dir, AISkillFile), []byte("TacticsID,SkillCodeName\n1,x\n"), 0o644)
	if _, err := LoadDir(dir); err == nil {
		t.Fatal("a malformed Tab_RefAISkill.csv loaded")
	}
}
