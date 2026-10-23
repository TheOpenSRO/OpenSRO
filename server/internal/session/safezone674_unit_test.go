package session

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Which region a monster stands in is its hub bucket's frame's (round 674):
// the zone's centre for a named zone, worldmap.WorldOrigin for -single-frame's
// one bucket. Region y drives world X, region x drives world Z mirrored
// (worldmap's measured transform): in Jangan's frame 97/168 is z (-960, 960],
// 96/168 -- south of the town -- z (960, 2880], 98/168 z (-2880, -960].
func TestSafeRegionAtNamesTheRegionInTheBucketsFrame(t *testing.T) {
	if _, ok := safeRegionAt("jangan", 0, 0); ok {
		t.Fatal("a town with no table installed")
	}
	installTowns674(t, [][2]int{{97, 168}, {102, 153}}, [][2]int{{96, 168}, {98, 168}})
	for _, c := range []struct {
		zone string
		x, z float64
		town bool
	}{
		{"jangan", 0, 0, true},
		{"jangan", 0, 959.9, true},
		{"jangan", 0, 960.1, false},  // 96/168
		{"jangan", 0, -960.1, false}, // 98/168
		{"jangan", 959.9, 0, true},
		{"jangan", 960.1, 0, false}, // 97/169, not in the table
		{worldmap.WorldBucket, 0, 0, true},
		{"donwhang", 0, 0, true}, // its own frame: 102/153
		{"nowhere", 0, 0, false}, // no frame
	} {
		r, ok := safeRegionAt(c.zone, c.x, c.z)
		if ok != c.town {
			t.Errorf("safeRegionAt(%q, %g, %g) = %+v, %v; want town %v", c.zone, c.x, c.z, r, ok, c.town)
		}
	}
	x, z := worldmap.ToWorld(102, 153, 960, 960, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
	if _, ok := safeRegionAt(worldmap.WorldBucket, x, z); !ok {
		t.Errorf("Donwhang's middle in the one world frame (%g, %g) is not its town", x, z)
	}
}
