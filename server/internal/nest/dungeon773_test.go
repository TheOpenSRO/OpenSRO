package nest

import "testing"

// JoinDungeons places the rows of the dungeons its caller serves, joined to
// their DB nests as a field row is (nest 4 stands in 0x8001 at (10, 10));
// a dungeon it does not serve stays left out, as Join leaves every one.
func TestRound773JoinDungeons(t *testing.T) {
	db := testDB(t)
	look := func(id int64) (SpeciesInfo, bool) {
		if id == 5001 {
			return SpeciesInfo{CodeName: "MOB_TEST_A"}, true
		}
		return SpeciesInfo{}, false
	}
	spots := []Spot{
		{ObjectID: 5001, Region: -32767, X: 10, Y: 3, Z: 10}, // the cave: nest 4
		{ObjectID: 5001, Region: -32766, X: 50, Z: 50},       // another dungeon, not served
	}
	served := func(region int) bool { return region == 0x8001 }
	got, rep := JoinDungeons(spots, db, look, served)
	if len(got) != 1 || rep.Dungeon != 1 || rep.Matched != 1 {
		t.Fatalf("placed %d: %+v", len(got), rep)
	}
	if got[0].Spot.Region != 0x8001 || got[0].Nest == nil || got[0].Nest.ID != 4 || got[0].Spot.Y != 3 {
		t.Fatalf("the cave row joined %+v", got[0])
	}
	if _, rep := Join(spots, db, look); rep.Dungeon != 2 || rep.Placed != 0 {
		t.Fatalf("Join placed a dungeon row: %+v", rep)
	}
}
