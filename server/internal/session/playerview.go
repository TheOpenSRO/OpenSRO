package session

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Players' interest area (round 737, docs/protocol/crowd_scale.md C1).
//
// READ (round 664 and crowd_scale.md section 1, "The server"): retail's
// server keeps every object in a 320-unit message block (CMsgBlock), each
// block linked to its 8 neighbours. An object put in a block is sent, for
// the block and each neighbour, that block's objects as a GROUP SPAWN
// (FUN_00533e70(1): 0x3017 begin, 0x3019 data, 0x3018 end) and is announced
// to that block's players as a SINGLE SPAWN (0x3015, FUN_00533f70); taken
// out, it gets the GROUP DESPAWN of those blocks (FUN_00533e70(2)) and they
// get its SINGLE DESPAWN (0x3016, FUN_00534050). A move is sent only to the
// players of the 3 x 3 blocks around the mover (CMsgBlockObject::
// FUN_00534150). Players included -- until this round OpenSRO showed every
// player to every other in the zone bucket, which under -single-frame is the
// whole world, and listed them all in one EnterWorldResult, which refused the
// arriving session past 166 full-kit players (round 736, MEASURED).
//
// So now:
//   - world.Hub files every player under its block (world.Entity.Cell) and
//     answers who is in the window (world.ViewRadius) without copying the zone.
//   - The arriving player is sent the players of its window as group spawns,
//     one group per block, after its OpEnterWorldResult (whose own list is now
//     empty); they are sent it as a 0x3015. A zone change is the same, after
//     the OpChangeZoneResult, and the window it left gets its 0x3016.
//   - A move that crosses a block line sends the mover the group spawns of
//     the players that came into view and the group despawns of those that
//     went out of it, and sends those players the mover's 0x3015 / 0x3016
//     (the difference of the two windows: the hub's MoveResult).
//   - A leave sends the window the 0x3016.
//
// THE KNOWN SET. Each session that has been through the world entry has a
// playerView: the characters its client holds a body for. Every message about
// a player -- its spawn, despawn, move, motion, body mode, equipment and buffs
// -- reaches a viewer only through the viewer's playerView lock: a spawn only
// when the hub says the two are in view of each other at that moment and the
// client does not hold the body yet, a despawn only when it holds it and they
// are not, anything else only when it holds it. A spawn's record is read from
// the hub (and the motion, berserk and buff books) under that same lock. Every
// change of truth -- a move across a line, an arrival, a leave, a state change
// -- is followed by its own deliveries, so whatever order two goroutines'
// messages reach a viewer's lock in, the client ends holding what the hub
// says, and never hears of a state before the spawn that would carry it or
// after the despawn that took it away. A session with no playerView -- one
// put in the hub directly, as unit tests and the crowd benchmark do -- hears
// everything in its window, as every session heard everything in its zone
// before this round.

// pcGroupChunk is how many body bytes one 0x3019 of a player group carries:
// retail's 4052 (READ, pcGroupChunkRetail).
const pcGroupChunk = pcGroupChunkRetail

// playerView is one session's known set, and the stores its own spawns and
// crossings are built from (the world entry's).
type playerView struct {
	mu    sync.Mutex
	known map[int64]struct{}
	deps  viewDeps
}

// playerViews is every session's view by session id: read once per
// recipient of every move, written at a world entry, a zone change and a
// leave -- a sync.Map, so the reads take no shared lock.
var playerViews sync.Map // uint64 -> *playerView

// startPlayerView gives sessionID a fresh, empty known set: its client has
// just started over (OpEnterWorldResult, OpChangeZoneResult).
func startPlayerView(sessionID uint64, d viewDeps) *playerView {
	d.ctx = context.Background()
	v := &playerView{known: map[int64]struct{}{}, deps: d}
	playerViews.Store(sessionID, v)
	return v
}

// playerViewOf is sessionID's view, nil when it has none.
func playerViewOf(sessionID uint64) *playerView {
	if v, ok := playerViews.Load(sessionID); ok {
		return v.(*playerView)
	}
	return nil
}

// forgetPlayerView drops sessionID's view: it left the world.
func forgetPlayerView(sessionID uint64) {
	playerViews.Delete(sessionID)
}

// sendIfKnown sends fs to sess when its client holds owner's body (or it has
// no view at all). The check and the send are one step under the view's
// lock.
func sendIfKnown(sess *gateway.Session, owner int64, fs ...*gateway.Frame) {
	if sess == nil {
		return
	}
	v := playerViewOf(sess.ID())
	if v == nil {
		_ = sess.SendFrames(fs...)
		return
	}
	v.mu.Lock()
	if _, ok := v.known[owner]; ok {
		_ = sess.SendFrames(fs...)
	}
	v.mu.Unlock()
}

// sendAboutPlayer sends fs to every client that holds owner's body -- the
// players in view of it -- and, with self, to owner's own client. Nothing
// when owner is not in the world.
func sendAboutPlayer(hub *world.Hub, owner int64, self bool, fs ...*gateway.Frame) {
	if hub == nil {
		return
	}
	for _, r := range hub.ViewOfCharacter(owner) {
		if r.CharacterID == owner {
			if self && r.Session != nil {
				_ = r.Session.SendFrames(fs...)
			}
			continue
		}
		sendIfKnown(r.Session, owner, fs...)
	}
}

// sendAboutPlayerPacket is sendAboutPlayer for one packet, encoded once.
func sendAboutPlayerPacket(hub *world.Hub, owner int64, self bool, op uint16, data []byte) {
	f, err := gateway.NewFrame(&proto.Packet{Opcode: op, Data: data})
	if err != nil {
		return
	}
	sendAboutPlayer(hub, owner, self, f)
}

// viewDeps is what a spawn record is built from.
type viewDeps struct {
	ctx   context.Context
	hub   *world.Hub
	eq    equipment.Store
	chars character.Store
	zerk  *berserk.Tracker
}

// playerSpawn is one player's spawn as one delivery builds it: its record
// and the state messages that follow it (its buffs).
type playerSpawn struct {
	e      world.Entity
	record []byte
	after  []*gateway.Frame
}

// buildPlayerSpawn reads e's record and state now. e is re-read from the hub
// by session, so the record carries where it stands at this moment; ok is
// false when it has left.
func buildPlayerSpawn(d viewDeps, e world.Entity, now time.Time) (playerSpawn, bool) {
	cur, ok := d.hub.EntityBySession(e.Session.ID())
	if !ok || cur.CharacterID != e.CharacterID {
		return playerSpawn{}, false
	}
	rec := playerRecord(d, cur, now)
	if rec == nil {
		return playerSpawn{}, false
	}
	return playerSpawn{e: cur, record: rec, after: buffStateFrames(cur.CharacterID, now)}, true
}

// spawnPlayersTo sends viewer the group spawns of those of others that are in
// view of it now and its client does not hold yet, one group per block (the
// window's blocks in order), followed by their buffs; and records them known.
func spawnPlayersTo(d viewDeps, viewer world.Entity, others []world.Entity) {
	if viewer.Session == nil || len(others) == 0 {
		return
	}
	v := playerViewOf(viewer.Session.ID())
	if v == nil {
		return
	}
	now := time.Now()
	v.mu.Lock()
	defer v.mu.Unlock()
	byCell := map[combat.Cell][]playerSpawn{}
	for _, o := range others {
		if o.Session == nil || o.CharacterID == viewer.CharacterID {
			continue
		}
		if _, held := v.known[o.CharacterID]; held {
			continue
		}
		if !d.hub.Sees(viewer.Session.ID(), o.Session.ID()) {
			continue
		}
		s, ok := buildPlayerSpawn(d, o, now)
		if !ok {
			continue
		}
		byCell[s.e.Cell] = append(byCell[s.e.Cell], s)
	}
	if len(byCell) == 0 {
		return
	}
	var frames []*gateway.Frame
	var after []*gateway.Frame
	for _, c := range playerCellsInOrder(byCell) {
		group := byCell[c]
		var body []byte
		for _, s := range group {
			body = append(body, s.record...)
		}
		gfs, err := npcspawn.GroupFrames(npcspawn.GroupSpawn, len(group), body, pcGroupChunk)
		if err != nil {
			continue
		}
		for _, gf := range gfs {
			frames = append(frames, gateway.MustFrame(&proto.Packet{Opcode: gf.Opcode, Data: gf.Data}))
		}
		for _, s := range group {
			v.known[s.e.CharacterID] = struct{}{}
			after = append(after, s.after...)
		}
	}
	_ = viewer.Session.SendFrames(append(frames, after...)...)
}

// spawnPlayerToOthers sends mover's single spawn (0x3015) to each of recips
// that sees it now and does not hold it yet, followed by its buffs, and
// records it known there. The record is built once.
func spawnPlayerToOthers(d viewDeps, mover world.Entity, recips []world.Entity) {
	spawnPlayerToOthersAs(d, mover, recips, false)
}

// spawnPlayerToOthersAs is spawnPlayerToOthers; with again, a recipient that
// already holds mover is sent the spawn too (an arrival: the same character
// on a new session, whose client draws it where it now is).
func spawnPlayerToOthersAs(d viewDeps, mover world.Entity, recips []world.Entity, again bool) {
	if len(recips) == 0 {
		return
	}
	var frames []*gateway.Frame
	built := false
	var version uint64
	for _, r := range recips {
		if r.Session == nil || r.CharacterID == mover.CharacterID {
			continue
		}
		v := playerViewOf(r.Session.ID())
		if v == nil {
			// A session with no view (put in the hub directly) hears the
			// arrival as it heard OpEntityEntered before round 737.
			v = &playerView{known: map[int64]struct{}{}}
		}
		v.mu.Lock()
		if _, held := v.known[mover.CharacterID]; (again || !held) && d.hub.Sees(r.Session.ID(), mover.Session.ID()) {
			// The version is read before the record, so a change between the
			// two rebuilds it at the next recipient at worst.
			if now := playerStateVersion(mover.CharacterID); !built || now != version {
				version = now
				spawn, ok := buildPlayerSpawn(d, mover, time.Now())
				if !ok {
					v.mu.Unlock()
					return
				}
				data := append(append([]byte(nil), spawn.record...), pcSpawnType)
				frames = append([]*gateway.Frame{gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleSpawn, Data: data})}, spawn.after...)
				built = true
			}
			_ = r.Session.SendFrames(frames...)
			v.known[mover.CharacterID] = struct{}{}
		}
		v.mu.Unlock()
	}
}

// despawnPlayersFrom sends viewer the group despawns of those of others its
// client holds and that are not in view of it now, one group per block, and
// forgets them.
func despawnPlayersFrom(d viewDeps, viewer world.Entity, others []world.Entity) {
	if viewer.Session == nil || len(others) == 0 {
		return
	}
	v := playerViewOf(viewer.Session.ID())
	if v == nil {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	byCell := map[combat.Cell][]int64{}
	for _, o := range others {
		if _, held := v.known[o.CharacterID]; !held {
			continue
		}
		if o.Session != nil && d.hub.Sees(viewer.Session.ID(), o.Session.ID()) {
			if cur, ok := d.hub.EntityBySession(o.Session.ID()); ok && cur.CharacterID == o.CharacterID {
				continue
			}
		}
		byCell[o.Cell] = append(byCell[o.Cell], o.CharacterID)
	}
	var frames []*gateway.Frame
	for _, c := range sortedCellsIDs(byCell) {
		ids := byCell[c]
		uids := make([]uint32, len(ids))
		for i, id := range ids {
			uids[i] = uint32(id)
			delete(v.known, id)
		}
		gfs, err := npcspawn.DespawnGroup(uids, pcGroupChunk)
		if err != nil {
			continue
		}
		for _, gf := range gfs {
			frames = append(frames, gateway.MustFrame(&proto.Packet{Opcode: gf.Opcode, Data: gf.Data}))
		}
	}
	if len(frames) > 0 {
		_ = viewer.Session.SendFrames(frames...)
	}
}

// despawnPlayerFromOthers sends gone's single despawn (0x3016) to each of
// recips that holds it and no longer sees it, and forgets it there. gone may
// have left the world.
func despawnPlayerFromOthers(d viewDeps, gone world.Entity, recips []world.Entity) {
	frame := gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(uint32(gone.CharacterID))})
	for _, r := range recips {
		if r.Session == nil || r.CharacterID == gone.CharacterID {
			continue
		}
		v := playerViewOf(r.Session.ID())
		if v == nil {
			// A session with no view heard of gone through the zone's
			// messages before round 737: it hears the despawn as it would
			// have heard OpEntityLeft.
			_ = r.Session.SendFrames(frame)
			continue
		}
		v.mu.Lock()
		if _, held := v.known[gone.CharacterID]; held && !stillSees(d.hub, r, gone) {
			_ = r.Session.SendFrames(frame)
			delete(v.known, gone.CharacterID)
		}
		v.mu.Unlock()
	}
}

// stillSees reports whether r sees gone now: both in the world on those
// sessions, gone as the same character, in view.
func stillSees(hub *world.Hub, r, gone world.Entity) bool {
	if gone.Session == nil {
		return false
	}
	cur, ok := hub.EntityBySession(gone.Session.ID())
	if !ok || cur.CharacterID != gone.CharacterID {
		return false
	}
	return hub.Sees(r.Session.ID(), gone.Session.ID())
}

// arrivePlayer is a player's arrival where others is everyone in view (the
// world entry, a zone change's landing): its client starts with an empty
// view and is sent their group spawns, and they are sent its 0x3015.
func arrivePlayer(d viewDeps, arrived world.Entity, others []world.Entity) {
	startPlayerView(arrived.Session.ID(), d)
	spawnPlayersTo(d, arrived, others)
	spawnPlayerToOthersAs(d, arrived, others, true)
}

// departPlayer sends gone's 0x3016 to each of recips that holds it, whether
// or not it still sees it: gone was taken out of the world and put back
// (a zone change, a warp -- retail's CMsgBlock slot 3 then slot 2), so a
// client that holds it must drop it before its new spawn.
func departPlayer(gone world.Entity, recips []world.Entity) {
	frame := gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(uint32(gone.CharacterID))})
	for _, r := range recips {
		if r.Session == nil || r.CharacterID == gone.CharacterID {
			continue
		}
		v := playerViewOf(r.Session.ID())
		if v == nil {
			_ = r.Session.SendFrames(frame)
			continue
		}
		v.mu.Lock()
		if _, held := v.known[gone.CharacterID]; held {
			_ = r.Session.SendFrames(frame)
			delete(v.known, gone.CharacterID)
		}
		v.mu.Unlock()
	}
}

// afterRelocate delivers a position change the hub has made (r): frame (the
// move's own message) to the mover's watchers that hold it, and to the mover
// itself with self; then, if it crossed a block line, what the crossing owes,
// built from the mover's view's stores (nothing for a session without one).
func afterRelocate(sess *gateway.Session, r world.MoveResult, self bool, frame *gateway.Frame) {
	bumpPlayerState(r.Entity.CharacterID)
	if self && sess != nil {
		_ = sess.SendFrames(frame)
	}
	for _, w := range r.Watchers {
		sendIfKnown(w, r.Entity.CharacterID, frame)
	}
	if !r.Crossed || sess == nil {
		return
	}
	if v := playerViewOf(sess.ID()); v != nil {
		crossPlayer(v.deps, r)
	}
}

// crossPlayer is what a move across a block line owes (world.MoveResult):
// the mover the group despawns of the lost and the group spawns of the
// gained, and those players its 0x3016 / 0x3015.
func crossPlayer(d viewDeps, r world.MoveResult) {
	if !r.Crossed {
		return
	}
	despawnPlayersFrom(d, r.Entity, r.Lost)
	despawnPlayerFromOthers(d, r.Entity, r.Lost)
	spawnPlayersTo(d, r.Entity, r.Gained)
	spawnPlayerToOthers(d, r.Entity, r.Gained)
}

func playerCellsInOrder[T any](m map[combat.Cell]T) []combat.Cell {
	out := make([]combat.Cell, 0, len(m))
	for c := range m {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].X != out[j].X {
			return out[i].X < out[j].X
		}
		return out[i].Z < out[j].Z
	})
	return out
}

func sortedCellsIDs(m map[combat.Cell][]int64) []combat.Cell { return playerCellsInOrder(m) }

// playerStateVersions numbers each player's changes of what its spawn record
// and its spawn's state messages carry (a move, a motion, a body mode, its
// equipment, a buff): bumpPlayerState is called after the change and before
// its delivery. A single spawn built once for many recipients
// (spawnPlayerToOthers) is rebuilt when the number moved under it, so no
// recipient is sent a record older than a change whose own delivery skipped
// it for not holding the body yet.
var playerStateVersions = struct {
	mu sync.Mutex
	m  map[int64]uint64
}{m: map[int64]uint64{}}

func playerStateVersion(id int64) uint64 {
	playerStateVersions.mu.Lock()
	defer playerStateVersions.mu.Unlock()
	return playerStateVersions.m[id]
}

func bumpPlayerState(id int64) {
	playerStateVersions.mu.Lock()
	playerStateVersions.m[id]++
	playerStateVersions.mu.Unlock()
}

func forgetPlayerState(id int64) {
	playerStateVersions.mu.Lock()
	delete(playerStateVersions.m, id)
	playerStateVersions.mu.Unlock()
}

// buffStateFrames is owner's active buffs as the OpBuffStart packets a
// client arriving in view is sent (sendBuffsInView's per-owner part, round
// 616): OpenSRO's buff records ride their own messages, not the spawn
// record's buff list (playerRecord writes none).
func buffStateFrames(owner int64, now time.Time) []*gateway.Frame {
	recs := buffBooks.Active(owner)
	if len(recs) == 0 {
		return nil
	}
	speed := buffBooks.RunSpeed(owner)
	out := make([]*gateway.Frame, 0, len(recs))
	for _, rec := range recs {
		s := uint32(0)
		if buff.Contributes(rec) {
			s = speed
		}
		out = append(out, gateway.MustFrame(&proto.Packet{Opcode: OpBuffStart, Data: buffStartPacket(rec, now, s)}))
	}
	return out
}
