package pcspawn

import "testing"

// A character walking in a dungeon carries its destination in the dungeon
// form (round 773): the region with bit 15, then three i32 of dungeon space.
func TestRound773DungeonDestinationRoundTrips(t *testing.T) {
	r := plain()
	r.Region, r.X, r.Z = 0x8001, 1011.5, -862
	r.HasDest, r.RunFlag, r.DestRegion = true, 1, 0x8001
	r.DungeonX, r.DungeonY, r.DungeonZ = 70000, -5, -900
	buf, err := Append(nil, r)
	if err != nil {
		t.Fatal(err)
	}
	field := plain()
	field.HasDest, field.DestRegion = true, 25000
	fbuf, err := Append(nil, field)
	if err != nil {
		t.Fatal(err)
	}
	if len(buf)-len(fbuf) != 6 {
		t.Fatalf("the dungeon record is %d bytes longer than the field one; want 6 (three i32 for three i16)", len(buf)-len(fbuf))
	}
	d, rest, err := Decode(buf, nil)
	if err != nil || len(rest) != 0 {
		t.Fatalf("Decode: %v, %d left", err, len(rest))
	}
	if d.Region != 0x8001 || d.DestRegion != 0x8001 || d.DungeonX != 70000 || d.DungeonY != -5 || d.DungeonZ != -900 {
		t.Fatalf("decoded %+v", d)
	}
}
