package session

// Dungeons (round 773): a place whose region id has bit 15 set -- the
// Donwhang cave (0x8001), the Qin-Shi tomb's six floors (0x8002..0x8007), and
// the instanced ones OpenSRO still refuses. docs/protocol/dungeon.md.
//
// READ: a dungeon has no region grid. Its positions are (region id, x, y, z)
// with x, y, z absolute in the dungeon's own space (the .dof's; teleportdata's
// and npcpos's dungeon rows are in it, and the client's minimap reads the
// player's dungeon x and z as such, UI_SILKMALL::FUN_00661ce0 0x661ce0). The
// movement packet carries them as three i32 behind a region word with bit 15
// (proto.Movement, round 737).
//
// OURS, the contract with the client (client/scripts/dungeon/):
//
//   - the zone label is worldmap.DungeonZone(rid), "dungeon/32769", which is
//     also the FrameRegion a result names and the hub bucket (never the one
//     world's, -single-frame or not: FrameFor has no frame for it);
//   - a world point in a dungeon is (dx, dy, -dz) of dungeon space, the field
//     frames' single z mirror, so the client stands the player at the
//     result's X, Y, Z as it does in the field;
//   - region-coded wire positions (spawn records, 0xB023, the echo's source,
//     party positions) carry the rid and dungeon-space x, y, z;
//   - a zone change, unstuck or saved place that names a dungeon with no
//     point of its own lands at the dungeon's entry (dungeonEntry).

import (
	"sort"
	"sync/atomic"

	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// dungeonEntries is each served dungeon's entry, in world coordinates, by
// rid (bit 15 set): installed from the teleport network at boot
// (InstallDungeonEntries). nil until then: no dungeon is served.
var dungeonEntries atomic.Pointer[map[int]world.Position]

// InstallDungeonEntries records the dungeons OpenSRO serves -- every rid a
// main-world teleport point stands in -- and each one's entry (OURS): the
// destination point of a link that starts in the open field (Donwhang's
// GATE_DUNGEON_DH_OUT, the tomb's GATE_JINSI_IN), else the lowest-id point of
// the dungeon that some link lands on (the tomb's lower floors, entered from
// the floor above). TeleportHandler calls it; tests and cmd/server may too.
// A nil network clears it.
func InstallDungeonEntries(network *teleport.Table) {
	if network == nil {
		dungeonEntries.Store(nil)
		return
	}
	type cand struct {
		fromField bool
		id        int
		pos       world.Position
	}
	best := map[int]cand{}
	for _, l := range network.Links {
		from, okF := network.PointByID(l.From)
		to, okT := network.PointByID(l.To)
		if !okF || !okT || !worldmap.IsDungeonRegion(to.Region) || !inOpenWorld(to) {
			continue
		}
		if to.X == 0 && to.Y == 0 && to.Z == 0 {
			continue
		}
		rid := worldmap.DungeonRID(to.Region)
		x, y, z := worldmap.DungeonToWorld(float64(to.X), float64(to.Y), float64(to.Z))
		c := cand{fromField: !worldmap.IsDungeonRegion(from.Region) && inOpenWorld(from), id: to.ID, pos: world.Position{X: x, Y: y, Z: z}}
		old, seen := best[rid]
		if !seen || (c.fromField && !old.fromField) || (c.fromField == old.fromField && c.id < old.id) {
			best[rid] = c
		}
	}
	out := make(map[int]world.Position, len(best))
	for rid, c := range best {
		out[rid] = c.pos
	}
	dungeonEntries.Store(&out)
}

// dungeonEntry is the entry of the dungeon whose rid is rid; ok is false for
// a dungeon OpenSRO does not serve.
func dungeonEntry(rid int) (world.Position, bool) {
	m := dungeonEntries.Load()
	if m == nil {
		return world.Position{}, false
	}
	p, ok := (*m)[worldmap.DungeonRID(rid)]
	return p, ok
}

// ServedDungeons lists the rids InstallDungeonEntries recorded, sorted.
func ServedDungeons() []int {
	m := dungeonEntries.Load()
	if m == nil {
		return nil
	}
	out := make([]int, 0, len(*m))
	for rid := range *m {
		out = append(out, rid)
	}
	sort.Ints(out)
	return out
}

// ServedDungeon reports whether rid (signed or not) is a dungeon OpenSRO
// serves: one a main-world teleport point stands in. cmd/server places
// monsters and NPCs only in these.
func ServedDungeon(rid int) bool {
	_, ok := dungeonEntry(rid)
	return ok
}

// dungeonOf is the rid of the dungeon a zone label or hub bucket names.
func dungeonOf(zone string) (int, bool) {
	return worldmap.ParseDungeonZone(zone)
}

// dungeonLocal is a world point in a dungeon as the dungeon's own x, z.
func dungeonLocal(pos world.Position) (dx, dz float64) {
	x, _, z := worldmap.WorldToDungeon(pos.X, pos.Y, pos.Z)
	return x, z
}
