package session

// The walk-in teleports (round 773; internal/teleport/walkin.go has the
// READ facts and the zones' OURS shape).
//
// READ, CGObjPC::vslot_309 (0x4ef480) -- what the game server does when a
// mover's path crosses a TELEPORT event zone: refuse when the character is
// already teleporting; take the zone's teleportdata point, which must have
// exactly one link (FUN_004ccb50, asserted); evaluate that link's restriction
// triples (FUN_00513a70) and refuse with its code on the 0xb05a reply; no
// fee is compared or taken on this path; otherwise set the teleport state,
// broadcast it (0x30bf kind 0xb) and, 0.01 s later (.rdata 0xb45df8), move
// the character to the link's destination. The enter/leave flag of the zone
// is not tested.
//
// OURS, disclosed:
//
//   - the zone is a circle and a height band about objectstring's centre
//     (teleport.WalkInRadius, WalkInHeight), tested along each mover's path
//     between the mover pass's samples (every moverPassPeriod), so a run
//     cannot step over one; the height only in a dungeon, whose floors stack
//     -- a field position's height is the client's frame-anchored one, not
//     the table's;
//   - a zone fires on entering it only: a character that arrives standing in
//     one (a teleport's landing beside the way back) must walk out first;
//   - the refusal and the receipt go on OpenSRO's teleport reply
//     (OpTeleportResult, the 0xb05a's stand-in for the NPC teleport too), and
//     a success is told with the receipt the client already takes as "the
//     zone change that follows is a teleport's arrival" -- no 0x30bf kind
//     0xb (OpenSRO's client acts on its own 0 only to end a scroll's
//     casting bar, round 779, which a walk-in never opens);
//   - a dead character, or one in a zone change, does not fire one.

import (
	"context"
	"fmt"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// walkInDelay is vslot_309's delay before the move: 0.01 s (.rdata 0xb45df8).
const walkInDelay = 10 * time.Millisecond

// walkInJump is the farthest two samples of one walk can be apart (OURS):
// a pass is moverPassPeriod, 0.25 s, and the fastest run in the game is under
// 200 units a second; farther is a relocation, not a walk.
const walkInJump = 100.0

// walkInRuntime is the teleporter the zones fire through (TeleportHandler
// installs it); nil: no walk-ins.
var walkInRuntime atomic.Pointer[teleporter]

// walkInZone is one zone placed in a hub bucket's coordinates.
type walkInZone struct {
	w       teleport.WalkIn
	x, y, z float64
	dungeon bool
}

// walkInState is what the zones know of one character: where the last sample
// had it, in which bucket, the zones it stands in, and whether a fire is on
// its way.
type walkInState struct {
	bucket string
	pos    world.Position
	inside map[int]bool
	firing bool
}

// walkInKey is one character in one hub: a test binary runs several hubs,
// each with its own character ids, and one's mover pass must not move
// another's samples.
type walkInKey struct {
	hub *world.Hub
	id  int64
}

var walkIns = struct {
	sync.Mutex
	byBucket map[string][]walkInZone
	byChar   map[walkInKey]*walkInState
}{byBucket: map[string][]walkInZone{}, byChar: map[walkInKey]*walkInState{}}

// installWalkIns sets the teleporter the zones fire through and forgets the
// zones placed for the last one.
func installWalkIns(t *teleporter) {
	walkIns.Lock()
	walkIns.byBucket = map[string][]walkInZone{}
	walkIns.byChar = map[walkInKey]*walkInState{}
	walkIns.Unlock()
	if t == nil || t.network == nil || len(t.network.WalkIns) == 0 {
		walkInRuntime.Store(nil)
		return
	}
	walkInRuntime.Store(t)
}

// zonesInLocked is the walk-in zones placed in bucket's coordinates: a
// dungeon's own, or the field's named in the bucket's frame. Cached per
// bucket. Caller holds walkIns.
func zonesInLocked(network *teleport.Table, bucket string) []walkInZone {
	if zs, ok := walkIns.byBucket[bucket]; ok {
		return zs
	}
	var out []walkInZone
	if rid, ok := dungeonOf(bucket); ok {
		for _, w := range network.WalkIns {
			if worldmap.IsDungeonRegion(w.Region) && worldmap.DungeonRID(w.Region) == rid {
				x, y, z := worldmap.DungeonToWorld(w.X, w.Y, w.Z)
				out = append(out, walkInZone{w: w, x: x, y: y, z: z, dungeon: true})
			}
		}
	} else if fx, fy, ok := entityFrame(bucket); ok {
		for _, w := range network.WalkIns {
			if worldmap.IsDungeonRegion(w.Region) {
				continue
			}
			rx, ry := worldmap.RegionXY(w.Region)
			x, z := worldmap.ToWorld(rx, ry, w.X, w.Z, fx, fy)
			out = append(out, walkInZone{w: w, x: x, y: w.Y, z: z})
		}
	}
	walkIns.byBucket[bucket] = out
	return out
}

// within reports whether p is in zone z.
func (z walkInZone) within(p world.Position) bool {
	if z.dungeon && math.Abs(p.Y-z.y) > teleport.WalkInHeight {
		return false
	}
	return math.Hypot(p.X-z.x, p.Z-z.z) <= teleport.WalkInRadius
}

// crossed reports whether the path from a to b passes through zone z: the
// segment's nearest point to the centre within the radius, and, in a
// dungeon, b's height (or a's) within the band.
func (z walkInZone) crossed(a, b world.Position) bool {
	if z.dungeon && math.Abs(b.Y-z.y) > teleport.WalkInHeight && math.Abs(a.Y-z.y) > teleport.WalkInHeight {
		return false
	}
	dx, dz := b.X-a.X, b.Z-a.Z
	t := 0.0
	if l2 := dx*dx + dz*dz; l2 > 0 {
		t = math.Max(0, math.Min(1, ((z.x-a.X)*dx+(z.z-a.Z)*dz)/l2))
	}
	return math.Hypot(a.X+t*dx-z.x, a.Z+t*dz-z.z) <= teleport.WalkInRadius
}

// noteWalkInArrival records where a character arrived (an entry, a zone
// change, a teleport): the zones it stands in there do not fire until it
// leaves them.
func noteWalkInArrival(hub *world.Hub, characterID int64, bucket string, pos world.Position) {
	t := walkInRuntime.Load()
	if t == nil {
		return
	}
	walkIns.Lock()
	defer walkIns.Unlock()
	st := &walkInState{bucket: bucket, pos: pos, inside: map[int]bool{}}
	for i, z := range zonesInLocked(t.network, bucket) {
		if z.within(pos) {
			st.inside[i] = true
		}
	}
	walkIns.byChar[walkInKey{hub, characterID}] = st
}

// forgetWalkIn drops a character's state (it left the world).
func forgetWalkIn(hub *world.Hub, characterID int64) {
	walkIns.Lock()
	delete(walkIns.byChar, walkInKey{hub, characterID})
	walkIns.Unlock()
}

// walkInClaimJump is walkInJump for a position a client reported (OpMove,
// walkInClaimed; OURS): an older client reports its walk every few seconds,
// and the claim is already bounded by the speed allowance (claimBound), so
// a longer step between two reports is still a walk.
const walkInClaimJump = 400.0

// walkInClaimed tests a position a client's OpMove put the character at --
// a walked report or a stop (round 773): the mover pass sees only the
// server's own movers. A placement (a QA hook, a teleport's landing) is a
// relocation: the zones it stands in count as arrived in.
func walkInClaimed(hub *world.Hub, e world.Entity, relocated bool) {
	if relocated {
		noteWalkInArrival(hub, e.CharacterID, e.Zone, e.Pos)
		return
	}
	walkInTest(hub, []world.Entity{e}, walkInClaimJump)
}

// walkInPass tests the movers the mover pass settled against the zones of
// their buckets and fires the ones entered.
func walkInPass(hub *world.Hub, moved []world.Entity) {
	walkInTest(hub, moved, walkInJump)
}

// walkInTest is walkInPass with the farthest step that still counts as a
// walk.
func walkInTest(hub *world.Hub, moved []world.Entity, jump float64) {
	t := walkInRuntime.Load()
	if t == nil || len(moved) == 0 {
		return
	}
	type fire struct {
		e    world.Entity
		zone walkInZone
	}
	var fires []fire
	walkIns.Lock()
	for _, e := range moved {
		if e.Session == nil {
			continue
		}
		zones := zonesInLocked(t.network, e.Zone)
		st := walkIns.byChar[walkInKey{hub, e.CharacterID}]
		if st == nil || st.bucket != e.Zone {
			// No sample yet in this bucket: this one is the first, and a
			// zone it stands in counts as arrived in.
			st = &walkInState{bucket: e.Zone, pos: e.Pos, inside: map[int]bool{}}
			for i, z := range zones {
				if z.within(e.Pos) {
					st.inside[i] = true
				}
			}
			walkIns.byChar[walkInKey{hub, e.CharacterID}] = st
			continue
		}
		from := st.pos
		st.pos = e.Pos
		if math.Hypot(e.Pos.X-from.X, e.Pos.Z-from.Z) > jump {
			// Not one pass's walk: a relocation (a GM's /tp, a placement)
			// between the samples. The path between is unknown, so nothing
			// fires; the zones it stands in now count as arrived in.
			st.inside = map[int]bool{}
			for i, z := range zones {
				if z.within(e.Pos) {
					st.inside[i] = true
				}
			}
			continue
		}
		for i, z := range zones {
			if st.inside[i] {
				if !z.within(e.Pos) {
					delete(st.inside, i)
				}
				continue
			}
			if !z.crossed(from, e.Pos) {
				continue
			}
			st.inside[i] = true
			if !st.firing && e.Life != world.LifeDead {
				st.firing = true
				fires = append(fires, fire{e: e, zone: z})
			}
		}
	}
	walkIns.Unlock()
	for _, f := range fires {
		f := f
		time.AfterFunc(walkInDelay, func() {
			t.walkIn(context.Background(), hub, f.e.CharacterID, f.zone.w)
			walkIns.Lock()
			if st := walkIns.byChar[walkInKey{hub, f.e.CharacterID}]; st != nil {
				st.firing = false
			}
			walkIns.Unlock()
		})
	}
}

// walkIn is vslot_309 for the character characterID entering zone w.
func (t *teleporter) walkIn(ctx context.Context, hub *world.Hub, characterID int64, w teleport.WalkIn) {
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok || e.Session == nil || e.Life == world.LifeDead {
		return
	}
	sess := e.Session
	// A scroll's cast (round 779, scroll.go): vslot_309 refuses a character
	// already teleporting (the READ above), silently.
	if scrollCastingOn(sess) {
		return
	}
	username, _ := AuthenticatedUsername(sess)
	logRefusal := func(code uint16, reason string, attrs ...any) {
		if t.logger != nil {
			t.logger.Info("walk-in teleport refused", append([]any{"account", username, "zone", w.Code,
				"code", fmt.Sprintf("0x%x", code), "reason", reason}, attrs...)...)
		}
	}
	links := t.network.LinksFrom(w.PointID)
	if len(links) != 1 {
		// The engine asserts exactly one; a zone with none or several moves
		// nobody (17 retail TELEPORT zones have no objectstring entry; the
		// rest one link each).
		logRefusal(0, "the zone's point has no single link", "links", len(links))
		return
	}
	link := links[0]
	dest, _ := t.network.PointByID(link.To)
	zone, bucket, pos, frame, ok := teleportArrival(dest)
	if !ok || !inOpenWorld(dest) {
		logRefusal(0, "the destination is not a place OpenSRO can put a player yet", "dest", dest.Code)
		return
	}
	c, err := t.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return
	}
	if code := teleport.CheckRestrictions(link, c.Level, teleport.PvPNeutral); code != 0 {
		logRefusal(code, teleportRefusalReason(code), "dest", dest.Code, "level", c.Level)
		_ = sess.Send(&proto.Packet{Opcode: OpTeleportResult, Data: (&TeleportResult{Code: code, Reason: teleportRefusalReason(code)}).Encode()})
		return
	}
	if t.logger != nil {
		t.logger.Info("walk-in teleport", "account", username, "character", c.Name, "zone", w.Code,
			"dest", dest.Code, "to_zone", zone, "x", pos.X, "y", pos.Y, "z", pos.Z)
	}
	if err := sess.Send(&proto.Packet{Opcode: OpTeleportResult, Data: (&TeleportResult{OK: true, Destination: dest.ZoneName}).Encode()}); err != nil {
		return
	}
	_, _ = warpTo(ctx, sess, t.eq, t.chars, hub, t.zerk, zone, bucket, pos, frame)
}
