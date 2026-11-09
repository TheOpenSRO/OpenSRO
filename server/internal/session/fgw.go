package session

// The Forgotten World on the server (round 869, lane W3;
// docs/protocol/forgotten_world.md 11 SERVER items 2-3): the Dimension hole's
// use in town and the gate it makes. Labels: READ (s: the game server, c: the
// client), MEASURED, INFERRED, OURS, OPEN.
//
// The hole (TypeID 3/3/12/7), in the READ order of GObjPC::FUN_004a08e0:
//
//  1. outside a safe zone (a town region)                 0x184b
//  2. the level outside the item's Param3..Param4           0x1851
//  3. Param6 = 7 only: not in a party, or not its master    0x184f
//  4. the world job: no free layer 0x1852, any other failure 0x183e
//
// then the item and its cool time (group 0x71, 5 h) are spent and the
// replies go out in the MEASURED order: the use's success (retail's 0xB04C;
// OpenSRO's OpUseItemResult, OURS opcode), 0x305C {u32 user, u32 item} to the
// user and the players around it, 0xB034 {01, 0x0F, u8 slot, 02} (the bag
// slot emptied), then the gate's single spawn 0x3015. MEASURED: the gate
// came 41 ms and 111 ms after the request in two measurements -- the shard
// manager's world-job round trip (INFERRED); OpenSRO opens the layer in
// process and sends the spawn at once, after the 0xB034.
//
// The gate (forgotten_world.md 4) is a structure in the open world at the
// creator's position, a random yaw (READ s:0x5f8aa0: rand()/32767 x 360 deg),
// with the access type of the hole's Param6 in its record. It lives exactly
// as long as its layer (READ; MEASURED 601.0 s / 604.9 s to its 0x3016 with
// nobody inside): the layer's close removes it. Its spawn reaches everyone
// in view (MEASURED: another party member got the record and did not draw
// it -- the type-6 / type-7 drawing rule is the client's, READ c:0x9e9eb0).
// Selecting it, 0x7045 {u32 gate}, answers the MEASURED 0xB045 {01, u32 gate,
// 01, 1c, 01, 02, u16 region, i32 x, y, z}: one interaction (0x1c, a
// teleport) with one kind-2 destination, the world's start. The select sets
// no interaction state (MEASURED: the next 0x704B answers {02, 0x1c0d}).
// Entering is the portal teleport 0x705A {gate, 3, 0} (gameworlds_run.go).

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// TimedJobItemCoolTime is an item cool time kept across a relog: MEASURED, a
// hole's use added a _TimedJob row of category 6 holding the item's id and
// 18,000,000. Its row keeps the item in Ref, the cool group in Key, the use in
// Start and the end in End (OpenSRO keeps only the hole's; the other items'
// cool times stay in memory, as before).
const TimedJobItemCoolTime = 6

// The bag slot's emptying after the hole's use (MEASURED 0xB034 {01, 0x0F,
// u8 slot, 02}: type 0x0F; the trailing 02 is OPEN, INFERRED the reason
// "used").
const (
	ItemMoveConsumed   byte = 0x0F
	itemConsumedReason byte = 2
)

// holeOf is it as a Dimension hole.
func holeOf(it *refdata.Item) (gameworld.Hole, bool) {
	if it == nil {
		return gameworld.Hole{}, false
	}
	// The item table's Param block: Param1 (RestoreHP's column) the grade,
	// Param3 / Param4 (RestoreMP / RestoreMPPct's) the band -- columns 118,
	// 122, 124 (refdata.Item.RestoreHP's note) -- Param5, Param6, Desc2.
	return gameworld.HoleOf(gameworld.HoleItem{ID: it.ID, TypeID1: it.TypeID1, TypeID2: it.TypeID2, TypeID3: it.TypeID3,
		TypeID4: it.TypeID4, Code: it.CodeName, Desc2: it.Desc2, Param1: int(it.Param1), Param3: it.RestoreMP,
		Param4: it.RestoreMPPct, Param5: it.Param5, Param6: it.Param6, CoolGroup: it.CooltimeGroup, CoolMs: it.CooltimeMs})
}

// isDimensionHole reports a hole item (TypeID 3/3/12/7).
func isDimensionHole(it *refdata.Item) bool {
	return it != nil && gameworld.IsHoleType(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4)
}

// fgwTown is the hole's safe-zone test seam; nil reads the region table.
var fgwTown func(e world.Entity) bool

// fgwInTown is the hole's town test: a region whose IsBattleField is 0
// (READ s:0x4a08e0's safe-zone check). With no region table loaded every
// place passes (OURS, as the stall network's test).
func fgwInTown(e world.Entity) bool {
	if f := fgwTown; f != nil {
		return f(e)
	}
	return stallNetInTown(e)
}

// fgwClock is the hole's and the recall's clock (a test seam).
var fgwClock = time.Now

// holeRefusal answers a hole's refusal: OpenSRO's use result with the code
// (the client's category-1 table, as the scrolls' codes; 0x184b has no text
// case there, READ).
func holeRefusal(sess *gateway.Session, code uint16) error {
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: fmt.Sprintf("dimension hole refused %#04x", code), Code: code}).Encode()})
}

// useDimensionHole is the hole's use (the package note): the checks, the
// layer, the spend, the replies and the gate.
func useDimensionHole(ctx context.Context, sess *gateway.Session, hub *world.Hub, inv inventory.Store, note *useNote,
	characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	hole, ok := holeOf(it)
	m := GameWorlds()
	if !ok || m == nil {
		return holeRefusal(sess, gameworld.CodeHoleOther)
	}
	ref := m.Ref().WorldByCode(hole.World)
	if ref == nil || !ref.Instanced() {
		return holeRefusal(sess, gameworld.CodeHoleOther)
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok {
		return holeRefusal(sess, gameworld.CodeHoleOther)
	}
	// 1. A town (READ: first).
	if !fgwInTown(e) {
		return holeRefusal(sess, gameworld.CodeHoleNotTown)
	}
	// 2. The item's band (Param3..Param4; the world's own when the row has
	// none).
	lo, hi := hole.LevelMin, hole.LevelMax
	if lo == 0 && hi == 0 {
		lo, hi = ref.Config.LevelMin, ref.Config.LevelMax
	}
	if (lo > 0 && e.Level < lo) || (hi > 0 && e.Level > hi) {
		return holeRefusal(sess, gameworld.CodeHoleLevel)
	}
	// 3. A party gate: the user must be the party's master.
	var partyID uint32
	if ps := gameWorldDeps().Parties; ps != nil {
		if p, in := ps.Get(characterID); in {
			partyID = p.ID
			if hole.Access == gameworld.AccessParty && p.LeaderID != characterID {
				return holeRefusal(sess, gameworld.CodeHolePartyMaster)
			}
		} else if hole.Access == gameworld.AccessParty {
			return holeRefusal(sess, gameworld.CodeHolePartyMaster)
		}
	} else if hole.Access == gameworld.AccessParty {
		return holeRefusal(sess, gameworld.CodeHolePartyMaster)
	}
	// The cool time (the client refuses it first, with no packet: MEASURED).
	now := fgwClock()
	if hole.CoolTime > 0 && !itemCooldowns.ReadyItem(characterID, it.ID, hole.CoolGroup, now) {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reuseDelayRefusal, Code: gameworld.CodeHoleCoolTime}).Encode()})
	}
	// 4. The world job: a new layer (game_worlds.md 4: the layer is made at
	// the use, READ; MEASURED, the gate appears at the use).
	w, err := m.Open(ctx, ref.ID, characterID, int64(partyID))
	if err != nil {
		if errors.Is(err, registry.ErrNoSlot) {
			return holeRefusal(sess, gameworld.CodeHoleNoLayer)
		}
		return holeRefusal(sess, gameworld.CodeHoleOther)
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		w.CloseAsync(gameworld.CloseManual)
		return holeRefusal(sess, gameworld.CodeHoleOther)
	}
	if hole.CoolTime > 0 {
		armHoleCoolTime(ctx, characterID, it.ID, hole, now)
	}
	if err := sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)}).Encode()}); err != nil {
		return err
	}
	// 0x305C now, ahead of the 0xB034 (MEASURED order); announceUses then
	// sends none of its own.
	broadcastItemUse(hub, characterID, it.ID)
	note.refItemID = 0
	_ = sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: []byte{itemOpOK, ItemMoveConsumed, byte(held.Index + ItemWireBagOffset), itemConsumedReason}})
	g := makeGate(hub, e, w, hole, partyID)
	if l := gameWorldDeps().Logger; l != nil {
		l.Info("dimension hole used", "character_id", characterID, "item", it.CodeName, "world", w.ID.String(), "gate", fmt.Sprintf("%#x", g.UID),
			"access", hole.Access, "zone", e.Zone, "x", e.Pos.X, "z", e.Pos.Z)
	}
	return nil
}

// armHoleCoolTime arms the hole's cool-time group and keeps it as a timed
// job (MEASURED: _TimedJob category 6, the item's id, 18,000,000).
func armHoleCoolTime(ctx context.Context, characterID, itemID int64, hole gameworld.Hole, now time.Time) {
	itemCooldowns.ArmItem(characterID, itemID, hole.CoolGroup, hole.CoolTime, now)
	if st := gameWorldDeps().Timed; st != nil {
		_ = st.Put(ctx, timedjob.Job{CharID: characterID, Type: TimedJobItemCoolTime, Ref: itemID, Key: int64(hole.CoolGroup),
			Start: now, End: now.Add(hole.CoolTime)})
	}
}

// restoreItemCoolTimes re-arms the kept item cool times at a world entry.
func restoreItemCoolTimes(ctx context.Context, characterID int64, now time.Time) {
	st := gameWorldDeps().Timed
	if st == nil {
		return
	}
	jobs, err := st.List(ctx, characterID)
	if err != nil {
		return
	}
	for _, j := range jobs {
		if j.Type == TimedJobItemCoolTime && now.Before(j.End) {
			itemCooldowns.ArmItem(characterID, j.Ref, uint32(j.Key), j.End.Sub(now), now)
		}
	}
}

// fgwGate is one Dimension-hole gate standing in the open world.
type fgwGate struct {
	UID    uint32
	World  *gameworld.World
	Hole   gameworld.Hole
	Owner  int64
	Name   string
	Party  uint32
	Access uint8
	// hub, zone and pos are where it stands in the open world's terms; the
	// region and local point are its record's.
	hub    *world.Hub
	zone   string
	pos    world.Position
	region uint16
	lx, lz float64
	angle  uint16
}

// gates is every standing gate, and per session the gates its client holds.
var gates = struct {
	mu    sync.Mutex
	byUID map[uint32]*fgwGate
	sent  map[uint64]map[uint32]bool
	count atomic.Int32
}{byUID: map[uint32]*fgwGate{}, sent: map[uint64]map[uint32]bool{}}

// gateUIDSeq numbers the gates (OURS range 0x7d400000..0x7d7fffff, beside
// the event zones' 0x7d000000..0x7d3fffff).
var gateUIDSeq atomic.Uint32

const gateUIDBase uint32 = 0x7d400000

// gateRand is the gate's yaw source (a test seam).
var gateRand = rand.New(rand.NewSource(time.Now().UnixNano()))
var gateRandMu sync.Mutex

// gateYaw is READ s:0x5f8aa0's random yaw, rand()/32767 x 360 deg, as the
// record's u16 (65536 to a turn).
func gateYaw() uint16 {
	gateRandMu.Lock()
	r := gateRand.Intn(32768)
	gateRandMu.Unlock()
	return uint16(float64(r) / 32767.0 * 65535.0)
}

// makeGate stands a gate for layer w at e, files its portal and spawns it to
// the players in view.
func makeGate(hub *world.Hub, e world.Entity, w *gameworld.World, hole gameworld.Hole, party uint32) *fgwGate {
	region, lx, lz := regionLocalOf(e.Zone, e.Pos)
	g := &fgwGate{UID: gateUIDBase + gateUIDSeq.Add(1)&0x003fffff, World: w, Hole: hole, Owner: e.CharacterID, Name: e.Name,
		Party: party, Access: hole.Access, hub: hub, zone: e.Zone, pos: e.Pos, region: region, lx: lx, lz: lz, angle: gateYaw()}
	RegisterPortal(&Portal{UID: g.UID, World: w, Access: g.Access, Owner: g.Owner, Party: int64(g.Party), Destinations: 1})
	gates.mu.Lock()
	gates.byUID[g.UID] = g
	gates.count.Store(int32(len(gates.byUID)))
	gates.mu.Unlock()
	reconcileGates(hub, hub.AllEntities())
	return g
}

// record is the gate's spawn record (forgotten_world.md 4).
func (g *fgwGate) record() gameworld.StructureRecord {
	r := gameworld.StructureRecord{RefObjID: gameworld.GateRefObjID, UID: g.UID, Region: g.region,
		X: float32(g.lx), Y: float32(g.pos.Y), Z: float32(g.lz), Angle: g.angle, B260: 1, State: 0,
		Gate: &gameworld.GateTail{Restricted: 1, Access: g.Access, HoleRefID: g.Hole.RefID}}
	if g.Access == gameworld.AccessParty {
		r.Gate.PartyID = g.Party
	} else {
		r.Gate.OwnerName = g.Name
	}
	return r
}

// gateInView reports whether e's window holds the gate (the NPCs' window:
// AOIRadius cells of the player's cell, npcworld.go).
func gateInView(g *fgwGate, e world.Entity) bool {
	if e.Zone != g.zone {
		return false
	}
	return combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z).Near(combat.CellOf(g.zone, g.pos.X, g.pos.Z), AOIRadius)
}

// reconcileGates sends each player of hub the spawns (0x3015) of the gates
// come into its window and the despawns (0x3016) of those gone out of it,
// and forgets the sessions no longer there. It rides the open world's area
// of interest tick (aoi.go) and runs at once when a gate stands or goes.
func reconcileGates(hub *world.Hub, ents []world.Entity) {
	doors := placedDoors(hub)
	if gates.count.Load() == 0 && len(doors) == 0 && !gatesOwed() {
		return
	}
	type send struct {
		sess *gateway.Session
		pkts []*proto.Packet
	}
	var todo []send
	gates.mu.Lock()
	for _, e := range ents {
		if e.Session == nil {
			continue
		}
		id := e.Session.ID()
		have := gates.sent[id]
		var pkts []*proto.Packet
		uids := make([]uint32, 0, len(gates.byUID))
		for uid := range gates.byUID {
			uids = append(uids, uid)
		}
		sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
		for _, uid := range uids {
			g := gates.byUID[uid]
			if g.hub != hub {
				continue
			}
			in := gateInView(g, e)
			switch {
			case in && !have[uid]:
				if have == nil {
					have = map[uint32]bool{}
					gates.sent[id] = have
				}
				have[uid] = true
				pkts = append(pkts, &proto.Packet{Opcode: npcspawn.OpSingleSpawn, Data: g.record().Encode(true)})
			case !in && have[uid]:
				delete(have, uid)
				pkts = append(pkts, &proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(uid)})
			}
		}
		// Round 870: the layer's trigger doors, the same window (doors.go).
		for _, d := range doors {
			in := e.Zone == d.zone && combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z).Near(combat.CellOf(d.zone, d.pos.X, d.pos.Z), AOIRadius)
			switch {
			case in && !have[d.uid]:
				if have == nil {
					have = map[uint32]bool{}
					gates.sent[id] = have
				}
				have[d.uid] = true
				pkts = append(pkts, &proto.Packet{Opcode: npcspawn.OpSingleSpawn, Data: d.record.Encode(true)})
			case !in && have[d.uid]:
				delete(have, d.uid)
				pkts = append(pkts, &proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(d.uid)})
			}
		}
		// A gate removed (its layer closed) since this client got it.
		for uid := range have {
			if isDoorUID(uid) {
				continue
			}
			if _, standing := gates.byUID[uid]; !standing {
				delete(have, uid)
				pkts = append(pkts, &proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(uid)})
			}
		}
		if len(pkts) > 0 {
			todo = append(todo, send{e.Session, pkts})
		}
	}
	gates.mu.Unlock()
	for _, s := range todo {
		_ = s.sess.SendBatch(s.pkts...)
	}
}

// gatesOwed reports a client still holding a gate that no longer stands.
func gatesOwed() bool {
	gates.mu.Lock()
	defer gates.mu.Unlock()
	for _, have := range gates.sent {
		for uid := range have {
			if isDoorUID(uid) {
				continue
			}
			if _, ok := gates.byUID[uid]; !ok {
				return true
			}
		}
	}
	return false
}

// forgetGateWindow drops what a session was sent (a world entry: the client
// cleared its roster; a disconnect).
func forgetGateWindow(id uint64) {
	gates.mu.Lock()
	delete(gates.sent, id)
	gates.mu.Unlock()
}

// removeGatesOf takes w's gates down with the layer (READ: the gate lives as
// long as its layer; MEASURED 0x3016 to everyone who had it).
func removeGatesOf(w *gameworld.World) {
	var hubs []*world.Hub
	gates.mu.Lock()
	for uid, g := range gates.byUID {
		if g.World == w {
			delete(gates.byUID, uid)
			UnregisterPortal(uid)
			hubs = append(hubs, g.hub)
		}
	}
	gates.count.Store(int32(len(gates.byUID)))
	gates.mu.Unlock()
	for _, h := range hubs {
		reconcileGates(h, h.AllEntities())
	}
}

// gateOf is the standing gate uid, nil for none.
func gateOf(uid uint32) *fgwGate {
	gates.mu.Lock()
	defer gates.mu.Unlock()
	return gates.byUID[uid]
}

// EncodeGateSelect is the gate's 0xB045 (MEASURED): {01, u32 gate, 01 (one
// interaction), 1c (a teleport), 01 (one destination), 02 (kind 2), u16
// region, i32 x, i32 y, i32 z} -- the world's start position.
func EncodeGateSelect(uid uint32, start gameworld.StartPos) []byte {
	b := []byte{npctalk.ResultOK}
	b = binary.LittleEndian.AppendUint32(b, uid)
	b = append(b, 1, gameworld.GateInteraction, 1, gameworld.GateDestinationKind)
	b = binary.LittleEndian.AppendUint16(b, start.Region)
	b = binary.LittleEndian.AppendUint32(b, uint32(int32(start.X)))
	b = binary.LittleEndian.AppendUint32(b, uint32(int32(start.Y)))
	return binary.LittleEndian.AppendUint32(b, uint32(int32(start.Z)))
}

// gateSelect answers a 0x7045 naming a gate; false when entity is no gate.
// Out of reach is the NPCs' range code (INFERRED, npctalk.CodeTooFar).
func gateSelect(sess *gateway.Session, e world.Entity, entity uint32) bool {
	g := gateOf(entity)
	if g == nil {
		return false
	}
	if g.zone != e.Zone {
		sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeNoTarget))
		return true
	}
	dx, dy, dz := g.pos.X-e.Pos.X, g.pos.Y-e.Pos.Y, g.pos.Z-e.Pos.Z
	if math.Sqrt(dx*dx+dy*dy+dz*dz) > gameworld.GateRange {
		sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeTooFar))
		return true
	}
	if len(g.World.Ref.Starts) == 0 {
		sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeNoTarget))
		return true
	}
	sendNPCTalk(sess, npctalk.OpSelectResult, EncodeGateSelect(g.UID, g.World.Ref.Starts[0]))
	return true
}
