package main

import (
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// With the cave served (a main-world teleport point stands in 0x8001), its
// npcpos row becomes a nest in the cave's own bucket, at the row's
// dungeon-space point mirrored, hatching at the row's height (round 773).
func TestRound773FullMapPlacesServedDungeonRows(t *testing.T) {
	pts := "ID,Code,ObjectID,ZoneName,Region,X,Y,Z,Radius,Interaction7,Interaction9,WorldID\n" +
		"10,OUT,0,Z,-32767,1011,0,-862,90,0,0,1\n" +
		"11,IN,0,Z,27027,1814,452,1834,90,0,0,1\n"
	links := "From,To,Fee,Rule1Type,Rule1Data1,Rule1Data2,Rule2Type,Rule2Data1,Rule2Data2," +
		"Rule3Type,Rule3Data1,Rule3Data2,Rule4Type,Rule4Data1,Rule4Data2,Rule5Type,Rule5Data1,Rule5Data2\n" +
		"11,10,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n"
	tab, err := teleport.Read(strings.NewReader(pts), strings.NewReader(links), strings.NewReader("ID,Code,NameStrID,Region,X,Y,Z,Fortress\n"))
	if err != nil {
		t.Fatal(err)
	}
	session.InstallDungeonEntries(tab)
	t.Cleanup(func() { session.InstallDungeonEntries(nil) })
	npcs, species := synthWorld(t)
	npcs[7002][1].LocalY = 42
	slots, rep := fullMapSlots(npcs, species, nil, nil)
	if rep.join.Dungeon != 0 || len(slots) != 3 {
		t.Fatalf("%d slots, report %+v", len(slots), rep.join)
	}
	var d *hatchData
	for _, sl := range slots {
		if x := sl.Data.(*hatchData); x.spec.Zone == "dungeon/32769" {
			d = x
		}
	}
	if d == nil || d.homeX != 1 || d.homeZ != -1 || d.homeY != 42 {
		t.Fatalf("the cave's slot %+v", d)
	}
	for _, sl := range slots {
		if x := sl.Data.(*hatchData); x != d && x.spec.Zone != worldmap.WorldBucket {
			t.Fatalf("a field slot in %q", x.spec.Zone)
		}
	}
}
