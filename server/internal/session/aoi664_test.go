package session

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
)

// Round 664: the window a player is sent is retail's -- the 3 x 3 message
// blocks of 320 units around the block it stands in (READ, SR_GameServer.exe:
// CRgnTerrain's 6 x 6 blocks a region, 0x53ad30's `fdiv` by 320.0 at
// 0xb45ae8, and the 8 neighbours of the table at 0xc64090 linked by
// CRgnTerrain::vslot_016 0x53ab90; aoi.go has the chain). A player at (10, 10)
// stands in the block [0, 320) x [0, 320), so it is sent the monsters of
// [-320, 640) on both axes and nothing else: 630 east is in, 650 east is out,
// 300 west is in, 330 west is out -- where the round-656 window (5 x 5 regions
// of 1920) sent every monster within 4,800.
func TestAOIWindowIsRetailsMessageBlocks(t *testing.T) {
	monsters := combat.NewHub()
	in := map[string]int64{
		"here":      spawnAt(t, monsters, "jangan", 100, 100),
		"630 east":  spawnAt(t, monsters, "jangan", 630, 10),
		"300 west":  spawnAt(t, monsters, "jangan", -300, 10),
		"630 north": spawnAt(t, monsters, "jangan", 10, 630),
		"corner":    spawnAt(t, monsters, "jangan", 639, -319),
		"300 south": spawnAt(t, monsters, "jangan", 10, -300),
	}
	out := map[string]int64{
		"650 east":    spawnAt(t, monsters, "jangan", 650, 10),
		"330 west":    spawnAt(t, monsters, "jangan", -330, 10),
		"650 north":   spawnAt(t, monsters, "jangan", 10, 650),
		"330 south":   spawnAt(t, monsters, "jangan", 10, -330),
		"1,000 east":  spawnAt(t, monsters, "jangan", 1000, 10),
		"a region on": spawnAt(t, monsters, "jangan", 1930, 10),
	}
	r := newListRig(t, monsters)
	c := r.join(t, 1, 10, 10)
	got, _ := r.list(t, c, len(in))
	listed := map[int64]bool{}
	for _, m := range got {
		listed[m.ID] = true
	}
	for name, id := range in {
		if !listed[id] {
			t.Errorf("the monster %s (in the 3 x 3 blocks) was not listed", name)
		}
	}
	for name, id := range out {
		if listed[id] {
			t.Errorf("the monster %s (outside the 3 x 3 blocks) was listed", name)
		}
	}
	if len(got) != len(in) {
		t.Errorf("listed %d monsters, want the window's %d", len(got), len(in))
	}
}
