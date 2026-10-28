package session

import (
	"context"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
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
// FUN_00534150). Players included -- until round 737 OpenSRO showed every
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
// THE KNOWN SET. Each character in the world on a session has a playerView,
// keyed by CHARACTER id (round 737's review: a session id is unique only
// within one process): the session it is for and the characters its client
// holds a body for. Every message about a player -- its spawn, despawn, move,
// motion, body mode, equipment, buffs, status and casts -- reaches a viewer
// only through the viewer's view lock: a spawn only when the view is OPEN,
// the hub says the two see each other at that moment and the client does not
// hold the body yet; a despawn only when it holds it and they do not;
// anything else only when it holds it. Every change of truth -- a move across
// a line, an arrival, a leave, a state change -- is followed by its own
// deliveries, so whatever order two goroutines' messages reach a viewer's
// lock in, the client ends holding what the hub says.
//
// A view is CLOSED from just before its character is put in the hub (a world
// entry, a zone change) until its result has been sent: nothing about another
// player reaches it then, and a player who comes into view in that gap is
// spawned when the view opens, from the hub's window read after it opened
// (round 737's review, F3: the gap used to drop such a spawn for good).
//
// A session with no view at all -- one put in the hub directly, as unit tests
// do -- is sent no spawn or despawn, and hears every other message in its
// window, as every session heard everything in its zone before round 737.

// pcGroupChunk is how many body bytes one 0x3019 of a player group carries:
// retail's 4052 (READ, pcGroupChunkRetail).
const pcGroupChunk = pcGroupChunkRetail

// playerView is one character's known set on one session, and the stores its
// own spawns and crossings are built from (the world entry's).
type playerView struct {
	mu    sync.Mutex
	sess  *gateway.Session
	open  bool
	known map[int64]uint64 // character id -> its world.Entity.Arrival when spawned here
	deps  viewDeps
}

// playerViews is every in-world character's view by character id: read once
// per recipient of every move, written at a world entry, a zone change and a
// leave -- a sync.Map, so the reads take no shared lock.
var playerViews sync.Map // int64 -> *playerView

// closePlayerView gives characterID on sess a closed, empty view: it is about
// to be put in the hub (or moved to another zone) and its client has not had
// its result yet. It replaces any view the character had, on this session or
// a stale one. It carries the stores its own crossings are built from, as an
// open view does (round 737's verification, N1: a closed view with none
// panicked a crossing on a nil hub).
func closePlayerView(characterID int64, sess *gateway.Session, d viewDeps) {
	playerViews.Store(characterID, closedView(sess, d))
}

func closedView(sess *gateway.Session, d viewDeps) *playerView {
	d.ctx = context.Background()
	return &playerView{sess: sess, known: map[int64]uint64{}, deps: d}
}

// liveOn reports whether sess is the hub's session for characterID: false
// for a stale session of a reconnect, whose entity the hub still holds by
// session after the new one took the character (world.Hub.Enter).
func liveOn(hub *world.Hub, characterID int64, sess *gateway.Session) bool {
	if hub == nil || sess == nil {
		return false
	}
	cur, ok := hub.EntityByCharacterID(characterID)
	return ok && cur.Session == sess
}

// storeViewIfLive makes v characterID's view only while sess is the hub's
// session for the character (round 737's verification, N4): a stale
// session's zone change or arrival must not take the view from the live one.
// The hub is read between the load and the swap, so a newer session that
// took the character after the read finds its own view kept: its close comes
// before its hub entry, its open after.
func storeViewIfLive(hub *world.Hub, characterID int64, sess *gateway.Session, v *playerView) bool {
	for {
		cur, loaded := playerViews.Load(characterID)
		if !liveOn(hub, characterID, sess) {
			return false
		}
		if !loaded {
			if _, raced := playerViews.LoadOrStore(characterID, v); !raced {
				return true
			}
			continue
		}
		if playerViews.CompareAndSwap(characterID, cur, v) {
			return true
		}
	}
}

// openedView is a fresh, empty, open view on sess: its client has just
// started over (OpEnterWorldResult, OpChangeZoneResult; arrivePlayer).
func openedView(sess *gateway.Session, d viewDeps) *playerView {
	d.ctx = context.Background()
	return &playerView{sess: sess, open: true, known: map[int64]uint64{}, deps: d}
}

// playerViewOf is characterID's view, nil when it has none.
func playerViewOf(characterID int64) *playerView {
	if v, ok := playerViews.Load(characterID); ok {
		return v.(*playerView)
	}
	return nil
}

// viewFor is the view of characterID on sess: nil when the character has
// none, or has one for another session (a stale session of a reconnect).
func viewFor(sess *gateway.Session, characterID int64) (v *playerView, other bool) {
	v = playerViewOf(characterID)
	if v == nil {
		return nil, false
	}
	if v.sess != sess {
		return nil, true
	}
	return v, false
}

// forgetPlayerView drops characterID's view when it is sess's: the session
// left the world. A newer session's view (a reconnect that entered first) is
// left alone.
func forgetPlayerView(characterID int64, sess *gateway.Session) {
	if v := playerViewOf(characterID); v != nil && v.sess == sess {
		playerViews.CompareAndDelete(characterID, v)
	}
}

// sendIfKnown sends fs to the client of recipient (its session and character)
// when it holds owner's body. A session with no view at all hears it (the
// unit tests' sessions); a closed view, or one for another session, does not.
// The check and the send are one step under the view's lock.
func sendIfKnown(sess *gateway.Session, recipient, owner int64, fs ...*gateway.Frame) {
	if sess == nil {
		return
	}
	v, other := viewFor(sess, recipient)
	if v == nil {
		if !other {
			_ = sess.SendFrames(fs...)
		}
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock() // a recovered panic must not leave the view locked
	if _, ok := v.known[owner]; ok && v.open {
		_ = sess.SendFrames(fs...)
	}
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
		sendIfKnown(r.Session, r.CharacterID, owner, fs...)
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

// playerSpawn is one player's spawn as one delivery builds it: its record,
// the state messages that follow it (its buffs and abnormal states), and the
// state version it was built at.
type playerSpawn struct {
	e       world.Entity
	record  []byte
	after   []*gateway.Frame
	version uint64
}

// buildPlayerSpawn reads e's record and state now. e is re-read from the hub
// by session, so the record carries where it stands at this moment; ok is
// false when it has left. The version is read first, so a change made while
// the record is read shows as a newer version than the one returned.
func buildPlayerSpawn(d viewDeps, e world.Entity, now time.Time) (playerSpawn, bool) {
	version := playerStateVersion(e.CharacterID)
	cur, ok := d.hub.EntityBySession(e.Session.ID())
	if !ok || cur.CharacterID != e.CharacterID {
		return playerSpawn{}, false
	}
	rec := playerRecord(d, cur, now)
	if rec == nil {
		return playerSpawn{}, false
	}
	after := buffStateFrames(cur.CharacterID, now)
	if f := characterStatusFrame(cur.CharacterID); f != nil {
		after = append(after, f)
	}
	// Its COS follow it (round 795, cosworld.go).
	after = append(after, cosSpawnFrames(cur.CharacterID, now)...)
	// Its plate colours (round 838, servicescroll.go, OURS).
	if f := plateColourFrame(cur.CharacterID); f != nil {
		after = append(after, f)
	}
	// Its custom title's text (round 838, titlescroll.go, OURS).
	if f := customTitleFrame(cur.CharacterID); f != nil {
		after = append(after, f)
	}
	return playerSpawn{e: cur, record: rec, after: after, version: version}, true
}

// fresh is s, rebuilt if its owner's state moved since it was built (rare:
// a change between the build, made outside the viewer's lock, and the send).
func (s playerSpawn) fresh(d viewDeps) (playerSpawn, bool) {
	if playerStateVersion(s.e.CharacterID) == s.version {
		return s, true
	}
	return buildPlayerSpawn(d, s.e, time.Now())
}

// spawnPlayersTo sends viewer the group spawns of those of others that are in
// view of it now and its client does not hold yet, one group per block (the
// window's blocks in order), followed by their buffs and states; and records
// them known. The records are read before the viewer's lock is taken (round
// 737's review, F8: with the SQL stores they are two queries each, and other
// players' sends to this viewer wait on that lock), then checked again under
// it.
func spawnPlayersTo(d viewDeps, viewer world.Entity, others []world.Entity) {
	if viewer.Session == nil || len(others) == 0 {
		return
	}
	v, _ := viewFor(viewer.Session, viewer.CharacterID)
	if v == nil {
		return
	}
	v.mu.Lock()
	if !v.open {
		v.mu.Unlock()
		return
	}
	var want []world.Entity
	for _, o := range others {
		if o.Session == nil || o.CharacterID == viewer.CharacterID {
			continue
		}
		if _, held := v.known[o.CharacterID]; !held {
			want = append(want, o)
		}
	}
	v.mu.Unlock()
	now := time.Now()
	var built []playerSpawn
	for _, o := range want {
		if !d.hub.Sees(viewer.Session.ID(), o.Session.ID()) {
			continue
		}
		if s, ok := buildPlayerSpawn(d, o, now); ok {
			built = append(built, s)
		}
	}
	if len(built) == 0 {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if !v.open || playerViewOf(viewer.CharacterID) != v {
		return
	}
	byCell := map[combat.Cell][]playerSpawn{}
	for _, s := range built {
		if _, held := v.known[s.e.CharacterID]; held {
			continue
		}
		if !d.hub.Sees(viewer.Session.ID(), s.e.Session.ID()) {
			continue
		}
		s, ok := s.fresh(d)
		if !ok {
			continue
		}
		byCell[s.e.Cell] = append(byCell[s.e.Cell], s)
	}
	var frames []*gateway.Frame
	var after []*gateway.Frame
	for _, c := range ownCellLast(playerCellsInOrder(byCell), viewer.Cell) {
		group := byCell[c]
		sortSpawnsByUID(group)
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
			v.known[s.e.CharacterID] = s.e.Arrival
			after = append(after, s.after...)
		}
	}
	if len(frames) > 0 {
		_ = viewer.Session.SendFrames(append(frames, after...)...)
	}
}

// spawnPlayerToOthers sends mover's single spawn (0x3015) to each of recips
// that sees it now and does not hold it yet, followed by its buffs and
// states, and records it known there. The record is built once, before any
// recipient's lock, and rebuilt only if mover's state moved meanwhile.
func spawnPlayerToOthers(d viewDeps, mover world.Entity, recips []world.Entity) {
	spawnPlayerToOthersAs(d, mover, recips, false, nil)
}

// spawnPlayerToOthersAs is spawnPlayerToOthers; with again, a recipient that
// holds mover from an EARLIER arrival (its known entry names another
// world.Entity.Arrival) is sent the spawn too: the same character on a new
// session, whose client draws it where it now is. One that holds this very
// arrival -- its own crossing spawned it a moment ago -- is not sent it twice.
// A non-nil notice (the arrival's OpPlayerZoneNotice) goes ahead of the spawn
// to each recipient sent it, and to no other (round 737's verification, N5).
func spawnPlayerToOthersAs(d viewDeps, mover world.Entity, recips []world.Entity, again bool, notice *gateway.Frame) {
	if len(recips) == 0 {
		return
	}
	spawn, ok := buildPlayerSpawn(d, mover, time.Now())
	if !ok {
		return
	}
	frames := spawnFrames(spawn)
	for _, r := range recips {
		if r.Session == nil || r.CharacterID == mover.CharacterID {
			continue
		}
		v, _ := viewFor(r.Session, r.CharacterID)
		if v == nil {
			continue // no view, or a stale session's: no spawns (F3)
		}
		// Each recipient's lock is released by defer, so a recovered panic in
		// the record builder (spawn.fresh) cannot leave the view locked.
		stop := func() bool {
			v.mu.Lock()
			defer v.mu.Unlock()
			if at, held := v.known[mover.CharacterID]; v.open && (!held || (again && at != spawn.e.Arrival)) && d.hub.Sees(r.Session.ID(), mover.Session.ID()) {
				if spawn.version != playerStateVersion(mover.CharacterID) {
					if spawn, ok = spawn.fresh(d); !ok {
						return true
					}
					frames = spawnFrames(spawn)
				}
				if notice != nil {
					_ = r.Session.SendFrames(notice)
				}
				_ = r.Session.SendFrames(frames...)
				v.known[mover.CharacterID] = spawn.e.Arrival
			}
			return false
		}()
		if stop {
			return
		}
	}
}

// spawnFrames is a 0x3015 of s and the state messages after it.
func spawnFrames(s playerSpawn) []*gateway.Frame {
	data := append(append([]byte(nil), s.record...), pcSpawnType)
	return append([]*gateway.Frame{gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleSpawn, Data: data})}, s.after...)
}

// despawnPlayersFrom sends viewer the group despawns of those of others its
// client holds and that are not in view of it now, one group per block, and
// forgets them.
func despawnPlayersFrom(d viewDeps, viewer world.Entity, others []world.Entity) {
	if viewer.Session == nil || len(others) == 0 {
		return
	}
	v, _ := viewFor(viewer.Session, viewer.CharacterID)
	if v == nil {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if !v.open {
		return
	}
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
	for _, c := range ownCellLast(playerCellsInOrder(byCell), viewer.Cell) {
		ids := byCell[c]
		uids := make([]uint32, 0, len(ids))
		for _, id := range ids {
			uids = append(uids, uint32(id))
			// Its COS go with it (round 795).
			uids = append(uids, cosDespawnUIDs(id)...)
			delete(v.known, id)
		}
		// By unique id, as the group spawn (round 762, READ FUN_00533b90).
		sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
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
	// Its COS go with it (round 795), ahead of it.
	frames := append(cosDespawnFrames(gone.CharacterID), frame)
	for _, r := range recips {
		if r.Session == nil || r.CharacterID == gone.CharacterID {
			continue
		}
		v, _ := viewFor(r.Session, r.CharacterID)
		if v == nil {
			continue
		}
		func() {
			v.mu.Lock()
			defer v.mu.Unlock() // a recovered panic must not leave the view locked
			if _, held := v.known[gone.CharacterID]; held && v.open && !stillSees(d.hub, r, gone) {
				_ = r.Session.SendFrames(frames...)
				delete(v.known, gone.CharacterID)
			}
		}()
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

// arrivePlayer opens arrived's view (its client has just had its result) and
// spawns both ways with the players in view of it NOW: the window is read
// from the hub after the view opened, so a player who came into view while
// it was closed is in it, and one who comes into view after it is spawned by
// its own crossing (round 737's review, F3). The players it is spawned to
// hear its OpPlayerZoneNotice (entered) just ahead of the spawn. Nothing for
// a stale session: the view is opened only while arrived.Session is the
// hub's session for the character (round 737's verification, N4).
func arrivePlayer(d viewDeps, arrived world.Entity) {
	if !storeViewIfLive(d.hub, arrived.CharacterID, arrived.Session, openedView(arrived.Session, d)) {
		return
	}
	// Its job (round 799, jobguild.go): the 0x3013 job section, OURS'
	// OpJobInfo, to its own client.
	sendJobInfo(d.ctx, arrived.Session, arrived.CharacterID)
	// Round 814: its own guild line (OURS: retail's own-character data is not
	// modelled; the line's message, OpEntityGuildUpdate, is).
	sendOwnGuildLine(d.ctx, arrived.Session, arrived.CharacterID)
	// Round 821: its guild's block (the window's data, s:0x5c8d40), and
	// its fellow members see it come online.
	sendOwnGuildBlock(d.ctx, arrived.Session, arrived.CharacterID)
	guildMemberPresence(d.ctx, arrived.CharacterID, true)
	// Round 802: a trader's safe trade (vslot_391's report).
	safeTradeAtLogin(d.ctx, arrived.Session, arrived.CharacterID)
	// Its COS arrive with it (round 795, cossummon.go): before the spawns
	// both ways, so the players it meets get them with its own.
	cosArrived(d.ctx, arrived)
	// Round 838: its premium Gold Time and composite grants (goldtime.go,
	// composite.go), kept across a restart.
	goldTimeArrived(d.ctx, arrived)
	compositeArrived(d.ctx, arrived)
	others := othersInView(d.hub, arrived)
	spawnPlayersTo(d, arrived, others)
	spawnPlayerToOthersAs(d, arrived, others, true, zoneNoticeFrame(zoneNoticeEntered, arrived))
}

// othersInView is the players in view of e as the hub has them now, e's own
// session left out.
func othersInView(hub *world.Hub, e world.Entity) []world.Entity {
	var out []world.Entity
	for _, o := range hub.ViewOfCharacter(e.CharacterID) {
		if o.Session != e.Session {
			out = append(out, o)
		}
	}
	return out
}

// departPlayer sends gone's 0x3016 to each of recips that holds it, whether
// or not it still sees it: gone was taken out of the world and put back
// (a zone change, a warp -- retail's CMsgBlock slot 3 then slot 2), so a
// client that holds it must drop it before its new spawn. Nothing when the
// character is in the world on another session (a reconnect whose old
// session leaves late: the live one's body stays). Each recipient sent the
// 0x3016 hears gone's OpPlayerZoneNotice (left) just ahead of it, and no
// other does (round 737's verification, N5).
func departPlayer(hub *world.Hub, gone world.Entity, recips []world.Watcher) {
	if hub != nil {
		if cur, ok := hub.EntityByCharacterID(gone.CharacterID); ok && cur.Session != gone.Session {
			return
		}
	}
	frame := gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(uint32(gone.CharacterID))})
	// Its COS go with it (round 795), ahead of it.
	cosGone := cosDespawnFrames(gone.CharacterID)
	notice := zoneNoticeFrame(zoneNoticeLeft, gone)
	for _, r := range recips {
		if r.Session == nil || r.CharacterID == gone.CharacterID {
			continue
		}
		v, _ := viewFor(r.Session, r.CharacterID)
		if v == nil {
			continue
		}
		v.mu.Lock()
		if _, held := v.known[gone.CharacterID]; held && v.open {
			if notice != nil {
				_ = r.Session.SendFrames(notice)
			}
			_ = r.Session.SendFrames(append(cosGone, frame)...)
			delete(v.known, gone.CharacterID)
		}
		v.mu.Unlock()
	}
}

// afterRelocate delivers a position change the hub has made (r): frame (the
// move's own message) to the mover's watchers that hold it, and to the mover
// itself with self; then, if it crossed a block line, what the crossing owes,
// built from the mover's view's stores -- nothing for a session without one,
// nor while its view is closed (a world entry or zone change in flight):
// arrivePlayer then spawns both ways from the window as the hub has it when
// the view opens, and the zone change's departPlayer has dropped it where it
// was held (round 737's verification, N1).
func afterRelocate(sess *gateway.Session, r world.MoveResult, self bool, frame *gateway.Frame) {
	bumpPlayerState(r.Entity.CharacterID)
	// A frame of nil is a crossing with no message of its own: the mover
	// pass's refiling of a leg (round 749, destmove.go moverPass).
	if frame != nil {
		if self && sess != nil {
			_ = sess.SendFrames(frame)
		}
		for _, w := range r.Watchers {
			sendIfKnown(w.Session, w.CharacterID, r.Entity.CharacterID, frame)
		}
	}
	if !r.Crossed || sess == nil {
		return
	}
	v, _ := viewFor(sess, r.Entity.CharacterID)
	if v == nil {
		return
	}
	v.mu.Lock()
	open, d := v.open, v.deps
	v.mu.Unlock()
	if open && d.hub != nil {
		crossPlayer(d, r)
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

// sortSpawnsByUID puts a block's records in its map's order, which is by
// unique id (round 762, READ FUN_00533910: the block's player map is a
// std::map keyed by the object's unique id, obj+8, walked in order).
func sortSpawnsByUID(group []playerSpawn) {
	sort.Slice(group, func(i, j int) bool { return uint32(group[i].e.CharacterID) < uint32(group[j].e.CharacterID) })
}

// ownCellLast moves own, when it is among cells, to the end (round 762, READ:
// CMsgBlock slot 2 0x534340 sends the neighbours' groups in its neighbour
// vector's order and the object's own block last, asm 0x534407; a walk's
// crossing sends the difference blocks only). The neighbours' own order is
// the vector's -- the order the blocks were linked when the regions loaded
// (INFERRED, not geometric) -- for which OpenSRO keeps its sorted one (OURS).
func ownCellLast(cells []combat.Cell, own combat.Cell) []combat.Cell {
	for i, c := range cells {
		if c == own {
			out := append(append(append([]combat.Cell(nil), cells[:i]...), cells[i+1:]...), own)
			return out
		}
	}
	return cells
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

// playerStateVersions numbers each player's changes of what its spawn record
// and its spawn's state messages carry (a move, a motion, a body mode, its
// equipment, a buff, a status): bumpPlayerState is called after the change
// and before its delivery. A spawn built outside a recipient's lock is
// rebuilt when the number moved under it, so no recipient is sent a record
// older than a change whose own delivery skipped it for not holding the body
// yet. One atomic per character (round 737's review, F11: a process-wide
// mutex was taken on every move).
var playerStateVersions sync.Map // int64 -> *atomic.Uint64

func playerStateCounter(id int64) *atomic.Uint64 {
	if c, ok := playerStateVersions.Load(id); ok {
		return c.(*atomic.Uint64)
	}
	c, _ := playerStateVersions.LoadOrStore(id, new(atomic.Uint64))
	return c.(*atomic.Uint64)
}

func playerStateVersion(id int64) uint64 { return playerStateCounter(id).Load() }

func bumpPlayerState(id int64) { playerStateCounter(id).Add(1) }

func forgetPlayerState(id int64) { playerStateVersions.Delete(id) }

// forgetLeftPlayer drops a character's state number and cached look as it
// leaves the world -- unless it is in the world again on a newer session by
// now (round 737's verification, N3), whose state they are.
func forgetLeftPlayer(hub *world.Hub, characterID int64) {
	if hub != nil {
		if _, live := hub.EntityByCharacterID(characterID); live {
			return
		}
	}
	forgetPlayerState(characterID)
	invalidateLook(characterID)
}

// OpPlayerZoneNotice tells a client that a player arrived in its zone or
// left it -- the world entry, a zone change, a logout -- as opposed to
// walking into or out of its 3 x 3 blocks, which the spawn messages carry
// alike (round 737's review). OURS, an additive message like every OpenSRO
// opcode (docs/protocol/PROTOCOL_DECISION.md): retail prints nothing for
// either, and OpenSRO's client keeps its "X entered the zone." / "X left the
// zone." lines for the real arrivals only, as before round 737. u8 kind
// (zoneNoticeEntered, zoneNoticeLeft), u32 uid, u16 length + the name.
// 0x00B7 was free in server/ and client/scripts/net (grep, 2026-10-06).
const OpPlayerZoneNotice uint16 = 0x00b7

const (
	zoneNoticeEntered byte = 1
	zoneNoticeLeft    byte = 2
)

// zoneNoticeFrame is e's zone notice of kind (docs/protocol/pc_spawn.md),
// sent by arrivePlayer and departPlayer with the spawn or despawn it goes
// ahead of, to exactly the recipients sent that (round 737's verification,
// N5). nil when it cannot be encoded.
func zoneNoticeFrame(kind byte, e world.Entity) *gateway.Frame {
	data := []byte{kind}
	data = append(data, byte(e.CharacterID), byte(e.CharacterID>>8), byte(e.CharacterID>>16), byte(e.CharacterID>>24))
	data = append(data, byte(len(e.Name)), byte(len(e.Name)>>8))
	data = append(data, e.Name...)
	f, err := gateway.NewFrame(&proto.Packet{Opcode: OpPlayerZoneNotice, Data: data})
	if err != nil {
		return nil
	}
	return f
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
