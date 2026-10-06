package session

import (
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// The NPCs' spawn and despawn (round 708). Retail's server creates every NPC
// as an object in a message block, and a player is sent a block's objects as
// a group spawn when the block comes into its 3 x 3 window and a group
// despawn when it goes out -- one group per block (CMsgBlock slot 2 0x534340
// / slot 3 0x5344b0 call FUN_00533e70(1) / (2) per block; docs/protocol/
// npc_spawn.md). The client has no other source of NPCs.
//
// The window is the monsters' (AOIRadius cells of combat.CellSpan around the
// player's cell, round 664), and the runtime rides the monster area of
// interest's tick: monsterAOI.reconcile hands it the entities it just read.
// It keeps, per session, the cell whose window the client holds NPCs for --
// apart from the monster view, which a list request also moves -- and sends
// the difference whenever the player's cell changes: the lost cells' groups
// despawned, then the gained cells' spawned. A player seen for the first
// time, or in another zone than before, is sent its whole window. Every
// frame of one delivery goes in one SendBatch.
//
// The NPCs are static: nothing hatches, dies or walks, so the per-block
// lists never change after InstallNPCs.

// npcGroupChunk is how many body bytes one 0x3019 carries (OURS: retail
// fills what is left of its message buffer less 0x20, FUN_00430a20).
const npcGroupChunk = 4064

// npcZoneReach is how many regions from a zone's centre an NPC is placed in
// that zone's frame when -single-frame is off (OURS: the client loads a
// zone's grid a few regions round its centre).
const npcZoneReach = 3

type npcWorld struct {
	logger *slog.Logger
	byCell map[combat.Cell][]*npcspawn.NPC
	mu     sync.Mutex
	sent   map[uint64]combat.Cell
	// placed counts NPC placements (an NPC in two zone frames counts twice).
	placed int
	// byUID is every placement of an NPC by its unique id (round 727): the
	// 0x7045 select and the 0x7046 open look the target up by the id the
	// client sends, in the selecting player's zone.
	byUID map[uint32][]npcPlacement
}

// npcPlacement is one NPC placed in one zone frame, at x, z of that frame.
type npcPlacement struct {
	zone string
	x, z float64
	npc  *npcspawn.NPC
}

var npcWorldRuntime atomic.Pointer[npcWorld]

// enterWorldBeforeResultHook, when set, runs in the world entry between
// hub.Enter and the OpEnterWorldResult send: a test's way to put an area of
// interest tick in that gap (TestNPCWindowSurvivesATickBeforeTheEntryResult).
// nil in production.
var enterWorldBeforeResultHook func(sess *gateway.Session)

// warpBeforeResultHook, when set, runs in a zone change between the hub's
// change and the OpChangeZoneResult send: a test's way to move another player
// into the mover's new window in that gap (round 737's review, F3). nil in
// production.
var warpBeforeResultHook func(sess *gateway.Session)

// InstallNPCs installs the NPC runtime with npcs, filed under the zone and
// cell each stands in: the one world frame under -single-frame (read now, so
// call it after SetSingleFrame), else every named zone whose centre is
// within npcZoneReach regions. It returns how many placements were filed.
// nil or empty npcs uninstalls it.
func InstallNPCs(npcs []npcspawn.NPC, logger *slog.Logger) int {
	if len(npcs) == 0 {
		npcWorldRuntime.Store(nil)
		return 0
	}
	w := &npcWorld{logger: logger, byCell: map[combat.Cell][]*npcspawn.NPC{}, sent: map[uint64]combat.Cell{},
		byUID: map[uint32][]npcPlacement{}}
	zones := make([]string, 0, len(worldmap.ZoneCentre))
	for z := range worldmap.ZoneCentre {
		zones = append(zones, z)
	}
	sort.Strings(zones)
	for i := range npcs {
		n := &npcs[i]
		if int(n.Region) >= 0x8000 {
			continue // a dungeon region: no frame names it
		}
		rx, ry := worldmap.RegionXY(int(n.Region))
		if SingleFrame() {
			x, z := worldmap.ToWorld(rx, ry, float64(n.X), float64(n.Z), worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
			w.file(combat.CellOf(worldmap.WorldBucket, x, z), n)
			w.byUID[n.UID] = append(w.byUID[n.UID], npcPlacement{zone: worldmap.WorldBucket, x: x, z: z, npc: n})
			continue
		}
		for _, zone := range zones {
			c := worldmap.ZoneCentre[zone]
			if abs(rx-c[0]) > npcZoneReach || abs(ry-c[1]) > npcZoneReach {
				continue
			}
			x, z, ok := worldmap.ToZoneWorld(zone, rx, ry, float64(n.X), float64(n.Z))
			if ok {
				w.file(combat.CellOf(zone, x, z), n)
				w.byUID[n.UID] = append(w.byUID[n.UID], npcPlacement{zone: zone, x: x, z: z, npc: n})
			}
		}
	}
	for _, list := range w.byCell {
		sort.Slice(list, func(i, j int) bool { return list[i].UID < list[j].UID })
	}
	npcWorldRuntime.Store(w)
	return w.placed
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func (w *npcWorld) file(c combat.Cell, n *npcspawn.NPC) {
	w.byCell[c] = append(w.byCell[c], n)
	w.placed++
}

// window is the cells of the window centred on c.
func window(c combat.Cell) []combat.Cell {
	out := make([]combat.Cell, 0, (2*AOIRadius+1)*(2*AOIRadius+1))
	for x := c.X - AOIRadius; x <= c.X+AOIRadius; x++ {
		for z := c.Z - AOIRadius; z <= c.Z+AOIRadius; z++ {
			out = append(out, combat.Cell{Zone: c.Zone, X: x, Z: z})
		}
	}
	return out
}

// reconcile sends each player in ents what its NPC window owes it, and
// forgets the sessions no longer in the world.
func (w *npcWorld) reconcile(ents []world.Entity) {
	type owed struct {
		sess         *gateway.Session
		gained, lost []combat.Cell
		character    int64
		cell         combat.Cell
	}
	var todo []owed
	w.mu.Lock()
	present := make(map[uint64]struct{}, len(ents))
	for _, e := range ents {
		if e.Session == nil {
			continue
		}
		id := e.Session.ID()
		present[id] = struct{}{}
		cell := combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z)
		prev, had := w.sent[id]
		if had && prev == cell {
			continue
		}
		o := owed{sess: e.Session, character: e.CharacterID, cell: cell}
		switch {
		case !had:
			o.gained = window(cell)
		case prev.Zone != cell.Zone:
			o.lost, o.gained = window(prev), window(cell)
		default:
			o.gained, o.lost = windowDiff(prev, cell, AOIRadius)
		}
		w.sent[id] = cell
		todo = append(todo, o)
	}
	for id := range w.sent {
		if _, ok := present[id]; !ok {
			delete(w.sent, id)
		}
	}
	w.mu.Unlock()
	for _, o := range todo {
		frames, spawned, despawned := w.frames(o.gained, o.lost)
		if len(frames) == 0 {
			continue
		}
		if err := o.sess.SendBatch(frames...); err != nil {
			// Not sent (round 708's review, LOW 1): forget the window, so a
			// session that is still there is sent it whole next tick.
			w.mu.Lock()
			if w.sent[o.sess.ID()] == o.cell {
				delete(w.sent, o.sess.ID())
			}
			w.mu.Unlock()
			continue
		}
		if w.logger != nil {
			w.logger.Info("npc: window moved", "character", o.character, "zone", o.cell.Zone,
				"cell", fmt.Sprintf("%d,%d", o.cell.X, o.cell.Z), "spawned", spawned, "despawned", despawned)
		}
	}
}

// frames is one delivery: for each lost cell holding NPCs a group despawn,
// then for each gained one a group spawn -- preceded by OpNpcFacingUnknown
// when some of its NPCs have no nest angle.
func (w *npcWorld) frames(gained, lost []combat.Cell) (out []*proto.Packet, spawned, despawned int) {
	add := func(fs []npcspawn.GroupFrame) {
		for _, f := range fs {
			out = append(out, &proto.Packet{Opcode: f.Opcode, Data: f.Data})
		}
	}
	for _, c := range sortedCells(lost) {
		list := w.byCell[c]
		if len(list) == 0 {
			continue
		}
		uids := make([]uint32, len(list))
		for i, n := range list {
			uids[i] = n.UID
		}
		fs, err := npcspawn.DespawnGroup(uids, npcGroupChunk)
		if err != nil {
			continue
		}
		add(fs)
		despawned += len(uids)
	}
	for _, c := range sortedCells(gained) {
		list := w.byCell[c]
		if len(list) == 0 {
			continue
		}
		recs := make([]npcspawn.Record, len(list))
		var unfaced []uint32
		for i, n := range list {
			recs[i] = n.Record
			if n.Source != npcspawn.FromNest {
				unfaced = append(unfaced, n.UID)
			}
		}
		if len(unfaced) > 0 {
			out = append(out, &proto.Packet{Opcode: npcspawn.OpNpcFacingUnknown, Data: npcspawn.FacingUnknown(unfaced)})
		}
		fs, err := npcspawn.SpawnGroup(recs, npcGroupChunk)
		if err != nil {
			continue
		}
		add(fs)
		spawned += len(recs)
	}
	return out, spawned, despawned
}

func sortedCells(cells []combat.Cell) []combat.Cell {
	out := append([]combat.Cell(nil), cells...)
	sort.Slice(out, func(i, j int) bool {
		if out[i].X != out[j].X {
			return out[i].X < out[j].X
		}
		return out[i].Z < out[j].Z
	})
	return out
}

// forgetNPCWindow drops what the NPC window sent session id, so its next
// reconcile sends the whole window (a world entry: the client cleared its
// roster).
func forgetNPCWindow(id uint64) {
	if w := npcWorldRuntime.Load(); w != nil {
		w.mu.Lock()
		delete(w.sent, id)
		w.mu.Unlock()
	}
}

// npcInZone is the placement of the NPC with unique id uid in zone, if the
// NPC runtime is installed and the NPC stands in that zone's frame.
func npcInZone(uid uint32, zone string) (npcPlacement, bool) {
	w := npcWorldRuntime.Load()
	if w == nil {
		return npcPlacement{}, false
	}
	for _, p := range w.byUID[uid] {
		if p.zone == zone {
			return p, true
		}
	}
	return npcPlacement{}, false
}

// NPCsInWindow is how many NPC placements the window centred on cell holds
// (tests and the boot log).
func NPCsInWindow(cell combat.Cell) int {
	w := npcWorldRuntime.Load()
	if w == nil {
		return 0
	}
	n := 0
	for _, c := range window(cell) {
		n += len(w.byCell[c])
	}
	return n
}
