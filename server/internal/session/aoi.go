package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The monsters' area of interest (round 656). Until this round every monster
// message reached every player in the monster's hub bucket -- and under
// -single-frame the bucket is the whole world (worldmap.WorldBucket) -- so
// with round 657's full map (~10,200 field monsters) every player would have
// been sent every monster's list record and every monster's every leg. Now a
// player hears about the monsters within AOIRadius cells of the cell it
// stands in (combat.CellOf; a square window -- retail's 3 x 3 message blocks
// since round 664), and nothing else:
//
//   - the monster list (handleMonsterList) lists that window, paged over as
//     many frames as it needs (monsterlist.go);
//   - the spawn push, the legs and stops, a monster's blows, the damage and
//     the death go only to the players whose window holds the monster's cell
//     (monsterWatchers, and the AI tick's delivery, monsterai.go);
//   - a monster that comes into a player's window -- the player walked over
//     a cell line, or the monster did -- is sent to it as an
//     OpMonsterSpawned (its list record and the way it faces) followed by its
//     current leg as an OpMonsterMoved when it is walking; one that goes out
//     of it is named in an OpMonsterLeft, which the client answers by
//     dropping the body without a death.
//
// Where the window is: the AOI runtime (monsterAOI, installed by cmd/server
// with RunMonsterAOI) keeps each player's VIEW, the cell the window is centred
// on. It moves the view to the player's current cell every AOITick
// (reconcile) and on every list request, and the enter and leave messages are
// the difference between the old window and the new. Without the runtime --
// the unit tests -- a player's view is the cell it stands in, read at each
// send, and nothing enters or leaves.
//
// The enter and leave messages are hints checked at the send (deliverViewEvents):
// each is sent only if, at that moment and under the session's monster wire
// lock, it is still true -- an enter only for a live monster in the view's
// window, a leave only for one that is not. Every change of truth (a view
// moving, a monster crossing a line, a list) produces its own messages after
// it, and a session's sends are serialised by that lock, so the client ends
// where the server is whatever order two goroutines' messages reach the
// socket in.

// AOIRadius is the area of interest's half-width in cells (combat.CellSpan,
// retail's 320-unit message block): a player sees the monsters of the
// (2 x 1 + 1)^2 = 9 blocks around the one it stands in -- a 960 x 960 square,
// so between 320 and 640 units on each side of the player.
//
// READ (round 664; docs/protocol/monster_ai.md, "What a player is sent:
// retail's message blocks"). SR_GameServer.exe links every block to its 8
// neighbours once, at load: CRgnTerrain::vslot_016 (0x53ab90) walks the 6 x 6
// blocks and, for each of the 8 (dx, dz) offsets in the table at 0xc64090
// ((-1,-1) (0,-1) (1,-1) (-1,0) (1,0) (-1,1) (0,1) (1,1)), finds the block
// (CRgnTerrain::FUN_0053ac20, across a region line through the neighbour
// region 0x430900 picks, index (i + 6) % 6) and adds it with CMsgBlock slot 5
// (0x5336e0, the list at block+0x10). An object put in a block (CMsgBlock
// slot 2, 0x534340) is, for each neighbour and then the block itself, sent
// that block's objects if it is a player (the group spawn 0x3017/0x3019/0x3018,
// 0x533e70) and announced to that block's players (0x3015, 0x533f70); taking
// it out (slot 3, 0x5344b0) sends 0x3016 (0x534050) to the same nine. Until
// round 664 this was OURS: 2 region cells, the client's REGION_LOAD_RADIUS.
const AOIRadius = 1

// AOITick is how often the runtime moves each player's view to the cell it
// stands in (reconcile). OURS: the monster AI's MonsterAITick, so a region
// line crossed is answered within one AI period.
const AOITick = MonsterAITick

// OpMonsterLeft names the monsters that have left a player's area of interest
// (round 656): u16 n, then n s64 ids. The client drops each body as a zone
// change does -- no death, no loot -- unless it is still playing a death.
// OURS, an additive placeholder like every OpenSRO opcode
// (docs/protocol/PROTOCOL_DECISION.md). 0x00B5 was free in server/ and
// client/scripts/net (grep, 2026-09-30).
const OpMonsterLeft uint16 = 0x00b5

// monsterLeftMaxIDs is how many ids one OpMonsterLeft carries: (MaxPayload -
// 2) / 8.
const monsterLeftMaxIDs = (proto.MaxPayload - 2) / 8

// MonsterLeft is the OpMonsterLeft payload.
type MonsterLeft struct {
	IDs []int64
}

func (m *MonsterLeft) Encode() []byte {
	out := make([]byte, 2, 2+8*len(m.IDs))
	binary.LittleEndian.PutUint16(out, uint16(len(m.IDs)))
	for _, id := range m.IDs {
		out = binary.LittleEndian.AppendUint64(out, uint64(id))
	}
	return out
}

// DecodeMonsterLeft decodes an OpMonsterLeft payload, refusing one cut short.
// Only tests call it -- the message goes server to client.
func DecodeMonsterLeft(data []byte) (*MonsterLeft, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("session: decoding MonsterLeft: truncated count")
	}
	n := int(binary.LittleEndian.Uint16(data))
	if len(data) < 2+8*n {
		return nil, fmt.Errorf("session: decoding MonsterLeft: %d ids need %d bytes, have %d", n, 2+8*n, len(data))
	}
	m := &MonsterLeft{IDs: make([]int64, n)}
	for i := range m.IDs {
		m.IDs[i] = int64(binary.LittleEndian.Uint64(data[2+8*i:]))
	}
	return m, nil
}

// monsterAOIRuntime is the running area-of-interest runtime, nil until
// cmd/server installs it (RunMonsterAOI) and in every unit test that does not.
var monsterAOIRuntime atomic.Pointer[monsterAOI]

// monsterAOI is the runtime's state.
type monsterAOI struct {
	world    *world.Hub
	monsters *combat.Hub
	logger   *slog.Logger

	mu sync.RWMutex
	// views is each player's view cell, by session id.
	views map[uint64]*aoiView
	// watchers is, for each cell some window holds, the views whose window
	// holds it: the recipients of a message about a monster in that cell.
	// Rebuilt under mu whenever a view moves (rebuildLocked).
	watchers map[combat.Cell][]*aoiView
}

// aoiView is one player's view.
type aoiView struct {
	sess *gateway.Session
	cell combat.Cell
	// pending is the monsters a view move has owed this player an enter for
	// that has not been sent yet (round 656's second review): a leg for one
	// of them is held back (mayShowLeg) -- the client would answer a leg for a
	// body it has never been told about by asking for the whole list -- and
	// the enter carries the leg anyway. Set by reconcile, cleared as each
	// enter is sent or dropped and by a list. Guarded by pendMu.
	pendMu  sync.Mutex
	pending map[int64]struct{}
}

func (view *aoiView) markPending(ids []int64) {
	if len(ids) == 0 {
		return
	}
	view.pendMu.Lock()
	defer view.pendMu.Unlock()
	if view.pending == nil {
		view.pending = map[int64]struct{}{}
	}
	for _, id := range ids {
		view.pending[id] = struct{}{}
	}
}

func (view *aoiView) unmarkPending(id int64) {
	view.pendMu.Lock()
	defer view.pendMu.Unlock()
	delete(view.pending, id)
}

func (view *aoiView) isPending(id int64) bool {
	view.pendMu.Lock()
	defer view.pendMu.Unlock()
	_, ok := view.pending[id]
	return ok
}

func (view *aoiView) clearPending() {
	view.pendMu.Lock()
	defer view.pendMu.Unlock()
	clear(view.pending)
}

// RunMonsterAOI installs the area-of-interest runtime before it returns, then
// moves every player's view every AOITick on its own goroutine until ctx ends.
// cmd/server calls it once, before the gateway serves and before the roster
// spawns.
func RunMonsterAOI(ctx context.Context, hub *world.Hub, monsters *combat.Hub, logger *slog.Logger) {
	v := newMonsterAOI(hub, monsters, logger)
	monsterAOIRuntime.Store(v)
	aoiLogger.Store(logger)
	go func() {
		ticker := time.NewTicker(AOITick)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				start := time.Now()
				v.reconcile()
				loopAOI.Tick(start)
			}
		}
	}()
}

func newMonsterAOI(hub *world.Hub, monsters *combat.Hub, logger *slog.Logger) *monsterAOI {
	return &monsterAOI{world: hub, monsters: monsters, logger: logger,
		views: map[uint64]*aoiView{}, watchers: map[combat.Cell][]*aoiView{}}
}

// aoiFor is the installed runtime when it serves monsters, else nil.
func aoiFor(monsters *combat.Hub) *monsterAOI {
	// Round 869: an instance's own runtime serves its monsters.
	if rt := runtimeOfMonsters(monsters); rt != nil {
		return rt.aoi
	}
	if v := monsterAOIRuntime.Load(); v != nil && v.monsters == monsters {
		return v
	}
	return nil
}

// rebuildLocked recomputes watchers from views. Called with mu held for
// writing.
func (v *monsterAOI) rebuildLocked() {
	clear(v.watchers)
	for _, view := range v.views {
		for x := view.cell.X - AOIRadius; x <= view.cell.X+AOIRadius; x++ {
			for z := view.cell.Z - AOIRadius; z <= view.cell.Z+AOIRadius; z++ {
				c := combat.Cell{Zone: view.cell.Zone, X: x, Z: z}
				v.watchers[c] = append(v.watchers[c], view)
			}
		}
	}
}

// setView centres sess's view on cell, as a list request does: the list sent
// next is the window's whole truth, so no enter or leave is owed.
func (v *monsterAOI) setView(sess *gateway.Session, cell combat.Cell) {
	v.mu.Lock()
	defer v.mu.Unlock()
	view := v.views[sess.ID()]
	if view != nil {
		view.clearPending() // the list names the whole window
	}
	if view != nil && view.cell == cell {
		return
	}
	if view == nil {
		v.views[sess.ID()] = &aoiView{sess: sess, cell: cell}
	} else {
		view.cell = cell
	}
	v.rebuildLocked()
}

// mayShowLeg reports whether a leg, blow or other push about monster id may
// go to the session now (round 656's second review): the monster is alive,
// its cell is in the session's window, and no enter for it is still owed.
// Checked under the session's monster wire lock, as the enters are.
func (v *monsterAOI) mayShowLeg(sessionID uint64, id int64) bool {
	c, alive := v.monsters.CellOfMonster(id)
	if !alive {
		return false
	}
	v.mu.RLock()
	view := v.views[sessionID]
	near := view != nil && view.cell.Near(c, AOIRadius)
	v.mu.RUnlock()
	return near && !view.isPending(id)
}

// viewCell is sess's view cell, if it has one.
func (v *monsterAOI) viewCell(sessionID uint64) (combat.Cell, bool) {
	v.mu.RLock()
	defer v.mu.RUnlock()
	view := v.views[sessionID]
	if view == nil {
		return combat.Cell{}, false
	}
	return view.cell, true
}

// appendWatchers appends to dst the sessions whose window holds cell.
func (v *monsterAOI) appendWatchers(dst []*gateway.Session, cell combat.Cell) []*gateway.Session {
	v.mu.RLock()
	defer v.mu.RUnlock()
	for _, view := range v.watchers[cell] {
		dst = append(dst, view.sess)
	}
	return dst
}

// viewEvents is what one session is owed after a view or a monster moved.
type viewEvents struct {
	sess           *gateway.Session
	enters, leaves []int64
}

// reconcile moves every player's view to the cell it stands in now and sends
// each one the difference: the monsters of the cells its window gained, and
// the ids of those in the cells it lost. A player seen for the first time
// gets a view and nothing else (its client asks for the list when it enters
// the world); a zone change moves the view silently too (the client drops
// every body and asks for the new zone's list, World3D._on_change_zone_result). A
// view whose session has left the world is dropped.
func (v *monsterAOI) reconcile() {
	ents := v.world.AllEntities()
	var owed []viewEvents
	v.mu.Lock()
	present := make(map[uint64]struct{}, len(ents))
	moved := false
	for _, e := range ents {
		if e.Session == nil {
			continue
		}
		id := e.Session.ID()
		present[id] = struct{}{}
		cell := combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z)
		view := v.views[id]
		if view == nil {
			v.views[id] = &aoiView{sess: e.Session, cell: cell}
			moved = true
			continue
		}
		if view.cell == cell {
			continue
		}
		old := view.cell
		view.cell = cell
		moved = true
		if old.Zone != cell.Zone {
			continue
		}
		gained, lost := windowDiff(old, cell, AOIRadius)
		ev := viewEvents{sess: e.Session}
		ev.enters = v.monsters.IDsInCells(nil, gained)
		view.markPending(ev.enters)
		ev.leaves = v.monsters.IDsInCells(nil, lost)
		if v.logger != nil {
			v.logger.Info("aoi: view moved", "character_id", e.CharacterID, "zone", cell.Zone,
				"from", fmt.Sprintf("%d,%d", old.X, old.Z), "to", fmt.Sprintf("%d,%d", cell.X, cell.Z),
				"entering", len(ev.enters), "leaving", len(ev.leaves))
		}
		if len(ev.enters) > 0 || len(ev.leaves) > 0 {
			owed = append(owed, ev)
		}
	}
	for id := range v.views {
		if _, ok := present[id]; !ok {
			delete(v.views, id)
			moved = true
		}
	}
	if moved {
		v.rebuildLocked()
	}
	v.mu.Unlock()
	for _, ev := range owed {
		v.deliverViewEvents(ev)
	}
	// The NPCs' spawns and despawns (round 708, npcworld.go) ride this tick:
	// the same entities, the same window.
	if w := npcWorldFor(v.world); w != nil {
		w.reconcile(ents)
	}
	// Round 869 lane W3 (fgw.go): the Dimension-hole gates standing in this
	// world, the same window.
	reconcileGates(v.world, ents)
}

// windowDiff is the cells the window centred on to holds and the one centred
// on from does not (gained), and the reverse (lost). Both centres are in one
// zone.
func windowDiff(from, to combat.Cell, radius int) (gained, lost []combat.Cell) {
	for x := to.X - radius; x <= to.X+radius; x++ {
		for z := to.Z - radius; z <= to.Z+radius; z++ {
			c := combat.Cell{Zone: to.Zone, X: x, Z: z}
			if !from.Near(c, radius) {
				gained = append(gained, c)
			}
		}
	}
	for x := from.X - radius; x <= from.X+radius; x++ {
		for z := from.Z - radius; z <= from.Z+radius; z++ {
			c := combat.Cell{Zone: from.Zone, X: x, Z: z}
			if !to.Near(c, radius) {
				lost = append(lost, c)
			}
		}
	}
	return gained, lost
}

// step is the monster step and the enter and leave messages its region
// crossings owe, as one step against view moves (round 656's review): the
// hub's StepCells and crossingsLocked under v.mu held for reading, so no
// reconcile or list can move a view between them. A view that moved between
// the two would have read the monster's new cell in its own difference and
// then found no crossing to answer for, and the client would have missed an
// enter or a leave. The monster AI's tick steps through it.
func (v *monsterAOI) step(dt float64, awake func(int64, combat.Cell) bool, dst []combat.CellChange) ([]combat.CellChange, []viewEvents) {
	v.mu.RLock()
	defer v.mu.RUnlock()
	dst = v.monsters.StepCells(dt, awake, dst)
	if aoiStepHook != nil {
		aoiStepHook()
	}
	return dst, v.crossingsLocked(dst)
}

// place moves a monster as Hub.Place does (a knock) and returns what its
// cell crossing owes each watcher, under the view lock held for reading as
// step's crossings are, so no view moves between the move and the
// difference.
func (v *monsterAOI) place(id int64, x, z float64) ([]viewEvents, bool) {
	v.mu.RLock()
	defer v.mu.RUnlock()
	_, ch, crossed, ok := v.monsters.Place(id, x, z)
	if !ok || !crossed {
		return nil, ok
	}
	return v.crossingsLocked([]combat.CellChange{ch}), true
}

// aoiStepHook, when set, runs inside step between the hub's step and the
// crossings, with the view lock held: a test's window into the one ordering
// the lock exists to exclude (TestAOIReconcileWaitsForTheStep). nil in
// production.
var aoiStepHook func()

// crossingsLocked turns the cell lines a step carried monsters over into what
// each watching player is owed: an enter for a player whose window holds the
// new cell and not the old, a leave for one whose window holds the old and
// not the new. Called with v.mu held for reading, by step, so no view moves between the
// step and this (round 656's review).
func (v *monsterAOI) crossingsLocked(changes []combat.CellChange) []viewEvents {
	if len(changes) == 0 {
		return nil
	}
	bySess := map[uint64]*viewEvents{}
	var order []uint64
	get := func(s *gateway.Session) *viewEvents {
		ev := bySess[s.ID()]
		if ev == nil {
			ev = &viewEvents{sess: s}
			bySess[s.ID()] = ev
			order = append(order, s.ID())
		}
		return ev
	}
	for _, ch := range changes {
		for _, view := range v.watchers[ch.To] {
			if !view.cell.Near(ch.From, AOIRadius) {
				ev := get(view.sess)
				ev.enters = append(ev.enters, ch.ID)
			}
		}
		for _, view := range v.watchers[ch.From] {
			if !view.cell.Near(ch.To, AOIRadius) {
				ev := get(view.sess)
				ev.leaves = append(ev.leaves, ch.ID)
			}
		}
	}
	out := make([]viewEvents, 0, len(order))
	for _, id := range order {
		out = append(out, *bySess[id])
	}
	return out
}

// sees reports whether sess's view holds cell, reading the view now.
func (v *monsterAOI) sees(sessionID uint64, cell combat.Cell) bool {
	vc, ok := v.viewCell(sessionID)
	return ok && vc.Near(cell, AOIRadius)
}

// deliverViewEvents sends ev under the session's monster wire lock, each
// message only if it is still true now (the package note above): the leaves
// first, as one or more OpMonsterLeft, then each enter as an OpMonsterSpawned
// with the monster's facing, and its leg when it is walking. The record is
// the hub's at the send, so a monster that walked since the event was
// computed is sent where it is.
func (v *monsterAOI) deliverViewEvents(ev viewEvents) {
	wire := monsterWireLock(ev.sess)
	wire.Lock()
	defer wire.Unlock()
	var left []int64
	for _, id := range ev.leaves {
		if c, alive := v.monsters.CellOfMonster(id); alive && v.sees(ev.sess.ID(), c) {
			continue // back in the window since: nothing left
		}
		left = append(left, id)
	}
	for len(left) > 0 {
		n := min(len(left), monsterLeftMaxIDs)
		if err := ev.sess.Send(&proto.Packet{Opcode: OpMonsterLeft, Data: (&MonsterLeft{IDs: left[:n]}).Encode()}); err != nil {
			return
		}
		left = left[n:]
	}
	v.mu.RLock()
	view := v.views[ev.sess.ID()]
	v.mu.RUnlock()
	for _, id := range ev.enters {
		if view != nil {
			view.unmarkPending(id)
		}
		m, alive := v.monsters.Get(id)
		if !alive || !v.sees(ev.sess.ID(), combat.CellOf(m.Zone, m.X, m.Z)) {
			continue
		}
		if err := sendMonsterEnter(ev.sess, m, v.monsters.Facing(id)); err != nil {
			return
		}
	}
}

// sendMonsterEnter sends m to sess as a monster coming into its window: the
// list record and facing as an OpMonsterSpawned (the client's spawn push,
// round 540, which draws or re-places the body and turns a standing one),
// its abnormal states as an OpObjectStatus when it has any (round 659), then
// the leg it is walking as an OpMonsterMoved from where it is now.
func sendMonsterEnter(sess *gateway.Session, m combat.Monster, facing float64) error {
	msg := &MonsterSpawned{Monster: monsterSnapshotFor(sess, m), Heading: float32(facing)}
	frames := []*proto.Packet{{Opcode: OpMonsterSpawned, Data: msg.Encode()}}
	// Its abnormal states, if any (round 659, status.go), so a monster that
	// comes into view already stunned is drawn stunned.
	if st := monsterStatusPacket(m.ID); st != nil {
		frames = append(frames, st)
	}
	if m.Moving {
		mv := &MonsterMoved{MonsterID: m.ID, X: float32(m.X), Z: float32(m.Z),
			DestX: float32(m.DestX), DestZ: float32(m.DestZ), Speed: float32(m.MoveSpeed), Mode: m.MoveMode}
		frames = append(frames, &proto.Packet{Opcode: OpMonsterMoved, Data: mv.Encode()})
	}
	// The enter, its status and its leg as one batch (round 662's review):
	// queued once, nothing comes between them.
	return sess.SendBatch(frames...)
}

// monsterWireMu guards the creation of a session's monster wire lock.
var monsterWireMu sync.Mutex

// monsterWireKey is the session value the wire lock is kept under.
const monsterWireKey = "session.monsterAIWire"

// monsterWireLock is sess's monster wire lock, made on first use: held while a
// monster list is built and sent (handleMonsterList), while the AI tick's
// pushes are sent to the session (monsterAI.sendUnderWireLock), and while the
// area of interest's enter and leave messages are checked and sent
// (deliverViewEvents). Round 537 kept it on the AI runtime; round 656 made it
// the package's, since the area of interest needs it with the AI off.
func monsterWireLock(sess *gateway.Session) *sync.Mutex {
	monsterWireMu.Lock()
	defer monsterWireMu.Unlock()
	if v, ok := sess.Get(monsterWireKey); ok {
		if l, ok := v.(*sync.Mutex); ok {
			return l
		}
	}
	l := &sync.Mutex{}
	sess.Set(monsterWireKey, l)
	return l
}

// viewCellOf is where e's window is centred: its view under the runtime, else
// -- the runtime off, or a player it has not seen yet -- the cell e stands
// in.
func viewCellOf(v *monsterAOI, e world.Entity) combat.Cell {
	if v != nil && e.Session != nil {
		if c, ok := v.viewCell(e.Session.ID()); ok {
			return c
		}
	}
	return combat.CellOf(e.Zone, e.Pos.X, e.Pos.Z)
}

// monsterWatchers is every entity in m's zone whose window holds m's cell:
// the recipients of a message about m sent from a request path (the damage,
// the death and the counter's blow in performAttack, the GM /kill, the spawn
// push). It reads the zone's entities and filters them, where the AI tick
// reads the runtime's watcher index instead (monsterAI.deliver).
func monsterWatchers(hub *world.Hub, monsters *combat.Hub, m combat.Monster) []world.Entity {
	if hub == nil {
		return nil
	}
	v := aoiFor(monsters)
	cell := combat.CellOf(m.Zone, m.X, m.Z)
	var out []world.Entity
	for _, e := range hub.EntitiesInZone(m.Zone) {
		if viewCellOf(v, e).Near(cell, AOIRadius) {
			out = append(out, e)
		}
	}
	return out
}

// monsterWindow is every live monster in the window of the cell e's view is
// centred on, in id order: what the monster list names.
func monsterWindow(monsters *combat.Hub, cell combat.Cell) []combat.Monster {
	listed := monsters.InWindow(nil, cell, AOIRadius)
	sort.Slice(listed, func(i, j int) bool { return listed[i].ID < listed[j].ID })
	return listed
}

// sendMonsterPush writes p to sess under its monster wire lock: how a request
// path sends a monster's damage, death or blow (round 656), so the send is
// ordered against the area of interest's checked enter messages
// (deliverViewEvents), which read the monster's life under the same lock -- a
// death sent after the check can never be followed by an enter for the dead
// monster.
func sendMonsterPush(sess *gateway.Session, p *proto.Packet) {
	wire := monsterWireLock(sess)
	wire.Lock()
	defer wire.Unlock()
	_ = sess.Send(p)
}

// unionWatchers is a and b with each session once, a's first (round 656's
// review: a kill's recipients are the watchers before the blow and after it).
func unionWatchers(a, b []world.Entity) []world.Entity {
	seen := make(map[uint64]struct{}, len(a)+len(b))
	out := make([]world.Entity, 0, len(a)+len(b))
	for _, list := range [][]world.Entity{a, b} {
		for _, e := range list {
			if e.Session == nil {
				continue
			}
			if _, dup := seen[e.Session.ID()]; dup {
				continue
			}
			seen[e.Session.ID()] = struct{}{}
			out = append(out, e)
		}
	}
	return out
}

// damageMonsterWatched is combat.Hub.ApplyDamage with the players to tell
// about it (round 656's review): those whose window held the monster before
// the blow, then those whose window holds where it stands after it, each once.
// A kill is announced to both, so a view that moved off the monster between
// the two -- whose leave no longer finds the dead monster in its cells --
// still hears the death rather than keeping a ghost. performAttack's blows go
// through it. The blow is booked to attacker on the monster's damage list
// (combat.Hub.ApplyDamageFrom, attacker 0 books nobody), and the killing blow
// hands the list back in hits: the unique kill notice names its killer from
// it (round 657, AnnounceUniqueKill).
func damageMonsterWatched(hub *world.Hub, monsters *combat.Hub, id, attacker int64, amount int) (updated combat.Monster, died, ok bool, watchers []world.Entity, hits []combat.Hit) {
	var before []world.Entity
	if m, alive := monsters.Get(id); alive {
		before = monsterWatchers(hub, monsters, m)
	}
	updated, died, ok, hits = monsters.ApplyDamageFrom(id, attacker, amount)
	if !ok {
		return updated, died, ok, nil, nil
	}
	return updated, died, ok, unionWatchers(before, monsterWatchers(hub, monsters, updated)), hits
}
