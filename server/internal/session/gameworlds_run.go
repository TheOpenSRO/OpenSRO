package session

// The instances' runtime in the session layer (round 869,
// docs/protocol/game_worlds.md 14 items 2-8): each instance's monster AI,
// area of interest and NPCs (worldRuntime, built by the world's Open hook and
// ticked by its own goroutine), its lifecycle's messages (the 0x300C 0x0C1A
// warnings, the close back to the return point), the entry
// (EnterInstance: the return point kept, the _CharInstanceWorldData row, the
// group cool time as a timed job with its 0x320C), the 0x705A portal entry
// with its two replies, and the 0x751D exit NPC.

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"math/rand"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// TimedJobWorldGroup is the group re-entry limit's timed-job type: category
// 0xC, CTJ_EnterWorldGroupKeeper (READ s:0x60a070; game_worlds.md 5). Its row
// keeps the group in Ref, the instance key in Key, the world and layer in
// V1 / V2, the entry in Start and the end in End.
const TimedJobWorldGroup = 0xC

// GameWorldDeps are the stores the instance paths use (cmd/server).
type GameWorldDeps struct {
	Chars     character.Store
	Equipment equipment.Store
	Zerk      *berserk.Tracker
	Timed     timedjob.Store
	Instances gameworld.CharStore
	Parties   *party.Hub
	Logger    *slog.Logger
	// Spawn hatches one monster of codename code into w at (zone, x, y, z):
	// a trigger's LOAD_MONSTER (cmd/server's species table). Nil spawns
	// nothing.
	Spawn func(w *gameworld.World, code string, zone string, x, y, z float64) (int64, bool)
	// PillarSummon runs a dead dimension pillar's summon skill in w (round
	// 869 lane W3, fgw_pillar.go: the minion executor over its 'ssou'
	// block) and answers the spawned monsters. Nil summons nothing.
	PillarSummon func(w *gameworld.World, pillar combat.Monster) []int64
}

var gwDeps atomic.Pointer[GameWorldDeps]

// SetGameWorldDeps installs the instance paths' stores.
func SetGameWorldDeps(d GameWorldDeps) { gwDeps.Store(&d) }

func gameWorldDeps() GameWorldDeps {
	if d := gwDeps.Load(); d != nil {
		return *d
	}
	return GameWorldDeps{}
}

// worldRuntime is an instance's own session runtimes.
type worldRuntime struct {
	ai  *monsterAI
	aoi *monsterAOI
	npc *npcWorld
}

// aiSetup is RunMonsterAI's configuration, kept for the instances' AIs.
type aiSetupBox struct {
	cfg    MonsterAIConfig
	logger *slog.Logger
}

var aiSetup atomic.Pointer[aiSetupBox]

// aoiLogger is RunMonsterAOI's logger, for the instances' areas of interest.
var aoiLogger atomic.Pointer[slog.Logger]

func runtimeOfWorld(w *gameworld.World) *worldRuntime {
	if w == nil {
		return nil
	}
	rt, _ := w.Ext.(*worldRuntime)
	return rt
}

// runtimeOfMonsters is the runtime of the instance owning monsters, nil for
// the open world's (and a bare hub's).
func runtimeOfMonsters(m *combat.Hub) *worldRuntime {
	if m == nil {
		return nil
	}
	w, _ := m.Unit().(*gameworld.World)
	if w == nil || w.Open() {
		return nil
	}
	return runtimeOfWorld(w)
}

// aiOf is the monster AI serving monsters: an instance's own, else the
// installed one when it serves this hub; nil for none.
func aiOf(m *combat.Hub) *monsterAI {
	if rt := runtimeOfMonsters(m); rt != nil {
		return rt.ai
	}
	a := monsterAIRuntime.Load()
	if a == nil || (m != nil && a.monsters != m) {
		return nil
	}
	return a
}

// npcWorldFor is the NPC runtime of hub's world.
func npcWorldFor(hub *world.Hub) *npcWorld {
	if w := instanceOf(hub); w != nil {
		if rt := runtimeOfWorld(w); rt != nil {
			return rt.npc
		}
		return nil
	}
	return npcWorldRuntime.Load()
}

// openHub is the open world's hub: the manager's world 1, else def.
func openHub(def *world.Hub) *world.Hub {
	if m := GameWorlds(); m != nil {
		if w := m.OpenWorld(); w != nil {
			return w.Hub
		}
	}
	return def
}

// instanceRegion reports whether region is one of world id's
// (_RefInstance_World_Region), for an instanced world the manager knows.
func instanceRegion(worldID, region int) bool {
	m := GameWorlds()
	if m == nil {
		return false
	}
	ref := m.Ref().World(uint16(worldID))
	return ref.Instanced() && ref.HasRegion(uint16(region))
}

// warpTarget is the hub a warp from `from` to (zone, pos) lands in: within
// an instance a place of one of its regions stays inside, any other place is
// the open world's (OURS rule: every table point OpenSRO warps to -- a
// return point, a scroll's town, a gate's destination -- is the open
// world's). The region is read in the frame of the warp's own bucket (round
// 871): a layer keeps its own frame under -single-frame (placeRegion), where
// the zone label's bucket (ZoneBucket) is the open world's one frame -- read
// there, a /unstuck or a GM /tp inside the Wrecked Ship named a region by
// Jangan and moved the character out of its layer.
func warpTarget(from *world.Hub, bucket string, pos world.Position) *world.Hub {
	w := instanceOf(from)
	if w == nil {
		return from
	}
	region, _, _ := regionLocalOf(bucket, pos)
	if region != 0 && w.Ref.HasRegion(region) {
		return from
	}
	return openHub(from)
}

// SessionWorldHooks is the session's part of every instance's hooks; cmd/server
// chains its own Open (the nests) before this one's.
func SessionWorldHooks() gameworld.Hooks {
	return gameworld.Hooks{
		Open:         openWorldRuntime,
		Tick:         tickWorldRuntime,
		Spawned:      worldSpawned,
		Warn:         worldWarn,
		Close:        worldClose,
		Message:      worldMessage,
		ZoneSwitched: worldZoneSwitched,
		LoadMonster:  worldLoadMonster,
		Other:        worldOtherAction,
		PartyMaster:  worldPartyMaster,
	}
}

func openWorldRuntime(w *gameworld.World) {
	rt := &worldRuntime{}
	if s := aiSetup.Load(); s != nil {
		rt.ai = newMonsterAI(w.Hub, w.Monsters, s.logger, s.cfg, rand.New(rand.NewSource(time.Now().UnixNano()^int64(w.Key))), nil)
	}
	rt.aoi = newMonsterAOI(w.Hub, w.Monsters, aoiLogger.Load())
	if rt.npc == nil {
		if prev := runtimeOfWorld(w); prev != nil {
			rt.npc = prev.npc
		}
	}
	w.Ext = rt
}

// SetInstanceNPCs files an instance's NPCs (its NPC nests, cmd/server's
// builder): spawned to the layer's players by its area of interest, selected
// and talked to as the open world's are.
func SetInstanceNPCs(w *gameworld.World, npcs []npcspawn.NPC, logger *slog.Logger) int {
	if len(npcs) == 0 {
		return 0
	}
	bucket, fx, fy, ok := InstanceFrame(w)
	if !ok {
		return 0
	}
	n := newNPCWorldAt(npcs, logger, bucket, fx, fy)
	rt := runtimeOfWorld(w)
	if rt == nil {
		rt = &worldRuntime{}
		w.Ext = rt
	}
	rt.npc = n
	return n.placed
}

func tickWorldRuntime(w *gameworld.World, now time.Time) {
	rt := runtimeOfWorld(w)
	if rt == nil {
		return
	}
	if rt.ai != nil {
		rt.ai.tick(now)
	}
	if rt.aoi != nil {
		rt.aoi.reconcile()
	}
}

func worldSpawned(w *gameworld.World, ids []int64) {
	for _, id := range ids {
		BroadcastMonsterSpawned(w.Hub, w.Monsters, id)
	}
}

// noticePacket is a 0x300C payload on OpenSRO's notice opcode (round 657's
// OpUniqueNotice, which the client's notice_word path reads).
func noticePacket(payload []byte) *proto.Packet {
	return &proto.Packet{Opcode: OpUniqueNotice, Data: payload}
}

// worldWarn is a GAMEWORLD_DISAPPEARANCE_TIME threshold passed: 0x300C
// {0x0C1A, u8 minutes} to everyone in the layer (game_worlds.md 4).
func worldWarn(w *gameworld.World, left time.Duration) {
	pkt := noticePacket(gameworld.EncodeCloseWarning(left))
	for _, e := range w.Hub.AllEntities() {
		e.Session.Send(pkt)
	}
}

// worldClose takes everyone still inside to the return point (READ
// s:0x5f80b0), then forgets the layer's runtimes.
func worldClose(w *gameworld.World, reason gameworld.CloseReason) {
	for _, e := range w.Hub.AllEntities() {
		if err := returnFromInstance(context.Background(), e.Session, w.Hub, "instance close"); err != nil {
			if l := gameWorldDeps().Logger; l != nil {
				l.Warn("instance close: return failed", "character_id", e.CharacterID, "err", err)
			}
		}
	}
	for _, m := range w.Monsters.AppendAll(nil) {
		statusFX.forgetMonster(m.ID)
	}
	// Round 869 lane W3 (fgw.go): the layer's gates go with it, and its
	// pending summons.
	removeGatesOf(w)
	forgetSummonsOf(w)
}

func worldMessage(w *gameworld.World, kind uint8, key string, targets []int64) {
	pkt := noticePacket(gameworld.EncodeTriggerNotice(kind, key))
	for _, id := range targets {
		if e, ok := w.Hub.EntityByCharacterID(id); ok {
			// Round 869 lane W3: an entering player hears it with its
			// arrival (MEASURED: right after its 0x3012).
			sendAfterArrival(id, e.Session, pkt, false)
		}
	}
}

// worldZoneSwitched is 0x351E {u32 object, u8 0x10, u8 state} to the layer's
// players (READ s:0x52f120 broadcasts it on a change).
func worldZoneSwitched(w *gameworld.World, z *gameworld.EventZoneObj) {
	pkt := &proto.Packet{Opcode: proto.OpEventZoneState, Data: gameworld.EncodeEventZoneState(z.UID, z.WireState())}
	for _, e := range w.Hub.AllEntities() {
		e.Session.Send(pkt)
	}
}

func worldLoadMonster(w *gameworld.World, code string, count int, num1 int64, targets []int64) {
	d := gameWorldDeps()
	if d.Spawn == nil {
		return
	}
	for _, id := range targets {
		e, ok := w.Hub.EntityByCharacterID(id)
		if !ok {
			continue
		}
		for i := 0; i < count; i++ {
			if mid, ok := d.Spawn(w, code, e.Zone, e.Pos.X, e.Pos.Y, e.Pos.Z); ok {
				BroadcastMonsterSpawned(w.Hub, w.Monsters, mid)
			}
		}
	}
}

func worldOtherAction(w *gameworld.World, a trigger.Action, ev trigger.Event, targets []int64) {
	if l := gameWorldDeps().Logger; l != nil {
		l.Info("trigger action not carried (OPEN / later content)", "world", w.ID.String(), "action", a.Kind)
	}
}

func worldPartyMaster(w *gameworld.World) int64 {
	d := gameWorldDeps()
	if d.Parties == nil {
		return 0
	}
	for _, id := range w.Members() {
		if p, ok := d.Parties.Get(id); ok {
			return p.LeaderID
		}
	}
	return 0
}

// returnPoint is where a character entered an instance from: its return
// point (the original keeps it in _Char, which the warp in does not
// overwrite: READ s:0x4df666..0x4df68f).
type returnPoint struct {
	zone, bucket, frame string
	pos                 world.Position
}

var instanceReturns sync.Map // character id -> returnPoint

// returnPlaceOf is characterID's return point: the one kept at its entry,
// else the character row's saved place, else its start.
func returnPlaceOf(ctx context.Context, chars character.Store, characterID int64) (returnPoint, bool) {
	if v, ok := instanceReturns.Load(characterID); ok {
		return v.(returnPoint), true
	}
	if chars == nil {
		return returnPoint{}, false
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return returnPoint{}, false
	}
	if zone, bucket, pos, frame, ok := restoredArrival(c); ok {
		return returnPoint{zone, bucket, frame, pos}, true
	}
	if zone, bucket, pos, frame, ok := startArrival(c); ok {
		return returnPoint{zone, bucket, frame, pos}, true
	}
	zone := startZones[character.RaceChina]
	bucket, pos, frame, _ := arrival(zone)
	return returnPoint{zone, bucket, frame, pos}, true
}

// instanceArrival is where a character is put in layer w: one of its start
// positions (rng picks it, READ s:0x6029e0), named in the layer's zone and
// frame (the first start's, InstanceFrame), standing on the walkable surface
// nearest the start's height. Round 870: READ CGObj::EnterWorld s:0x485360
// (ResolveCellAndHeight) -- the Wrecked Ship's starts are ~10 above their
// decks (MEASURED -770 over -779.1, -247 over -257.6), and the deck, a
// compound object's navigation mesh, is the surface, not the sea floor's
// terrain under it. The entry and /unstuck inside a layer (round 871) both
// place through it.
func instanceArrival(w *gameworld.World, rng *rand.Rand) (start gameworld.StartPos, zone, bucket string, pos world.Position, frame string, err error) {
	start, ok := gameworld.StartPosOf(w.Ref, rng)
	if !ok {
		return start, "", "", world.Position{}, "", fmt.Errorf("world %d has no start position", w.ID.World)
	}
	first := w.Ref.Starts[0]
	zone, _, _, frame, ok = placeRegion(int(first.Region), first.X, first.Y, first.Z, true)
	if !ok {
		return start, "", "", world.Position{}, "", fmt.Errorf("start region %#04x cannot be placed", first.Region)
	}
	bucket, pos, ok = InstancePlace(w, start.Region, start.X, start.Y, start.Z)
	if !ok {
		return start, "", "", world.Position{}, "", fmt.Errorf("start region %#04x cannot be placed", start.Region)
	}
	if y, ok := navArrivalHeight(bucket, pos); ok {
		pos.Y = y
	}
	return start, zone, bucket, pos, frame, nil
}

// EnterInstance warps sess's character into w at a random start position
// (READ s:0x6029e0), keeping its return point, recording its
// _CharInstanceWorldData row and starting (or keeping) its group cool time
// with the 0x320C push (READ s:0x60a070). The checks are the caller's
// (CanEnter, the portal's). The client hears the ordinary zone change.
func EnterInstance(ctx context.Context, sess *gateway.Session, w *gameworld.World, via string) error {
	d := gameWorldDeps()
	from := sessionHub(sess)
	if from == nil {
		from = openHub(nil)
	}
	if from == nil {
		return fmt.Errorf("not in the world")
	}
	e, ok := from.EntityBySession(sess.ID())
	if !ok {
		return fmt.Errorf("not in the world")
	}
	start, zone, bucket, pos, frame, err := instanceArrival(w, rand.New(rand.NewSource(time.Now().UnixNano())))
	if err != nil {
		return err
	}
	// The return point: where the character stood, saved now (the move in
	// saves nothing: savePosition skips an instance).
	if instanceOf(from) == nil {
		p, _ := placeOf(sess)
		rp := returnPoint{zone: p.zone, bucket: e.Zone, frame: p.frame, pos: e.Pos}
		instanceReturns.Store(e.CharacterID, rp)
		savePosition(d.Chars, sess, e)
		// Round 869 lane W2: the registry keeps it too, for a recovery
		// when the instance's host dies (handoff.go).
		clusterSetReturn(ctx, e.CharacterID, rp)
	}
	// Round 869 lane W3: the re-entry limit's 0x320C is queued for the
	// arrival before the warp (MEASURED: it comes after the arrival state,
	// behind the entry notices), so it cannot overtake them. A layer on
	// another process (lane W2) sends its own at the hand-off's arrival.
	now := w.Clock().Now()
	coolPkt, fresh := startGroupCoolTime(ctx, e.CharacterID, w, now)
	guarded := arrivalGuardOn.Load()
	remote := w.Remote()
	if coolPkt != nil && guarded && !remote {
		queueForArrival(e.CharacterID, coolPkt, true)
	}
	if remote {
		// Round 869 lane W2: a layer another process runs: the hand-off
		// there (handoff.go), the same zone change for the client.
		if err := handOffToInstance(sess, w, zone, bucket, pos, frame, via); err != nil {
			return err
		}
	} else if _, err := warpAcross(ctx, sess, d.Equipment, d.Chars, from, w.Hub, d.Zerk, zone, bucket, pos, frame, via); err != nil {
		dropArrivalSends(e.CharacterID)
		return err
	}
	// Round 870, MEASURED: a new limit's 0x320C comes twice -- right after
	// the entry notice pair and again in the arrival state -- and a running
	// one's (a re-entry) once, in the arrival state. Held, the first goes
	// out right after the arrival's early sends (the notices); unheld, it is
	// posted to the layer behind the entry's triggers (World.Enter fired
	// them). A layer on another process sends its own (lane W2's hand-off).
	if coolPkt != nil && fresh && !remote {
		if guarded {
			queueAfterEarly(e.CharacterID, coolPkt)
		} else {
			w.Post(func() { _ = sess.Send(coolPkt) })
		}
	}
	if coolPkt != nil && !guarded && !remote {
		w.Sync()
		_ = sess.Send(coolPkt)
	}
	if d.Instances != nil {
		row, _, _ := d.Instances.Get(ctx, e.CharacterID, w.ID.World)
		if row.Key != w.Key {
			row = gameworld.CharInstance{CharID: e.CharacterID}
		}
		row.Key, row.World, row.Layer, row.Opened = w.Key, w.ID.World, w.ID.Layer, w.Created
		row.Region, row.X, row.Y, row.Z = start.Region, int32(start.X), int32(start.Y), int32(start.Z)
		row.Activated, row.EnterCount, row.LastEnterTime = true, row.EnterCount+1, now
		if err := d.Instances.Put(ctx, row); err != nil && d.Logger != nil {
			d.Logger.Warn("instance row not saved", "character_id", e.CharacterID, "err", err)
		}
	}
	return nil
}

// startGroupCoolTime is the re-entry limit's timed job at an entry: a new
// one for this instance, or the running one kept (re-entering the same
// instance does not restart it -- INFERRED: the job holds the key it was
// started for). It answers its 0x320C {0x0C, group, remaining} for the
// client (nil for none) and whether the job is new.
func startGroupCoolTime(ctx context.Context, characterID int64, w *gameworld.World, now time.Time) (*proto.Packet, bool) {
	g := w.Ref.Group
	d := gameWorldDeps()
	if g == nil || g.CoolTime <= 0 || d.Timed == nil {
		return nil, false
	}
	job, running := groupCoolTime(ctx, characterID, g.ID, now)
	fresh := !running || uint32(job.Key) != w.Key
	if fresh {
		job = timedjob.Job{CharID: characterID, Type: TimedJobWorldGroup, Ref: int64(g.ID), Key: int64(w.Key),
			Start: now, End: now.Add(g.CoolTime), V1: int64(w.ID.World), V2: int64(w.ID.Layer)}
		if err := d.Timed.Put(ctx, job); err != nil && d.Logger != nil {
			d.Logger.Warn("group cool time not saved", "character_id", characterID, "err", err)
		}
	}
	// Round 869 lane W3 / round 870: sent with the arrival (EnterInstance
	// places it; MEASURED twice for a new limit, once for a running one).
	return &proto.Packet{Opcode: proto.OpTimedJobPush, Data: gameworld.EncodeGroupCoolTime(uint32(g.ID), job.End.Sub(now))}, fresh
}

// groupCoolTime is characterID's running limit of group, if any.
func groupCoolTime(ctx context.Context, characterID int64, group int, now time.Time) (timedjob.Job, bool) {
	d := gameWorldDeps()
	if d.Timed == nil {
		return timedjob.Job{}, false
	}
	jobs, err := d.Timed.List(ctx, characterID)
	if err != nil {
		return timedjob.Job{}, false
	}
	for _, j := range jobs {
		if j.Type == TimedJobWorldGroup && j.Ref == int64(group) && now.Before(j.End) {
			return j, true
		}
	}
	return timedjob.Job{}, false
}

// coolTimesOf is characterID's running group limits, for CanEnter.
func coolTimesOf(ctx context.Context, characterID int64, now time.Time) []gameworld.CoolTime {
	d := gameWorldDeps()
	if d.Timed == nil {
		return nil
	}
	jobs, err := d.Timed.List(ctx, characterID)
	if err != nil {
		return nil
	}
	var out []gameworld.CoolTime
	for _, j := range jobs {
		if j.Type == TimedJobWorldGroup && now.Before(j.End) {
			out = append(out, gameworld.CoolTime{Group: int(j.Ref), Key: uint32(j.Key), End: j.End})
		}
	}
	return out
}

// groupCoolTimePackets is a 0x320C {0x0C, group, remaining s} for each of
// characterID's running group limits.
func groupCoolTimePackets(ctx context.Context, characterID int64, now time.Time) []*proto.Packet {
	var out []*proto.Packet
	for _, ct := range coolTimesOf(ctx, characterID, now) {
		out = append(out, &proto.Packet{Opcode: proto.OpTimedJobPush, Data: gameworld.EncodeGroupCoolTime(uint32(ct.Group), ct.End.Sub(now))})
	}
	return out
}

// returnFromInstance warps sess's character from the instance hub `from` to
// its return point in the open world (the exit NPC, the layer's close).
func returnFromInstance(ctx context.Context, sess *gateway.Session, from *world.Hub, via string) error {
	d := gameWorldDeps()
	e, ok := from.EntityBySession(sess.ID())
	if !ok {
		return fmt.Errorf("not in the instance")
	}
	rp, ok := returnPlaceOf(ctx, d.Chars, e.CharacterID)
	if !ok {
		return fmt.Errorf("no return point")
	}
	to := openHub(from)
	if to == from {
		return fmt.Errorf("no open world")
	}
	// Round 870, MEASURED: the arrival back in town (the exit NPC's and the
	// close's) carries the running limit's 0x320C in its arrival state, as
	// every arrival does; the icon stays.
	cool := groupCoolTimePackets(ctx, e.CharacterID, time.Now())
	guarded := arrivalGuardOn.Load()
	if guarded {
		for _, p := range cool {
			queueForArrival(e.CharacterID, p, true)
		}
	}
	_, err := warpAcross(ctx, sess, d.Equipment, d.Chars, from, to, d.Zerk, rp.zone, rp.bucket, rp.pos, rp.frame, via)
	if err != nil {
		dropArrivalSends(e.CharacterID)
	} else if !guarded {
		for _, p := range cool {
			_ = sess.Send(p)
		}
	}
	instanceReturns.Delete(e.CharacterID)
	clusterClearReturn(ctx, e.CharacterID)
	return err
}

// entrantOf is what CanEnter reads of e.
func entrantOf(ctx context.Context, e world.Entity, gm bool, now time.Time) gameworld.Entrant {
	en := gameworld.Entrant{CharID: e.CharacterID, Level: e.Level, GM: gm,
		JobSuit: inJobMode(ctx, e.CharacterID), Riding: riderMount(e.CharacterID) != nil,
		TradeCOS: ownsTransport(e.CharacterID), CoolTimes: coolTimesOf(ctx, e.CharacterID, now)}
	if _, _, stalled := stallOf(e.CharacterID); stalled || exchangeEstablished(e.CharacterID) {
		en.Busy = true
	}
	if ps := gameWorldDeps().Parties; ps != nil {
		if p, ok := ps.Get(e.CharacterID); ok {
			en.InParty, en.PartyMembers = true, len(p.Members)
		}
	}
	return en
}

// Portal is an object whose kind-3 teleport (0x705A {u32 object, u8 3, u8
// index}) enters an instance: the Dimension-hole gate (lane W3 registers it
// with RegisterPortal). Its access rule is READ s:0x4865a0: 6 admits only the
// owner's character, 7 the owner's party.
type Portal struct {
	UID    uint32
	World  *gameworld.World
	Access uint8
	Owner  int64 // the creator's character (access 6)
	Party  int64 // the creator's party (access 7)
	// Destinations are the portal's teleport-ref links' arrivals; index 0 is
	// the world's start (forgotten_world.md 4: one kind-2 destination).
	Destinations int
}

var portals sync.Map // uid -> *Portal

// RegisterPortal files a portal; UnregisterPortal drops it (the gate's
// removal with its layer).
func RegisterPortal(p *Portal)    { portals.Store(p.UID, p) }
func UnregisterPortal(uid uint32) { portals.Delete(uid) }
func portalOf(uid uint32) *Portal {
	if v, ok := portals.Load(uid); ok {
		return v.(*Portal)
	}
	return nil
}

// The portal teleport's replies (READ game_worlds.md 5): {2, 1} accepted
// (the warp queued), then {1} the warp done or {2, code} refused.
func teleportUseReply(ok bool, code uint16) []byte {
	if ok {
		return []byte{1}
	}
	b := []byte{2}
	return binary.LittleEndian.AppendUint16(b, code)
}

// InstanceTeleportHandler answers 0x705A kind 3, a portal into an instance
// (game_worlds.md 5; forgotten_world.md 5). Other kinds are not this
// handler's (OpenSRO's own teleport is 0x00F3).
func InstanceTeleportHandler(gate func(username string) bool) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != proto.OpTeleportUse {
			return nil
		}
		if len(p.Data) < 5 || p.Data[4] != 3 {
			return nil
		}
		uid := binary.LittleEndian.Uint32(p.Data)
		index := -1
		if len(p.Data) >= 6 {
			index = int(p.Data[5])
		}
		// HandleTeleportUse always ends with {2, code}: 1, the warp queued
		// (s:0x513a33 through s:0x4e7250).
		if err := sess.Send(&proto.Packet{Opcode: proto.OpTeleportUseAck, Data: teleportUseReply(false, 1)}); err != nil {
			return err
		}
		code := portalEntry(ctx, sess, uid, index, gate)
		if code != 0 {
			return sess.Send(&proto.Packet{Opcode: proto.OpTeleportUseAck, Data: teleportUseReply(false, code)})
		}
		return nil
	}
}

// portalEntry is the warp handler's portal path (READ s:0x4f37dc ->
// s:0x4f3347), in order: the player set (OPEN: what fills it), flag 0x40000
// (OPEN: never set by OpenSRO), a trade transport 0x1c10, the portal's access
// 0x1c2f, the destination 2, CanEnter (its 2 and 6 as 3), then the warp,
// whose failure is 3. 0 is entered: {1} has gone out before the zone change.
func portalEntry(ctx context.Context, sess *gateway.Session, uid uint32, index int, gate func(string) bool) uint16 {
	from := sessionHub(sess)
	if from == nil {
		return gameworld.CodeRefused
	}
	e, ok := from.EntityBySession(sess.ID())
	if !ok {
		return gameworld.CodeRefused
	}
	pt := portalOf(uid)
	if pt == nil || pt.World == nil {
		return gameworld.CodeRefused
	}
	if ownsTransport(e.CharacterID) {
		return gameworld.CodeTradeCOS
	}
	switch pt.Access {
	case 6:
		if e.CharacterID != pt.Owner {
			return gameworld.CodeAccess
		}
	case 7:
		var pp *party.Party
		inParty := false
		if ps := gameWorldDeps().Parties; ps != nil {
			pp, inParty = ps.Get(e.CharacterID)
		}
		if !inParty || int64(pp.ID) != pt.Party {
			return gameworld.CodeAccess
		}
	}
	if index < 0 || index >= max(pt.Destinations, 1) {
		return gameworld.CodeNoDestination
	}
	username, _ := AuthenticatedUsername(sess)
	gm := gate != nil && gate(username)
	now := pt.World.Clock().Now()
	if c := gameworld.CanEnter(pt.World, entrantOf(ctx, e, gm, now), now); c != 0 {
		return gameworld.ReplyCode(c)
	}
	if err := sess.Send(&proto.Packet{Opcode: proto.OpTeleportUseAck, Data: teleportUseReply(true, 0)}); err != nil {
		return 0
	}
	if err := EnterInstance(ctx, sess, pt.World, "instance gate"); err != nil {
		if l := gameWorldDeps().Logger; l != nil {
			l.Warn("instance entry failed after the accept", "character_id", e.CharacterID, "err", err)
		}
	}
	return 0
}

// The exit NPC (READ s:0x51c050; game_worlds.md 5): 0x751D {u32 npc} ->
// 0xB51D {u8 1} or {u8 2, u16 code} (error category 1, c:0x89a760).
func exitReply(code uint16) []byte {
	if code == 0 {
		return []byte{1}
	}
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

// isExitNPC reports an NPC record of the instance exit (NPC_INS_EXIT_TELEPORT,
// interaction 0x29).
func isExitNPC(n *npcspawn.NPC) bool {
	return n != nil && strings.HasPrefix(strings.ToUpper(strings.TrimSpace(n.Code)), "NPC_INS_EXIT_TELEPORT")
}

// InstanceExitHandler answers 0x751D: the exit NPC's warp to the return
// point. Refusals in the READ order: dead 0x1c36, a trade transport 0x1c10,
// busy 2; an NPC that is not an exit NPC of the caller's layer is 2 (OURS:
// the original's lookup failure was not read).
func InstanceExitHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != proto.OpInstanceExit {
			return nil
		}
		code := instanceExit(ctx, sess, p.Data)
		if code != 0 {
			return sess.Send(&proto.Packet{Opcode: proto.OpInstanceExitAck, Data: exitReply(code)})
		}
		return nil
	}
}

func instanceExit(ctx context.Context, sess *gateway.Session, data []byte) uint16 {
	if len(data) < 4 {
		return 2
	}
	hub := sessionHub(sess)
	w := instanceOf(hub)
	if w == nil {
		return 2
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return 2
	}
	uid := binary.LittleEndian.Uint32(data)
	if pl, found := npcInWorld(hub, uid, e.Zone); !found || !isExitNPC(pl.npc) {
		return 2
	}
	if e.Life == world.LifeDead {
		return gameworld.CodeDead
	}
	if ownsTransport(e.CharacterID) {
		return gameworld.CodeTradeCOS
	}
	if _, _, stalled := stallOf(e.CharacterID); stalled || exchangeEstablished(e.CharacterID) {
		return 2
	}
	if err := sess.Send(&proto.Packet{Opcode: proto.OpInstanceExitAck, Data: exitReply(0)}); err != nil {
		return 0
	}
	if err := returnFromInstance(ctx, sess, hub, "instance exit"); err != nil {
		if l := gameWorldDeps().Logger; l != nil {
			l.Warn("instance exit failed after the accept", "character_id", e.CharacterID, "err", err)
		}
	}
	return 0
}

// npcInWorld is npcInZone in hub's world.
func npcInWorld(hub *world.Hub, uid uint32, zone string) (npcPlacement, bool) {
	w := npcWorldFor(hub)
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

// instanceNPCUIDSeq numbers the instances' NPCs (OURS: above the open
// world's npcspawn.UIDBase range, so every "is it an NPC" test holds).
var instanceNPCUIDSeq atomic.Uint32

const instanceNPCUIDBase uint32 = 0x7fc00000

// NextInstanceNPCUID is a fresh unique id for an instance's NPC.
func NextInstanceNPCUID() uint32 { return instanceNPCUIDBase + instanceNPCUIDSeq.Add(1)&0x003fffff }

// InstanceFrame is the bucket and frame of an instance: those its first start
// position is placed in (placeRegion), which every region of the world
// shares -- so its players, monsters and NPCs are in one bucket. ok is false
// for a world with no start position.
func InstanceFrame(w *gameworld.World) (bucket string, fx, fy int, ok bool) {
	if w == nil || len(w.Ref.Starts) == 0 {
		return "", 0, 0, false
	}
	st := w.Ref.Starts[0]
	_, bucket, _, frame, placed := placeRegion(int(st.Region), st.X, st.Y, st.Z, true)
	if !placed {
		return "", 0, 0, false
	}
	fx, fy, ok = worldmap.ParseRegionLabel(frame)
	if !ok && worldmap.IsDungeonRegion(int(st.Region)) {
		return bucket, 0, 0, true
	}
	return bucket, fx, fy, ok
}

// InstancePlace is where a region-local point of an instance stands in its
// bucket and frame (InstanceFrame): the nests' and NPCs' placement.
func InstancePlace(w *gameworld.World, region uint16, x, y, z float64) (bucket string, pos world.Position, ok bool) {
	if worldmap.IsDungeonRegion(int(region)) {
		wx, wy, wz := worldmap.DungeonToWorld(x, y, z)
		return worldmap.DungeonZone(int(region)), world.Position{X: wx, Y: wy, Z: wz}, true
	}
	bucket, fx, fy, ok := InstanceFrame(w)
	if !ok {
		return "", world.Position{}, false
	}
	rx, ry := worldmap.RegionXY(int(region))
	wx, wz := worldmap.ToWorld(rx, ry, x, z, fx, fy)
	return bucket, world.Position{X: wx, Y: y, Z: wz}, true
}
