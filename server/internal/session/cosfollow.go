package session

import (
	"encoding/binary"
	"math"
	"math/rand"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// How a COS follows its owner (round 851 lane F, READ SR_GameServer.exe;
// docs/protocol/pets.md "Round 851" has the walk-through with every address).
//
// Two FOLLOWs. The summon's spawn (s:0x4fbae0) calls COS slot 401
// (s:0x4d2050 for CGObjCOS, CGObjCOS_Cart, CGObjCOS_Pet, _GoldPet and
// _SilkPet), which posts AI command 0xb {1, owner}; the state's slot 14
// (s:0x5591b0) records the leader (+0x14c) and, for mode 1, calls CTactics
// slot 18 (s:0x5471b0): an IsPet object (TypeID4 3 or 4, s:0x4838c0 ->
// 0x44b460) gets the pet behaviours -- IDLE s:0x5488b0, FOLLOW s:0x549f80,
// the speed handler s:0x548a30 -- and every other COS keeps the table's
// (AI::CTactics::InstallBehaviourTable s:0x53fc00): IDLE s:0x5485b0, FOLLOW
// s:0x549ac0, speed AITactics_Handler_110 s:0x5489b0. So:
//
//   - Rides and transports (cosSideFollow): IDLE turns to FOLLOW at 65.0 or
//     more from the owner, and a COS standing inside its own radius of the
//     owner steps out to a random one of 36 directions; FOLLOW runs at the
//     row's run speed to a point beside the owner (cosSidePoint) until it is
//     nearer than BC + 50.0. No leash, no warp: a ride or transport left
//     behind stays where it stopped (the owner's own leash keeps a transport
//     within 1000, round 801).
//   - Growth and ability pets (cosPetFollow): IDLE turns to FOLLOW past
//     66.0, FOLLOW runs at its owner's speed (cosPetSpeed) to its slot of
//     eight round the owner (cosFormationPoint) until within 60.0; an owner
//     outside the 3 x 3 regions round the pet has it warped onto the owner
//     (s:0x549fc6 -> s:0x541110, the 0x7022 to the owner's position).
//
// Both send a COS's legs straight (AITactics_MoveAlongDirection s:0x540f70:
// position + direction x length, posted as a 0x7021 to the COS itself), and
// the server's mover stops it at the first blocking edge with no slide
// (CGObjMoverByDest, CRegionManagerBody::vslot_012; movement.md, "The stop at
// a wall"). Neither path-finds or retries round a wall: a COS whose straight
// line is blocked stands at the wall, re-sent the same way every pass while
// its heading and the way to its point stay within 5 degrees (cosSteer),
// until its owner moves so that the line changes.
//
// Every leg goes through cosLeg, the one place a COS's leg meets the world.

// FOLLOW and IDLE's numbers (READ).
const (
	// cosIdleLeave: a ride's or transport's IDLE (s:0x5485b0) leaves at a
	// distance of 65.0 or more (the float at s:0xb46298).
	cosIdleLeave = 65.0
	// cosFollowArrive: its FOLLOW (s:0x549ac0) arrives nearer than BC + 50.0
	// (the double at s:0xb46288).
	cosFollowArrive = 50.0
	// petIdleLeave: a pet's IDLE (s:0x5488b0) leaves past 66.0 (the float at
	// s:0xb46158).
	petIdleLeave = 66.0
	// petFollowArrive: a pet's FOLLOW (s:0x549f80) arrives within 60.0 (the
	// double at s:0xb45e80).
	petFollowArrive = 60.0
	// cosSteerAngle, degrees: a way to the point this close to the heading
	// keeps the heading (the float 5.0 at s:0xb45b28).
	cosSteerAngle = 5.0
	// cosSteerMiss: ...unless the heading misses the point by more than this
	// (the double 100.0 at s:0xb45af0).
	cosSteerMiss = 100.0
	// cosKeepLeg: a COS still walking a leg with more than this left keeps
	// it (the double 30.0 at s:0xb45e58); a pet's leg shorter than this
	// always goes straight at its point.
	cosKeepLeg = 30.0
	// petFarSpeed: the speed handler s:0x548a30 matches the owner's run speed
	// at this distance or more (the float 80.0 at s:0xb46148), its current
	// speed nearer.
	petFarSpeed = 80.0
	// petFarRunBoost: the far run speed's factor when the owner runs (the
	// double 1.25 at s:0xb46290).
	petFarRunBoost = 1.25
	// petSlotRadius: a pet's slot is BC x 3.0 (CTactics slot 25 s:0x5400c0,
	// the double at s:0xb45ab8, outside BATTLE) x 0.8 (s:0xb45bf0, in
	// s:0x55e090) from its owner.
	petSlotRadius = 3.0 * 0.8
	// petSlotPull and petSlotTries: a slot point off the navigation mesh is
	// moved 0.7 (s:0xb45ef8) toward the owner, at most 50 times (0x55e2ab).
	petSlotPull  = 0.7
	petSlotTries = 50
	// cosIdleStepOut: a ride's or transport's IDLE steps out to BC + ownerBC
	// + rand()%5 + 1 when it stands within BC of the owner (s:0x548664).
	cosIdleStepOut = 5
)

// cosTable36 are the server's 36 directions (s:0x54ab10 fills 0xce2030):
// entry i is (cos a, 0, -sin a) in the region's own frame at a = 5 + 10 i
// degrees.
var cosTable36 = func() (t [36][2]float64) {
	for i := range t {
		a := float64(5+10*i) * math.Pi / 180
		t[i] = [2]float64{math.Cos(a), -math.Sin(a)}
	}
	return t
}()

// cosTable8 are a pet's eight slot directions (s:0x54a990 fills the AI
// manager's +0x3c table from +0x6c, read as its entries 9..16 by
// s:0x55e090): (cos a, 0, -sin a) at a = 22 + 45 i degrees.
var cosTable8 = func() (t [8][2]float64) {
	for i := range t {
		a := float64(22+45*i) * math.Pi / 180
		t[i] = [2]float64{math.Cos(a), -math.Sin(a)}
	}
	return t
}()

// The region frame against OpenSRO's world frame: x the same way, z the
// other (worldmap.ToWorld; round 812, "a world +Z is a local -Z").
func localDir(wx, wz float64) (lx, lz float64) { return wx, -wz }
func worldDir(lx, lz float64) (wx, wz float64) { return lx, -lz }

// headingLocal is a heading's facing vector in the region's frame (world
// facing (sin h, cos h), world.HeadingToward).
func headingLocal(h float64) (fx, fz float64) { return localDir(math.Sin(h), math.Cos(h)) }

// angleDeg is FUN_00545450 x 57.29578 (s:0xb45c38): the angle between two
// vectors in degrees, NaN when either is zero.
func angleDeg(ax, az, bx, bz float64) float64 {
	n := math.Hypot(ax, az) * math.Hypot(bx, bz)
	if n == 0 {
		return math.NaN()
	}
	c := (ax*bx + az*bz) / n
	return math.Acos(math.Max(-1, math.Min(1, c))) * 180 / math.Pi
}

// ftolIndex is the picker's truncation (_ftol, s:0x9fbb40) clamped to
// [0, top] as FUN_0053dad0 / FUN_0055e3b0 clamp it (a NaN: 0).
func ftolIndex(v float64, top int) int {
	if math.IsNaN(v) || v < 0 {
		return 0
	}
	i := int(v)
	if i > top {
		return top
	}
	return i
}

// cosSidePoint is a ride's or transport's FOLLOW point (s:0x549bc9..
// 0x549d64): the owner's side vector -- its facing crossed with up, (-fz, 0,
// fx) in the region's frame -- times a sign (-1 when (d.x f.z - d.z f.x) of
// the COS->owner vector d and the COS's own facing f is under 0.0 (the FLOAT
// at s:0xade894, fcomp DWORD at 0x549c2a; round 796 read the double 0.0078125
// there), then snapped by FUN_0053dad0: the angle between the NEGATED
// side vector and (1, 0, 0), in degrees over 10 (s:0xb45c60), truncated, picks
// the 36-table entry, at selfBC + ownerBC + rand()%10+1 (r) from the owner.
// The snap reads only the angle's size, so the direction always lies on the
// region frame's -z half (a = 5..185) with x the negated side's: the point is
// not always on the side the side vector names (READ, as built).
func cosSidePoint(owner world.Position, ownerHeading float64, cosPos world.Position, cosHeading float64, r float64) world.Position {
	dir := cosSideDir(owner, ownerHeading, cosPos, cosHeading)
	wx, wz := worldDir(dir[0], dir[1])
	return world.Position{X: owner.X + r*wx, Y: owner.Y, Z: owner.Z + r*wz}
}

// cosSideDir is cosSidePoint's table direction (region frame).
func cosSideDir(owner world.Position, ownerHeading float64, cosPos world.Position, cosHeading float64) [2]float64 {
	dx, dz := localDir(owner.X-cosPos.X, owner.Z-cosPos.Z)
	sfx, sfz := headingLocal(cosHeading)
	sign := 1.0
	if dx*sfz-dz*sfx < 0 {
		sign = -1
	}
	fx, fz := headingLocal(ownerHeading)
	sx, sz := -sign*fz, sign*fx
	i := ftolIndex(angleDeg(-sx, -sz, 1, 0)/10, 35)
	return cosTable36[i]
}

// cosStepOutPoint is IDLE's step out (s:0x548664..0x5486f6): a COS standing
// within its own radius of the owner goes to a random 36-table direction at
// selfBC + ownerBC + rand()%5+1 from the owner.
func cosStepOutPoint(owner world.Position, selfBC float64) world.Position {
	i := rand.Intn(36)
	r := selfBC + ownerBCRadius + float64(rand.Intn(cosIdleStepOut)+1)
	wx, wz := worldDir(cosTable36[i][0], cosTable36[i][1])
	return world.Position{X: owner.X + r*wx, Y: owner.Y, Z: owner.Z + r*wz}
}

// cosPreferredSlot is FUN_0055e3b0 on the owner->pet offset as FUN_00555340
// hands it (the order of the subtraction INFERRED): the angle between the
// negated offset and (1, 0, 0) over 180.0 (s:0xb45e60), truncated -- 0 for
// every offset but one lying exactly along the axis, READ as built.
func cosPreferredSlot(owner, pet world.Position) int {
	dx, dz := localDir(owner.X-pet.X, owner.Z-pet.Z)
	return ftolIndex(angleDeg(-dx, -dz, 1, 0)/180, 7)
}

// cosPickSlot is FUN_00555340 / FUN_005554d0: the preferred slot when free,
// else p+1, p-1, p+2, p-2, ... (mod 8); -1 when all eight are taken.
func cosPickSlot(p int, taken [8]bool) int {
	if !taken[p] {
		return p
	}
	for k := 1; k < 8; k++ {
		if s := (p + k) & 7; !taken[s] {
			return s
		}
		if s := (p - k + 8) & 7; !taken[s] {
			return s
		}
	}
	return -1
}

// cosFormationPoint is FUN_0055e090: the owner's position plus slot's
// direction x BC x 2.4, moved 0.7 at a time toward the owner (at most 50
// times) while it is off the navigation mesh (CRegionManagerBody slot 11
// s:0x98b1d0 finds no cell) or farther than that radius. onMesh nil: every
// point is on it. OURS: the closing snap to whole units (0x55e2c0..) is not
// modelled.
func cosFormationPoint(owner world.Position, slot int, selfBC float64, onMesh func(world.Position) bool) world.Position {
	r := selfBC * petSlotRadius
	wx, wz := worldDir(cosTable8[slot][0], cosTable8[slot][1])
	p := world.Position{X: owner.X + r*wx, Y: owner.Y, Z: owner.Z + r*wz}
	for i := 0; i < petSlotTries; i++ {
		d := math.Hypot(owner.X-p.X, owner.Z-p.Z)
		if d <= r && (onMesh == nil || onMesh(p)) {
			break
		}
		if d > 0 {
			p.X += petSlotPull * (owner.X - p.X) / d
			p.Z += petSlotPull * (owner.Z - p.Z) / d
		}
	}
	return p
}

// cosPetSpeed is the speed handler s:0x548a30 outside BATTLE: the pet's run
// speed becomes, at dist or more than 80.0 from its owner, the owner's run
// speed (x 1.25 while the owner runs), nearer the owner's current speed. It
// is set as the run's percentage of the row's run speed (refobjchar +0xe6,
// ParamKeeper param 24), so the run speed it walks is exactly this.
func cosPetSpeed(dist, ownerRun, ownerCurrent float64, ownerRunning bool) float64 {
	if dist >= petFarSpeed {
		if ownerRunning {
			return ownerRun * petFarRunBoost
		}
		return ownerRun
	}
	return ownerCurrent
}

// cosSteer is the leg both FOLLOWs choose once they have a point L away in
// direction dir (s:0x549dec.. for a ride or transport, s:0x54a2b3.. for a
// pet), with the COS facing f:
//   - a pet goes straight at its point when L is 30.0 or less;
//   - both go straight at it when it lies 5 degrees or more off the
//     heading, or the heading would miss it by more than 100.0 (|f L - dir L|);
//   - else a COS walking a leg with more than 30.0 left keeps it (keep);
//   - else it walks L along its own heading (alongHeading).
func cosSteer(fx, fz, dirX, dirZ, L float64, pet, moving bool, legLeft float64) (keep, alongHeading bool) {
	if pet && !(L > cosKeepLeg) {
		return false, false
	}
	a := angleDeg(fx, fz, dirX, dirZ)
	if !(a < cosSteerAngle) {
		return false, false
	}
	if math.Hypot(fx*L-dirX*L, fz*L-dirZ*L) > cosSteerMiss {
		return false, false
	}
	if moving && legLeft > cosKeepLeg {
		return true, false
	}
	return false, true
}

// cosRegionsAdjacent is FUN_00430ce0: two places in the same frame whose
// regions are at most one apart on each axis (a dungeon: always).
func cosRegionsAdjacent(zoneA string, a world.Position, zoneB string, b world.Position) bool {
	if zoneA != zoneB {
		return false
	}
	ra, _, _ := regionLocalOf(zoneA, a)
	rb, _, _ := regionLocalOf(zoneB, b)
	if ra&0x8000 != 0 || rb&0x8000 != 0 {
		return ra&0x8000 != 0 && rb&0x8000 != 0
	}
	ax, ay := int(ra&0xff), int(ra>>8)
	bx, by := int(rb&0xff), int(rb>>8)
	return iabs(ax-bx) < 2 && iabs(ay-by) < 2
}

func iabs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// cosLeg is the one place a COS's leg meets the world: the end of a straight
// leg from `from` toward `to` -- where the navigation mesh's no-slide walk
// stops it at a wall (the server's mover, READ), or `to`. wall reports a
// stop short of `to`. Without a navigation mesh the leg is straight.
//
// Round 851: lane C's per-kind collision belongs here and nowhere else.
func cosLeg(o *cosObj, from, to world.Position) (end world.Position, wall bool) {
	r, ok := navWalk(o.zone, from.X, from.Y, from.Z, to.X, to.Z)
	if !ok || !r.Blocked {
		if ok && r.Checked && !math.IsNaN(r.Y) {
			to.Y = r.Y
		}
		return to, false
	}
	y := r.Y
	if math.IsNaN(y) {
		y = to.Y
	}
	return world.Position{X: r.X, Y: y, Z: r.Z}, true
}

// cosOnMesh is cosFormationPoint's probe on the server's navigation mesh: a
// surface under p in its frame (no mesh: every point).
func cosOnMesh(zone string) func(world.Position) bool {
	w := navWorld.Load()
	if w == nil {
		return nil
	}
	if _, dungeon := dungeonOf(zone); dungeon {
		return nil
	}
	ox, oy, ok := entityFrame(zone)
	if !ok {
		return nil
	}
	return func(p world.Position) bool { return !math.IsNaN(w.Height(ox, oy, p.X, p.Z, p.Y)) }
}

// cosRunSpeed is o's run speed now: a pet's matched one (cosPetSpeed) once
// set, else its row's.
func (o *cosObj) runSpeedNow() float64 {
	if o.runSpeed > 0 {
		return o.runSpeed
	}
	return o.row.RunSpeed
}

// ownerSpeeds are a character's run speed, current speed and run flag
// (CGObjChar +0x170, +0x174, +0x155; a rider's are its mount's, s:0x4aa410).
func ownerSpeeds(characterID int64) (run, current float64, running bool) {
	running = !motions.walkingMode(characterID)
	if w, r, riding := riderSpeeds(characterID); riding {
		if running {
			return r, r, true
		}
		return r, w, false
	}
	run = float64(buffBooks.RunSpeed(characterID))
	if running {
		return run, run, true
	}
	return run, PlayerWalkSpeed, false
}

// sendCOSSpeed is a COS's 0x30D0 {u32 uid, f32 walk, f32 run} (the speed
// handler's recompute, slot 0x4e8, broadcasts it: s:0x4aa4ce).
func sendCOSSpeed(o *cosObj, walk, run float64) {
	out := binary.LittleEndian.AppendUint32(nil, o.uid)
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(walk)))
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(run)))
	sendAboutCOS(o, OpSpeedChange, out)
}

// cosFollowOwner is what the owner looks like to a following COS.
type cosFollowOwner struct {
	pos          world.Position
	heading      float64
	zone         string
	alive        bool
	moving       bool // a destination leg (+0x154 == 1)
	dest         world.Position
	run, current float64
	running      bool
}

// cosFollowStep is one pass of o's IDLE / FOLLOW (the caller holds
// cosWorld.mu). It returns the leg to start (ok), a warp onto the owner, or
// a speed to tell.
type cosFollowStep struct {
	leg      bool
	dir      [2]float64 // world frame, unit
	length   float64
	keep     bool
	warp     bool
	warpTo   world.Position
	speed    float64 // > 0: the pet's new run speed
	stepOut  bool
	slotFree bool
}

// cosFollowDecide is IDLE and FOLLOW for one COS (pure but for rand and the
// mesh probe): o's state flips between them as the original's does.
func cosFollowDecide(o *cosObj, pos world.Position, own cosFollowOwner, taken func(*cosObj) [8]bool, onMesh func(world.Position) bool) cosFollowStep {
	var st cosFollowStep
	bc := float64(o.row.BCRadius)
	if !own.alive {
		// Both handlers run only while the leader's life state
		// (CGObj::GetLifeState s:0x485ee0) is 1.
		return st
	}
	pet := cos.IsPetKind(o.kind)
	d2 := math.Hypot(own.pos.X-pos.X, own.pos.Z-pos.Z)
	d3 := math.Sqrt(d2*d2 + (own.pos.Y-pos.Y)*(own.pos.Y-pos.Y))
	if pet {
		if !o.following {
			if d3 > petIdleLeave {
				o.following = true
			} else {
				return st
			}
		}
		// FOLLOW s:0x549f80.
		if !cosRegionsAdjacent(o.zone, pos, own.zone, own.pos) {
			o.following, o.hasSlot = false, false
			st.warp, st.warpTo, st.slotFree = true, own.pos, true
			return st
		}
		if d2 <= petFollowArrive {
			o.following, o.hasSlot = false, false
			st.slotFree = true
			return st
		}
		if v := cosPetSpeed(d2, own.run, own.current, own.running); v > 0 && math.Abs(v-o.runSpeedNow()) >= 1e-6 {
			st.speed = v
		}
		// The slot is given back and taken again every pass (s:0x555460).
		slot := cosPickSlot(cosPreferredSlot(own.pos, pos), taken(o))
		if slot < 0 {
			slot = 0
		}
		o.slot, o.hasSlot = slot, true
		p := cosFormationPoint(own.pos, slot, bc, onMesh)
		if !cosRegionsAdjacent(o.zone, pos, own.zone, p) {
			o.following, o.hasSlot = false, false
			st.slotFree = true
			return st
		}
		L := math.Hypot(p.X-pos.X, p.Z-pos.Z)
		if own.moving {
			if lead := math.Hypot(own.pos.X-own.dest.X, own.pos.Z-own.dest.Z); lead < L {
				L += lead
			}
		}
		leg := cosSteerStep(o, pos, p, L, true)
		leg.speed = st.speed
		return leg
	}
	// A ride's or transport's IDLE s:0x5485b0.
	if !o.following {
		if d3 >= cosIdleLeave {
			o.following = true
		} else {
			if d3 <= bc && !o.moving {
				p := cosStepOutPoint(own.pos, bc)
				L := math.Hypot(p.X-pos.X, p.Z-pos.Z)
				if L > 0 {
					st.leg, st.stepOut, st.length = true, true, L
					st.dir = [2]float64{(p.X - pos.X) / L, (p.Z - pos.Z) / L}
				}
			}
			return st
		}
	}
	// FOLLOW s:0x549ac0.
	if d2 < bc+cosFollowArrive {
		o.following = false
		return st
	}
	r := bc + ownerBCRadius + float64(rand.Intn(10)+1)
	p := cosSidePoint(own.pos, own.heading, pos, o.heading, r)
	L := math.Hypot(p.X-pos.X, p.Z-pos.Z)
	return cosSteerStep(o, pos, p, L, false)
}

// cosSteerStep turns cosSteer's choice into the leg (MoveAlongDirection's
// guard s:0x541730: none when the length is 0.01 or less, s:0xb45df8).
func cosSteerStep(o *cosObj, pos, p world.Position, L float64, pet bool) cosFollowStep {
	var st cosFollowStep
	if L <= 0.01 {
		return st
	}
	dx, dz := p.X-pos.X, p.Z-pos.Z
	n := math.Hypot(dx, dz)
	if n <= 0 {
		return st
	}
	dx, dz = dx/n, dz/n
	fx, fz := math.Sin(o.heading), math.Cos(o.heading)
	left := 0.0
	if o.moving {
		left = math.Hypot(o.to.X-pos.X, o.to.Z-pos.Z)
	}
	keep, along := cosSteer(fx, fz, dx, dz, L, pet, o.moving, left)
	if keep {
		st.keep = true
		return st
	}
	if along {
		dx, dz = fx, fz
	}
	st.leg, st.dir, st.length = true, [2]float64{dx, dz}, L
	return st
}

// startCOSLeg starts o on a leg from pos along dir for length (the caller
// holds cosWorld.mu), through cosLeg. It answers the leg's end and whether
// it is worth sending (a wall closer than navMinLeg leaves o standing,
// turned: OURS, the original posts the move and its mover refuses the
// step).
func startCOSLeg(o *cosObj, pos world.Position, dir [2]float64, length float64, now time.Time) (world.Position, bool) {
	to := world.Position{X: pos.X + dir[0]*length, Y: pos.Y, Z: pos.Z + dir[1]*length}
	end, wall := cosLeg(o, pos, to)
	o.heading = world.HeadingToward(o.heading, dir[0], dir[1])
	if cosTrace {
		cosWorld.depsNow().logger.Info("cos: leg", "cos", o.uid, "kind", o.kind, "from_x", pos.X, "from_z", pos.Z,
			"to_x", to.X, "to_z", to.Z, "end_x", end.X, "end_z", end.Z, "wall", wall, "speed", o.runSpeedNow(), "following", o.following)
	}
	if math.Hypot(end.X-pos.X, end.Z-pos.Z) < navMinLeg {
		o.pos, o.moving = pos, false
		return end, false
	}
	o.from, o.to, o.legStart, o.legSpeed, o.moving, o.pos = pos, end, now, o.runSpeedNow(), true, pos
	return end, true
}
