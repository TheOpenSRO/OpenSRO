package session

import (
	"fmt"
	"math"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/safezone"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// Towns (round 674): a monster that walks into a town region is removed.
//
// READ, SR_GameServer.exe (internal/safezone's package note has the
// addresses): CGObjMob's SetCurRegion (slot 235, 0x4c1270) sets life state 3
// -- removal, no death -- whenever the monster's new region's _RefRegion
// IsBattleField byte is 0. It runs on every region change, a hatch's first
// placement included, and nothing before it can veto a monster's entry. So a
// monster chasing a player across a town's region line disappears at the
// line; one hatched or spawned in a town is gone at once. Nothing else
// protects the player: CGObjMob's attack check and the AI's target tests read
// no region, so a monster still on the field side can hit a player standing
// just inside, within its reach.
//
// srrevamp: the monster AI's pass checks each monster whose step carried it
// over a cell line -- a region line is always one (combat.CellSpan divides
// worldmap.RegionSpan) -- and each monster it meets for the first time, and
// removes the ones standing in a town (combat.Hub.Remove). The players whose
// window held it are told the way a monster leaving their window is
// (OpMonsterLeft): the client drops the body, no death. With no table
// installed (-regions-csv unset, and every test that does not install one)
// nothing changes.
//
// OURS, disclosed: the region of a monster exactly on a z region line is
// worldmap.FromWorld's, while the cell index files that line on the far side
// (combat.CellOf), so a monster whose leg ends exactly on the line is not
// checked until it next crosses a cell line.
var safeRegions atomic.Pointer[safezone.Table]

// SetSafeRegions installs the town table the monster AI removes monsters by
// (cmd/server's -regions-csv); nil turns the rule off.
func SetSafeRegions(t *safezone.Table) { safeRegions.Store(t) }

// safeRegionAt is the town region world point (x, z) of hub bucket zone lies
// in, when the installed table names one.
func safeRegionAt(zone string, x, z float64) (safezone.Region, bool) {
	t := safeRegions.Load()
	if t == nil {
		return safezone.Region{}, false
	}
	fx, fy, ok := entityFrame(zone)
	if !ok || math.IsNaN(x) || math.IsNaN(z) {
		return safezone.Region{}, false
	}
	rx, ry, _, _ := worldmap.FromWorld(x, z, fx, fy)
	if rx < 0 || rx > 0xFF || ry < 0 || ry > 0xFF {
		return safezone.Region{}, false
	}
	return t.SafeAt(worldmap.RegionID(rx, ry))
}

// removeIfInTown removes m when it stands in a town region: the hub's
// removal, the players whose window holds it told (OpMonsterLeft, after the
// pass), its states and its blocking streak forgotten as a death forgets
// them, and one log line. Its brain, if it has one, is dropped by the pass's
// reconcile like a dead monster's. Called under a.mu, by the pass.
func (a *monsterAI) removeIfInTown(m combat.Monster, why string) bool {
	region, ok := safeRegionAt(m.Zone, m.X, m.Z)
	if !ok {
		return false
	}
	gone, removed := a.monsters.Remove(m.ID)
	if !removed {
		return false
	}
	chanceMemory.Forget(gone.ID)
	statusFX.forgetMonster(gone.ID)
	// id 0: sent as it is. The monster is gone from the hub, so the
	// alive-and-shown check every other push takes (mayShowLeg) would drop it.
	a.pending = append(a.pending, monsterPush{zone: gone.Zone, cell: combat.CellOf(gone.Zone, gone.X, gone.Z),
		packet: &proto.Packet{Opcode: OpMonsterLeft, Data: (&MonsterLeft{IDs: []int64{gone.ID}}).Encode()}})
	state, target := "none", int64(0)
	if b := a.brains[gone.ID]; b != nil {
		state, target = b.machine.State().String(), b.target
	}
	rx, ry := worldmap.RegionXY(region.ID)
	if a.logger != nil {
		a.logger.Info("monster removed: it entered a town (_RefRegion IsBattleField 0; CGObjMob::SetCurRegion 0x4c1270 -> SetLifeState 3)",
			"monster", gone.ID, "name", gone.Name, "how", why, "state", state, "target", target,
			"region", fmt.Sprintf("%d/%d", rx, ry), "area", region.Area,
			"x", math.Round(gone.X*10)/10, "z", math.Round(gone.Z*10)/10)
	}
	a.tracef("ai: monster %d removed in town region %d/%d (%s), %s", gone.ID, rx, ry, region.Area, why)
	return true
}
