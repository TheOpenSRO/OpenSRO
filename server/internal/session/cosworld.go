package session

import (
	"context"
	"log/slog"
	"math"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The COS in the world (round 795): the pets, rides and transports a
// character has called out, as SR_GameServer.exe keeps them -- docs/protocol/
// pets.md, "Round 795", has every rule with its address. This file is the
// registry and how a COS reaches the clients; cossummon.go is the summon and
// the release, coscommand.go the client's requests, cosride.go riding and
// cosai.go what a COS does every tick.
//
// Who sees a COS (OURS, a departure disclosed): retail files a COS in its own
// message block like any object. OpenSRO's COS stays within its leash of its
// owner, so it is delivered with its owner: it is spawned to a client right
// after the owner's own spawn (playerSpawn.after) and despawned with the
// owner's despawn, and every message about it goes to the clients that hold
// the owner (sendAboutPlayer). The owner's own client hears all of it.

// cosUIDBase is the first COS unique id (OURS): a range of its own beside the
// NPCs' 0x7f000000 (npcspawn.UIDBase) and the characters' ids, which share
// the retail spawn messages with it.
const cosUIDBase uint32 = 0x7e000000

// cosObj is one COS in the world. Its fields are guarded by cosWorld.mu.
type cosObj struct {
	uid    uint32
	owner  int64 // character id
	rec    cos.Record
	row    species.Row
	kind   int   // the row's TypeID4
	itemID int64 // the summon item's RefItemID (pets; 0 for a ride)
	zone   string
	pos    world.Position
	// heading is radians, as world.Entity's.
	heading float64
	// The leg it walks, when moving.
	moving   bool
	from, to world.Position
	legStart time.Time
	legSpeed float64
	// ridden: its owner sits on it (cosride.go).
	ridden bool
	// The tick's clocks (cosai.go).
	hgpAcc    float64
	regenAt   time.Time
	rentAt    time.Time
	lastTick  time.Time
	target    int64 // a growth pet's monster
	nextSwing time.Time
	pick      int64 // an ability pet's ground item
	dead      bool
	// Round 851 (cosfollow.go): FOLLOW (true) or IDLE; a pet's slot of
	// eight round its owner (hasSlot); a pet's run speed matched to its
	// owner's (0: the row's).
	following bool
	slot      int
	hasSlot   bool
	runSpeed  float64
}

// at is where o stands at now.
func (o *cosObj) at(now time.Time) world.Position {
	if !o.moving || o.legSpeed <= 0 {
		return o.pos
	}
	dx, dz := o.to.X-o.from.X, o.to.Z-o.from.Z
	dist := math.Hypot(dx, dz)
	d := o.legSpeed * now.Sub(o.legStart).Seconds()
	if dist <= 0 || d >= dist {
		return o.to
	}
	f := d / dist
	return world.Position{X: o.from.X + dx*f, Y: o.from.Y + (o.to.Y-o.from.Y)*f, Z: o.from.Z + dz*f}
}

// settle ends a finished leg.
func (o *cosObj) settle(now time.Time) {
	if !o.moving {
		return
	}
	o.pos = o.at(now)
	if o.pos == o.to {
		o.moving = false
	}
}

// cosDeps are the stores the runtime works through, bound once by
// cmd/server (SetCOSDeps).
type cosDeps struct {
	store   cos.Store
	bags    inventory.Store // the COS bags, keyed by COS id
	table   *species.Table
	inv     inventory.Store
	items   combat.ItemLookup
	chars   character.Store
	hub     *world.Hub
	mons    *combat.Hub
	logger  *slog.Logger
	enabled bool
	// skillLookup resolves a row's col-83 attack (species.Row.Attacks).
	skillLookup species.SkillLookup
}

// cosRuntime is every COS in the world. Its stores (deps) sit apart from
// mu: the tick reads them while it holds mu.
type cosRuntime struct {
	mu      sync.Mutex
	next    uint32
	byUID   map[uint32]*cosObj
	byOwner map[int64][]*cosObj
	deps    atomic.Pointer[cosDeps]
}

var cosWorld = &cosRuntime{byUID: map[uint32]*cosObj{}, byOwner: map[int64][]*cosObj{}}

// SetCOSDeps binds the COS runtime's stores (cmd/server). A server without a
// COS table summons nothing: every COS item answers "cannot be used".
func SetCOSDeps(store cos.Store, bags inventory.Store, table *species.Table, skills species.SkillLookup, inv inventory.Store,
	items combat.ItemLookup, chars character.Store, hub *world.Hub, mons *combat.Hub, logger *slog.Logger) {
	if logger == nil {
		logger = slog.Default()
	}
	cosWorld.deps.Store(&cosDeps{store: store, bags: bags, table: table, inv: inv, items: items, chars: chars,
		hub: hub, mons: mons, logger: logger, skillLookup: skills,
		enabled: store != nil && table != nil && table.Len() > 0})
}

func (w *cosRuntime) depsNow() cosDeps {
	if d := w.deps.Load(); d != nil {
		return *d
	}
	return cosDeps{logger: slog.Default()}
}

// add registers o under a fresh uid.
func (w *cosRuntime) add(o *cosObj) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for {
		w.next++
		uid := cosUIDBase + w.next&0x00ffffff
		if _, taken := w.byUID[uid]; !taken {
			o.uid = uid
			break
		}
	}
	w.byUID[o.uid] = o
	w.byOwner[o.owner] = append(w.byOwner[o.owner], o)
}

// remove drops o from the registry; false when it was not there.
func (w *cosRuntime) remove(o *cosObj) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.byUID[o.uid] != o {
		return false
	}
	delete(w.byUID, o.uid)
	list := w.byOwner[o.owner]
	for i, x := range list {
		if x == o {
			list = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(list) == 0 {
		delete(w.byOwner, o.owner)
	} else {
		w.byOwner[o.owner] = list
	}
	return true
}

// get is the COS with uid, nil when none.
func (w *cosRuntime) get(uid uint32) *cosObj {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.byUID[uid]
}

// owned is owner's COS in summon order (a copy of the list).
func (w *cosRuntime) owned(owner int64) []*cosObj {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]*cosObj(nil), w.byOwner[owner]...)
}

// ownedOf is owner's COS whose uid is uid, nil when none.
func (w *cosRuntime) ownedOf(owner int64, uid uint32) *cosObj {
	w.mu.Lock()
	defer w.mu.Unlock()
	if o := w.byUID[uid]; o != nil && o.owner == owner {
		return o
	}
	return nil
}

// byRecord is the COS in the world whose record is id, nil when none.
func (w *cosRuntime) byRecord(id int64) *cosObj {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, o := range w.byUID {
		if o.rec.ID == id {
			return o
		}
	}
	return nil
}

// ridden is the COS owner rides, nil when none.
func (w *cosRuntime) ridden(owner int64) *cosObj {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, o := range w.byOwner[owner] {
		if o.ridden {
			return o
		}
	}
	return nil
}

// spawnRecord is o's CICCos record as it stands now. The caller holds no lock.
func (w *cosRuntime) spawnRecord(o *cosObj, now time.Time) []byte {
	w.mu.Lock()
	o.settle(now)
	pos, heading, moving, to, speed := o.at(now), o.heading, o.moving, o.to, o.legSpeed
	life := byte(world.LifeAlive)
	if o.dead {
		life = byte(world.LifeDead)
	}
	r := cos.SpawnRecord{RefID: uint32(o.row.ID), TypeID4: o.kind, UID: o.uid,
		Life: life, Walk: float32(o.row.WalkSpeed), Run: float32(o.runSpeedNow()),
		Name: o.rec.Name, OwnerJob: 4}
	zone, owner, ridden := o.zone, o.owner, o.ridden
	w.mu.Unlock()
	region, lx, lz := regionLocalOf(zone, pos)
	r.Region, r.X, r.Y, r.Z = region, float32(lx), float32(pos.Y), float32(lz)
	r.Angle = proto.EncodeMovementAngle(world.WireAngle(heading))
	r.Running = speed >= float64(r.Run)-0.01 || speed == 0
	if moving && !ridden {
		dr, dx, dz := regionLocalOf(zone, to)
		r.HasDest, r.DestRegion = true, dr
		r.DestX, r.DestY, r.DestZ = int16(dx), int16(to.Y), int16(dz)
		r.Motion = 3
	}
	if e, ok := cosOwnerEntity(owner); ok {
		r.OwnerName = e.Name
		r.OwnerUID = uint32(e.CharacterID)
		// Round 800: the owner's job state, and its alias while it wears a
		// suit (READ the COS record's owner name s:0x4d1c90 reads
		// GetNickName in job mode).
		ctx := context.Background()
		r.OwnerJob = jobStateNow(ctx, owner)
		if r.OwnerJob != pcspawn.JobStateNone {
			if a := jobRecord(ctx, owner).Alias; a != "" {
				r.OwnerName = a
			}
		}
	}
	return cos.AppendSpawnRecord(nil, r)
}

// cosOwnerEntity is the owner's hub entity.
func cosOwnerEntity(owner int64) (world.Entity, bool) {
	hub := cosWorld.depsNow().hub
	if hub == nil {
		return world.Entity{}, false
	}
	return hub.EntityByCharacterID(owner)
}

// cosSpawnFrames are the single spawns (0x3015) of owner's COS, for a client
// that is about to hold, or holds, the owner: what follows the owner's own
// spawn (playerSpawn.after).
func cosSpawnFrames(owner int64, now time.Time) []*gateway.Frame {
	var out []*gateway.Frame
	for _, o := range cosWorld.owned(owner) {
		data := append(cosWorld.spawnRecord(o, now), cosSpawnTypeKnown)
		out = append(out, gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleSpawn, Data: data}))
	}
	return out
}

// The 0x3015 spawn-type byte: 1 for a COS that has just been called out
// (the client plays the summon effect and snd_cos_summon on a pet, READ
// c:0x9c5d20), 4 for one met on the way (pcSpawnType, round 737).
const (
	cosSpawnTypeSummoned byte = 1
	cosSpawnTypeKnown    byte = pcSpawnType
)

// cosDespawnUIDs are owner's COS uids, despawned with the owner.
func cosDespawnUIDs(owner int64) []uint32 {
	var out []uint32
	for _, o := range cosWorld.owned(owner) {
		out = append(out, o.uid)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// cosDespawnFrames are the single despawns (0x3016) of owner's COS.
func cosDespawnFrames(owner int64) []*gateway.Frame {
	var out []*gateway.Frame
	for _, uid := range cosDespawnUIDs(owner) {
		out = append(out, gateway.MustFrame(&proto.Packet{Opcode: npcspawn.OpSingleDespawn, Data: npcspawn.SingleDespawn(uid)}))
	}
	return out
}

// sendAboutCOS sends one packet about o to every client that holds o's
// owner, the owner's own included.
func sendAboutCOS(o *cosObj, op uint16, data []byte) {
	sendAboutPlayerPacket(cosWorld.depsNow().hub, o.owner, true, op, data)
}

// sendToCOSOwner sends one packet to o's owner only.
func sendToCOSOwner(o *cosObj, op uint16, data []byte) {
	if e, ok := cosOwnerEntity(o.owner); ok && e.Session != nil {
		_ = e.Session.Send(&proto.Packet{Opcode: op, Data: data})
	}
}

// cosAnnounce spawns o to everyone who holds its owner and the owner itself,
// as just called out, and bumps the owner's state so a spawn of the owner
// being built now is rebuilt with it.
func cosAnnounce(o *cosObj, spawnType byte) {
	bumpPlayerState(o.owner)
	data := append(cosWorld.spawnRecord(o, time.Now()), spawnType)
	sendAboutCOS(o, npcspawn.OpSingleSpawn, data)
}

// cosVanish despawns o from everyone who holds its owner and the owner.
func cosVanish(o *cosObj) {
	bumpPlayerState(o.owner)
	sendAboutCOS(o, npcspawn.OpSingleDespawn, npcspawn.SingleDespawn(o.uid))
}

// cosRow is the COS table's row id, ok false when the table has none.
func cosRow(id int64) (species.Row, bool) {
	return cosWorld.depsNow().table.ByID(id)
}

// cosRowByCode is the COS table's row by code name.
func cosRowByCode(code string) (species.Row, bool) {
	return cosWorld.depsNow().table.ByCode(code)
}

// cosKindOf is a RefObjID's TypeID4 in the COS table, 0 when it is none.
func cosKindOf(ref uint32) int {
	if r, ok := cosRow(int64(ref)); ok {
		return r.TypeID4
	}
	return 0
}

// cosDistance is the flat distance between two points.
func cosDistance(a, b world.Position) float64 { return math.Hypot(a.X-b.X, a.Z-b.Z) }

// cosOwnerLevel is a character's level, 0 when it cannot be read.
func cosOwnerLevel(ctx context.Context, chars character.Store, id int64) int {
	if e, ok := cosOwnerEntity(id); ok && e.Level > 0 {
		return e.Level
	}
	if chars == nil {
		return 0
	}
	if c, err := chars.GetByID(ctx, id); err == nil && c != nil {
		return c.Level
	}
	return 0
}
