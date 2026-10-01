package session

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
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
// (OpMonsterLeft): the client fades the body out over 1.5 s, no death (round
// 677: READ, retail's deletion of a state-3 monster sends the despawn 0x3016
// -- FUN_00417090 -> the leave-world 0x485150 -> CMsgBlock slot 3 0x5344b0 ->
// FUN_00534050 -- and the client fades a despawn with CIDecoDisappear;
// docs/protocol/appear_fade.md). With no table
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

// townPlacedPeriod is how often the pass sums up the monsters it removed on
// placement in a town (OURS, round 674's review): those are logged at Debug
// one by one and at INFO as one count per period. A nest standing in a town
// (Alexandria's six in the retail data, windows of 1-3 s, cap 24) hatches and
// loses a monster every second or two while a player is near, which one INFO
// line each would flood the log with. A monster that WALKED in -- one chasing
// a player, typically -- keeps its INFO line.
const townPlacedPeriod = time.Minute

// removeIfInTown removes m when it stands in a town region: the hub's
// removal, the players whose window holds it told (OpMonsterLeft, after the
// pass), its states and its blocking streak forgotten as a death forgets
// them, and a log line. Its brain, if it has one, is dropped by the pass's
// reconcile like a dead monster's. Called under a.mu, by the pass. placed is
// whether the pass met it standing there (a hatch, a respawn, a GM spawn)
// rather than its step carrying it in.
func (a *monsterAI) removeIfInTown(m combat.Monster, placed bool) bool {
	region, ok := safeRegionAt(m.Zone, m.X, m.Z)
	if !ok {
		return false
	}
	cell := combat.CellOf(m.Zone, m.X, m.Z)
	// The players whose window holds the monster NOW, before it leaves the
	// hub (round 674's review): the leave goes to them as well as to the
	// cell's watchers when it is sent after the pass. A view the area of
	// interest's reconcile moves off the cell in between gets no leave from
	// the reconcile -- the monster is no longer in the hub to be named in
	// its lost cells -- and would keep a ghost body. damageMonsterWatched
	// takes a death's watchers before and after the blow for the same reason.
	watchers := a.watchersOf(cell)
	gone, removed := a.monsters.Remove(m.ID)
	if !removed {
		return false
	}
	chanceMemory.Forget(gone.ID)
	statusFX.forgetMonster(gone.ID)
	// id 0: sent as it is. The monster is gone from the hub, so the
	// alive-and-shown check every other push takes (mayShowLeg) would drop it.
	a.pending = append(a.pending, monsterPush{zone: gone.Zone, cell: cell, also: watchers,
		packet: &proto.Packet{Opcode: OpMonsterLeft, Data: (&MonsterLeft{IDs: []int64{gone.ID}}).Encode()}})
	state, target := "none", int64(0)
	if b := a.brains[gone.ID]; b != nil {
		state, target = b.machine.State().String(), b.target
	}
	rx, ry := worldmap.RegionXY(region.ID)
	how, level := "walked in", slog.LevelInfo
	if placed {
		how, level = "placed there", slog.LevelDebug
		if a.townPlaced == 0 {
			a.townPlacedSince = a.now
		}
		a.townPlaced++
	}
	if a.logger != nil {
		a.logger.Log(context.Background(), level, "monster removed: it entered a town (_RefRegion IsBattleField 0; CGObjMob::SetCurRegion 0x4c1270 -> SetLifeState 3)",
			"monster", gone.ID, "name", gone.Name, "how", how, "state", state, "target", target,
			"region", fmt.Sprintf("%d/%d", rx, ry), "area", region.Area,
			"x", math.Round(gone.X*10)/10, "z", math.Round(gone.Z*10)/10)
	}
	a.tracef("ai: monster %d removed in town region %d/%d (%s), %s", gone.ID, rx, ry, region.Area, how)
	return true
}

// logTownPlaced writes the period's count of monsters removed on placement in
// a town, once townPlacedPeriod has passed since the first of them. Called
// under a.mu, at the end of the pass.
func (a *monsterAI) logTownPlaced() {
	if a.townPlaced == 0 || a.now.Sub(a.townPlacedSince) < townPlacedPeriod {
		return
	}
	if a.logger != nil {
		a.logger.Info("monsters removed on placement in a town (hatched, respawned or spawned there; each at Debug)",
			"count", a.townPlaced, "over_s", math.Round(a.now.Sub(a.townPlacedSince).Seconds()))
	}
	a.townPlaced = 0
}

// watchersOf is the sessions whose window holds cell now: the area of
// interest's watcher index when it runs, else the zone's players by the cell
// each stands in -- deliver's two recipient rules.
func (a *monsterAI) watchersOf(cell combat.Cell) []*gateway.Session {
	if v := aoiFor(a.monsters); v != nil {
		return v.appendWatchers(nil, cell)
	}
	if a.world == nil {
		return nil
	}
	var out []*gateway.Session
	for _, e := range a.world.EntitiesInZone(cell.Zone) {
		if e.Session != nil && combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z).Near(cell, AOIRadius) {
			out = append(out, e.Session)
		}
	}
	return out
}
