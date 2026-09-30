package nest

import (
	"strings"
	"testing"
)

// Round 660's review. Synthetic rows only.

// Co-located nests: two nests at one point, naming two other species, and
// two rows there -- each row takes its own nest, never the same one (the
// shard's SD_MONTKILLER and SD_HIKE both claimed nest 29723). A row whose
// own species' nest stands 0.7 off beside another species' nest at 0.0 takes
// its own. A third row at the full point finds both nests claimed and runs
// the stand-in. The tolerance's evidence counts the OTHER nests inside it:
// the nearest other nest to a placed row is 0 here, not the far one at 5.
// A rarity-8 row (unique-class) is left out like a rarity-3 one.
func TestJoinCoLocatedNestsOneRowEach(t *testing.T) {
	tac, err := ReadTactics(strings.NewReader(`dwTacticsID,dwObjID,nSightRange,btAggressType,AggressData,btChangeTarget,btTraceBoundary,TraceData,btHomingType,HomingData,btAggressTypeOnHoming,btFleeType,dwChampionTacticsID,AdditionOptionFlag
1,8001,100,0,0,2,1,500,0,0,1,0,0,0
2,8002,100,0,0,2,1,500,0,0,1,0,0,0
3,6003,100,0,0,2,1,500,0,0,1,0,0,0
`))
	if err != nil {
		t.Fatal(err)
	}
	nests, err := ReadNests(strings.NewReader(`dwNestID,dwHiveID,dwTacticsID,nRegionDBID,fLocalPosX,fLocalPosY,fLocalPosZ,wInitialDir,nRadius,nGenerateRadius,nChampionGenPercentage,dwDelayTimeMin,dwDelayTimeMax,dwMaxTotalCount,btFlag,btRespawn,btType
10,1,1,25000,100,0,100,0,300,100,10,1,3,3,0,1,0
11,1,2,25000,100,0,100,0,300,100,10,1,3,3,0,1,0
12,1,2,25000,500,0,500,0,300,100,10,1,3,3,0,1,0
13,1,3,25000,500.7,0,500,0,300,100,10,1,3,3,0,1,0
14,1,1,25000,105,0,100,0,300,100,10,1,3,3,0,1,0
`))
	if err != nil {
		t.Fatal(err)
	}
	db := NewDB(tac, nests, nil)
	species := map[int64]SpeciesInfo{
		6001: {CodeName: "MOB_SD_MONTKILLER_SYN"}, 6002: {CodeName: "MOB_SD_HIKE_SYN"},
		6003: {CodeName: "MOB_KK_PLANAR_SYN"}, 6004: {CodeName: "MOB_THIRD_SYN"},
		6008: {Rarity: 8, CodeName: "MOB_SD_SPHINX_SYN"},
	}
	look := func(id int64) (SpeciesInfo, bool) { s, ok := species[id]; return s, ok }
	got, rep := Join([]Spot{
		{ObjectID: 6001, Region: 25000, X: 100, Z: 100},
		{ObjectID: 6002, Region: 25000, X: 100, Z: 100},
		{ObjectID: 6004, Region: 25000, X: 100, Z: 100},
		{ObjectID: 6003, Region: 25000, X: 500, Z: 500},
		{ObjectID: 6008, Region: 25000, X: 300, Z: 300},
	}, db, look)
	if rep.Placed != 4 || len(got) != 4 {
		t.Fatalf("placed %d rows, want 4: the rarity-8 row is unique-class and left out (%+v)", rep.Placed, rep)
	}
	if rep.SwappedTo[8001] != 1 || rep.SwappedTo[8002] != 1 {
		t.Fatalf("the two co-located rows took nests of species 8001 x%d and 8002 x%d, want one each", rep.SwappedTo[8001], rep.SwappedTo[8002])
	}
	if got[2].Cat != StandIn || got[2].DBSpecies != 0 {
		t.Fatalf("the third row at the full point joined %+v, want the stand-in (both nests are claimed)", got[2])
	}
	if got[3].Cat != Matched || got[3].Nest == nil || got[3].Nest.ID != 13 {
		t.Fatalf("the PLANAR row joined %+v, want its own species' nest 13 at 0.7 over nest 12 at 0.0", got[3])
	}
	if rep.NearestOther != 0 {
		t.Fatalf("nearest other nest to a placed row %.3f, want 0: co-located nests are inside the tolerance", rep.NearestOther)
	}
}

// The champion gate (col 41) on the OUTCOME: with every die at 0 -- a roll
// that would come up champion and giant -- a row without a champion row
// hatches a plain monster, and one with it a giant.
func TestRollClassChampionGateOutcome(t *testing.T) {
	zero := func() int { return 0 }
	in := HatchInput{Rarity: 0, TypeID4: 1, ChampionPct: 100, HasChampionTactics: false}
	if r := RollClass(zero, in, GiantMonsterSpawnRatio); r.Class != 0 || r.Champion {
		t.Fatalf("no champion row, every die 0: %+v, want a plain monster", r)
	}
	in.HasChampionTactics = true
	if r := RollClass(zero, in, GiantMonsterSpawnRatio); r.Class != 4 || !r.Champion {
		t.Fatalf("a champion row, every die 0: %+v, want a giant (0 is not above 14)", r)
	}
}
