package session

import (
	"math"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

func near851(a, b float64) bool { return math.Abs(a-b) < 1e-3 }

// Round 851: a ride's or transport's FOLLOW point is the 36-table's
// (s:0x549bc9..0x549d64): the side vector's sign by the cross product under
// 0.0078125, then the snap that keeps only the angle's size.
func TestRound851SidePoint(t *testing.T) {
	owner := world.Position{X: 100, Y: 5, Z: 200}
	// The owner faces +Z (heading 0); the COS at (50, 210) facing +Z: the
	// cross is -50, sign -1, side (-1, 0) in the region frame, the negated
	// side (1, 0) at 0 degrees -> entry 0 (5 degrees): (cos 5, -sin 5)
	// locally, (cos 5, sin 5) in the world.
	p := cosSidePoint(owner, 0, world.Position{X: 50, Z: 210}, 0, 15)
	c, s := math.Cos(5*math.Pi/180), math.Sin(5*math.Pi/180)
	if !near851(p.X, 100+15*c) || !near851(p.Z, 200+15*s) || p.Y != 5 {
		t.Fatalf("sign -1: got %+v, want (%.3f, 5, %.3f)", p, 100+15*c, 200+15*s)
	}
	// The COS behind the owner facing +X: the cross is +50, sign +1, side
	// (1, 0), negated at 180 degrees -> entry 18 (185 degrees).
	p = cosSidePoint(owner, 0, world.Position{X: 100, Z: 150}, math.Pi/2, 15)
	c, s = math.Cos(185*math.Pi/180), math.Sin(185*math.Pi/180)
	if !near851(p.X, 100+15*c) || !near851(p.Z, 200+15*s) {
		t.Fatalf("sign +1: got %+v, want (%.3f, %.3f)", p, 100+15*c, 200+15*s)
	}
	// The owner faces +X: the side is (0, +-1) locally, its negation at 90
	// degrees whichever the sign -> entry 9 (95 degrees), toward world +Z
	// both times: the snap reads only the angle's size.
	for _, h := range []float64{0, math.Pi} {
		p = cosSidePoint(owner, math.Pi/2, world.Position{X: 50, Z: 210}, h, 15)
		c, s = math.Cos(95*math.Pi/180), math.Sin(95*math.Pi/180)
		if !near851(p.X, 100+15*c) || !near851(p.Z, 200+15*s) {
			t.Fatalf("facing +X, COS heading %.2f: got %+v, want (%.3f, %.3f)", h, p, 100+15*c, 200+15*s)
		}
	}
}

// Round 851: a pet's slot (s:0x555340 / 0x5554d0 / 0x55e3b0) and its point
// (s:0x55e090).
func TestRound851PetSlots(t *testing.T) {
	var none [8]bool
	if got := cosPickSlot(0, none); got != 0 {
		t.Fatalf("free: %d", got)
	}
	taken := none
	taken[0] = true
	if got := cosPickSlot(0, taken); got != 1 {
		t.Fatalf("0 taken: %d, want 1", got)
	}
	taken[1] = true
	if got := cosPickSlot(0, taken); got != 7 {
		t.Fatalf("0 and 1 taken: %d, want 7", got)
	}
	owner := world.Position{X: 0, Z: 0}
	// Any offset but one exactly along the region's x: slot 0.
	if got := cosPreferredSlot(owner, world.Position{X: 30, Z: 17}); got != 0 {
		t.Fatalf("preferred slot %d, want 0", got)
	}
	if got := cosPreferredSlot(owner, world.Position{X: -30, Z: 0}); got != 1 {
		t.Fatalf("the axis: %d, want 1", got)
	}
	// Slot 0: 22 degrees at BC x 2.4 (BC 5: 12).
	p := cosFormationPoint(owner, 0, 5, nil)
	c, s := math.Cos(22*math.Pi/180), math.Sin(22*math.Pi/180)
	if !near851(p.X, 12*c) || !near851(p.Z, 12*s) {
		t.Fatalf("slot 0: %+v, want (%.3f, %.3f)", p, 12*c, 12*s)
	}
	// Off the mesh past 8: pulled 0.7 at a time -- six pulls, 7.8 away.
	p = cosFormationPoint(owner, 0, 5, func(q world.Position) bool { return math.Hypot(q.X, q.Z) <= 8 })
	if d := math.Hypot(p.X, p.Z); !near851(d, 7.8) {
		t.Fatalf("pulled to %.3f, want 7.8", d)
	}
	// Never off the mesh: 50 pulls at most.
	p = cosFormationPoint(owner, 0, 50, func(world.Position) bool { return false })
	if d := math.Hypot(p.X, p.Z); !near851(d, 120-35) {
		t.Fatalf("50 pulls: %.3f, want 85", d)
	}
}

// Round 851: a pet runs at its owner's speed (s:0x548a30).
func TestRound851PetSpeed(t *testing.T) {
	if v := cosPetSpeed(100, 60, 60, true); !near851(v, 75) {
		t.Fatalf("far, owner running: %v, want 75", v)
	}
	if v := cosPetSpeed(80, 60, 16, false); !near851(v, 60) {
		t.Fatalf("far, owner walking: %v, want its run 60", v)
	}
	if v := cosPetSpeed(79.9, 60, 16, false); !near851(v, 16) {
		t.Fatalf("near, owner walking: %v, want 16", v)
	}
}

// Round 851: the leg choice (s:0x549dec.., s:0x54a2b3..).
func TestRound851Steer(t *testing.T) {
	deg := func(a float64) (float64, float64) { return math.Sin(a * math.Pi / 180), math.Cos(a * math.Pi / 180) }
	fx, fz := deg(0)
	// 10 degrees off: straight at the point.
	dx, dz := deg(10)
	if keep, along := cosSteer(fx, fz, dx, dz, 50, false, false, 0); keep || along {
		t.Fatal("10 degrees: the point's way")
	}
	// 2 degrees off, standing: along the heading.
	dx, dz = deg(2)
	if keep, along := cosSteer(fx, fz, dx, dz, 50, false, false, 0); keep || !along {
		t.Fatal("2 degrees standing: along the heading")
	}
	// Walking with 40 left: kept.
	if keep, _ := cosSteer(fx, fz, dx, dz, 50, false, true, 40); !keep {
		t.Fatal("2 degrees walking, 40 left: kept")
	}
	// 4 degrees over 2000: misses by 139 -> the point's way.
	dx, dz = deg(4)
	if keep, along := cosSteer(fx, fz, dx, dz, 2000, false, false, 0); keep || along {
		t.Fatal("a miss over 100: the point's way")
	}
	// A pet 30 or nearer goes straight at its point.
	dx, dz = deg(2)
	if keep, along := cosSteer(fx, fz, dx, dz, 30, true, true, 100); keep || along {
		t.Fatal("a pet's short leg: the point's way")
	}
}

// Round 851: FUN_00430ce0's 3 x 3 regions.
func TestRound851RegionsAdjacent(t *testing.T) {
	z := worldmap.WorldBucket
	a := world.Position{X: 0, Z: 0}
	if !cosRegionsAdjacent(z, a, z, world.Position{X: 1900, Z: 0}) {
		t.Error("the next region: adjacent")
	}
	if cosRegionsAdjacent(z, a, z, world.Position{X: 4000, Z: 0}) {
		t.Error("two regions on: not adjacent")
	}
	if cosRegionsAdjacent(z, a, "jangan", a) {
		t.Error("another frame: not adjacent")
	}
}

// partWallRegion is wallRegion with the wall blocking only local z 900..1020
// (world z -60..60 in Jangan's frame): open above and below it.
func partWallRegion(wallX float32) *navmesh.Region {
	r := wallRegion(wallX)
	r.InternalEdges = []navmesh.Edge{
		{AX: wallX, AZ: 0, BX: wallX, BZ: 900, Flags: 0, CellFrom: 0, CellTo: 1, RegionFrom: -1, RegionTo: -1},
		{AX: wallX, AZ: 900, BX: wallX, BZ: 1020, Flags: 3, CellFrom: 0, CellTo: 1, RegionFrom: -1, RegionTo: -1},
		{AX: wallX, AZ: 1020, BX: wallX, BZ: navmesh.RegionSpan, Flags: 0, CellFrom: 0, CellTo: 1, RegionFrom: -1, RegionTo: -1},
	}
	return r
}

// Round 851: a transport is sent straight and stopped at the wall; it stays
// stuck while its owner stands beyond the wall, and is freed once its owner
// moves so the straight way is clear -- no path-finding, no leash, no warp.
func TestRound851TransportStuckAtAWall(t *testing.T) {
	// Jangan's frame: world (0, 0) is region 97/168's local (960, 960); the
	// wall at local x 990 is world x 30.
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): partWallRegion(990)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	o := &cosObj{uid: 1, kind: cos.KindTransport, zone: "jangan", row: species.Row{BCRadius: 5, RunSpeed: 60, WalkSpeed: 20}}
	pos := world.Position{X: 80, Z: 0}
	o.pos, o.heading = pos, 3*math.Pi/2
	own := cosFollowOwner{pos: world.Position{X: -60, Z: 0}, heading: 3 * math.Pi / 2, zone: "jangan", alive: true}
	now := time.Unix(0, 0)
	pass := func() (world.Position, bool, bool) {
		st := cosFollowDecide(o, pos, own, func(*cosObj) [8]bool { return [8]bool{} }, nil)
		if !st.leg {
			return pos, false, false
		}
		end, sent := startCOSLeg(o, pos, st.dir, st.length, now)
		_, wall := cosLeg(o, pos, world.Position{X: pos.X + st.dir[0]*st.length, Z: pos.Z + st.dir[1]*st.length})
		return end, sent, wall
	}
	end, sent, wall := pass()
	if !o.following || !sent || !wall || !near851(end.X, 30.2) {
		t.Fatalf("the first leg: following %v sent %v wall %v end %+v, want stopped at the wall x 30.2", o.following, sent, wall, end)
	}
	pos, o.pos, o.moving = end, end, false
	// Stuck: 50 more passes leave it at the wall.
	for i := 0; i < 50; i++ {
		e, s, _ := pass()
		if s && math.Hypot(e.X-pos.X, e.Z-pos.Z) > 1 {
			t.Fatalf("pass %d left the wall: %+v", i, e)
		}
		o.moving = false
	}
	// The owner comes round to the transport's side, above the wall's end.
	own.pos = world.Position{X: 80, Z: 250}
	end, sent, wall = pass()
	if !sent || wall || math.Hypot(end.X-pos.X, end.Z-pos.Z) < 100 {
		t.Fatalf("freed: sent %v wall %v end %+v from %+v", sent, wall, end, pos)
	}
}

// Round 851: a pet left two regions behind is warped onto its owner
// (s:0x549fc6 -> 0x541110); one region behind it is not, and a ride never.
func TestRound851Warp(t *testing.T) {
	z := worldmap.WorldBucket
	pet := &cosObj{uid: 2, kind: cos.KindGrowth, zone: z, row: species.Row{BCRadius: 5, RunSpeed: 50}, following: true}
	own := cosFollowOwner{pos: world.Position{X: 4000, Z: 0}, zone: z, alive: true, run: 50, current: 50, running: true}
	none := func(*cosObj) [8]bool { return [8]bool{} }
	st := cosFollowDecide(pet, world.Position{}, own, none, nil)
	if !st.warp || st.warpTo != own.pos || pet.following {
		t.Fatalf("two regions: %+v following %v", st, pet.following)
	}
	pet.following = true
	own.pos = world.Position{X: 1900, Z: 0}
	if st = cosFollowDecide(pet, world.Position{}, own, none, nil); st.warp || !st.leg {
		t.Fatalf("the next region: %+v", st)
	}
	if !near851(st.speed, 62.5) {
		t.Fatalf("far behind a running owner: speed %v, want 62.5", st.speed)
	}
	ride := &cosObj{uid: 3, kind: cos.KindRide, zone: z, row: species.Row{BCRadius: 5, RunSpeed: 50}}
	own.pos = world.Position{X: 40000, Z: 0}
	if st = cosFollowDecide(ride, world.Position{}, own, none, nil); st.warp || !st.leg {
		t.Fatalf("a ride far behind: %+v", st)
	}
	// A dead owner: nothing.
	own.alive = false
	if st = cosFollowDecide(ride, world.Position{}, own, none, nil); st.leg || st.warp {
		t.Fatalf("a dead owner: %+v", st)
	}
}
