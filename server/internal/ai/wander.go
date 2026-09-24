package ai

import (
	"math"
	"math/rand"
)

// The pure rules a monster's motion tick runs (round 536): which way it faces
// when it hatches, whether an idle spell ends in another idle or a WANDER leg,
// where that leg goes, which clip a move plays, when it has strayed and where
// HOMING walks it, and when it has arrived. Every rule below was read out of
// SR_GameServer.exe; the addresses are cited at each. The monster AI tick
// (session/monsterai.go, round 537, behind cmd/server's default-off
// -monster-ai) runs them.
//
// Headings are angles in radians measured from +x toward +z: the unit heading
// SetHeading (IGObj slot 230, 0x00482440 / the CGObjMobile override
// 0x0048ba10) writes to the owner's +0x24/+0x2c is (cos a, 0, sin a).

// CRandMax is the C runtime's RAND_MAX: rand() (0x009dd338, _rand in the
// dump) returns 0..0x7fff, which is why Nest_Hatch divides it by 32767.0
// (0xb45af8) to get a fraction.
const CRandMax = 0x7fff

// crand is one call of the engine's rand().
func crand(rng *rand.Rand) int { return rng.Intn(CRandMax + 1) }

// crandSign is the engine's random-sign idiom, `(rand() & 0x80000001)`, then
// neg/sbb/and 2/add -1 (PickWanderLeg 0x5458d4..0x5458e8 and
// 0x545939..0x54594c): an odd draw gives +1 and an even one -1.
func crandSign(rng *rand.Rand) int {
	if crand(rng)&1 == 1 {
		return 1
	}
	return -1
}

// SpawnHeading is the heading a hatched monster faces: Nest_Hatch (0x005607b0,
// 0x5609ee..0x560a15) takes rand() / 32767.0 (0xb45af8) * 2pi (0xb45c18)
// + 0.0 (0xb45ab0), so [0, 2pi], for a monster whose species' rarity
// (refChar+0x89) is not 3. A rarity-3 species faces its nest row's own
// direction (+0x1c; docs/protocol/monster_ai.md, "The _RefNest row", row 8),
// which srrevamp does not hold: no roster species is rarity 3. The engine
// rounds each step to a float; this keeps float64.
func SpawnHeading(rng *rand.Rand) float64 {
	return float64(crand(rng)) / 32767.0 * (2 * math.Pi)
}

// IdleStayThreshold is the IDLE roll's threshold: CAIState_IDLE's slot 41
// (0x00559cf0, the MsgInterrupted 0x25 handler IDLE overrides) loads
// ebx = 0x19 at 0x559d01, draws r = |rand()| % 100 + 1 (0x559da3..0x559dba)
// and stays IDLE (ChangeState(1)) when r < ebx, else goes to WANDER
// (ChangeState(2)) -- WANDER for 76 of the 100 values.
//
// Four owner conditions raise the threshold to 0x65 (101), which means always
// IDLE: IsMercenary (slot 15) answering 1 (0x559d06); the owner's TypeID
// word (FUN_00485c90) with bit 1 set and its fields reading 1, 2, 3, 8
// ((w & 0x1c) == 4, (w & 0x60) == 0x40, (w & 0x780) == 0x180,
// (w & 0xf800) == 0x4000; 0x559d22..0x559d54); IsAttackableCOS (slot 16)
// with the owner's +0x1cd8 record's +0x1d18 set (0x559d66..0x559d83); and
// slot 243 (+0x3cc) answering non-zero (0x559d98) -- with slot 242, one of
// the two TID-shape tests for (1,2,4,1)/(1,2,4,4) (docs/protocol/
// monster_ai.md, "The roam radius"). None is modelled. Every roster species
// is TypeID (1,2,1,1) (characterdata cols 9..12, read on the RE box
// 2026-09-24): its third field is 1 ((w & 0x780) == 0x80, the shape
// Nest_Hatch gives a random heading under), so it is neither the 1,2,3,8
// word nor a (1,2,4,x) shape, and nothing makes it a mercenary or a COS.
// Its threshold is 25.
const IdleStayThreshold = 25

// IdleNext is the IDLE roll: StateIdle (another idle spell) or StateWander.
// rand() is never negative, so the engine's |x| (cdq/xor/sub) changes nothing.
func IdleNext(rng *rand.Rand) State {
	if crand(rng)%100+1 < IdleStayThreshold {
		return StateIdle
	}
	return StateWander
}

// PickWanderLeg is CAIState_WANDER::PickWanderLeg (0x00545860) for a monster
// at (x, z) facing heading (radians) with run speed runSpeed (its +0x170). It
// refuses (ok false) unless runSpeed > 1e-6 (fcomp 0xb45c84 at 0x545877; the
// location record the engine also requires is always present here).
// Otherwise it draws, in the engine's order:
//
//	s1   = random sign                             ; 0x5458cd
//	dist = 85.0 + s1 * (rand() % 40)               ; 0x5458eb..0x54590f, 0xb46160 -> 46..124
//	m    = |rand()| % 91 + 45                      ; 0x54591f..0x545931
//	s2   = random sign                             ; 0x545934
//	t    = s2 * m * pi/180                         ; 0xb45e00
//
// and walks the leg WanderLegDirection(cos heading, sin heading, t) -- the
// heading bisected with heading + t (round 535), a turn of 22.5..67.5 degrees
// either side -- for dist: the destination is position + direction * dist
// (FUN_00540f70). The returned heading is the leg's own direction, which the
// move's start writes to the owner (CGObjMoverByDest 0x48c330 -> its slot 10,
// 0x48c660: SetHeading to atan2 toward the destination).
//
// Not modelled, and disclosed: the ctx+0x14c term, which adds a unit vector
// toward that object when it resolves (0x5459f0..0x545a50; what +0x14c holds
// is unread, and for a nest monster it is unverified that it is empty); and
// the blocked-probe reversal, which probes position + direction * 30
// (0xb45e58) through the world singleton's slot 12 and reverses the
// direction (* -1.0, 0xb45e68) when bit 0 or bit 28 reports it blocked --
// srrevamp's server holds no collision world to ask.
func PickWanderLeg(rng *rand.Rand, x, z, heading, runSpeed float64) (destX, destZ, legHeading float64, ok bool) {
	if !(runSpeed > WanderMinRunSpeed) {
		return x, z, heading, false
	}
	s1 := crandSign(rng)
	dist := WanderDistanceBase + float64(s1*(crand(rng)%WanderDistanceSpread))
	m := crand(rng)%WanderTurnSpreadDeg + WanderTurnMinDegrees
	s2 := crandSign(rng)
	t := float64(s2*m) * math.Pi / 180
	dx, dz := WanderLegDirection(math.Cos(heading), math.Sin(heading), t)
	return x + dx*dist, z + dz*dist, math.Atan2(dz, dx), true
}

// MotionMode is the clip byte AITactics_Handler_110 (0x005489b0..0x00548a20)
// picks for a move, 0 or 1 (docs/protocol/monster_ai.md, "srrevamp's own
// monster protocol": 0 walk clip, 1 run clip):
//
//   - run speed (+0x170) <= 1e-6 (the float at 0xb45c84, fcom at 0x5489bc) -> 0;
//   - else walk speed (+0x16c) <= 1e-6 (fcomp at 0x5489d8) -> 1;
//   - else the current state: WANDER (2) -> 0; FLEE (4) -> 0; anything else -> 1.
//
// FLEE's HP-bucket branch (AITactics_HPBucket 0x541d70 < 3) returns without
// writing the byte, but the one caller, FUN_00541820, zeroes it before the
// call (`mov byte [esp+0xa],0` at 0x541833), so FLEE gives 0 either way.
func MotionMode(state State, walk, run float64) uint8 {
	if !(run > WanderMinRunSpeed) {
		return 0
	}
	if !(walk > WanderMinRunSpeed) {
		return 1
	}
	if state == StateWander || state == StateFlee {
		return 0
	}
	return 1
}

// RoamRule1Factor scales the roam radius under rule 1: the double 1.5 at
// 0xb45d78 (fmul at 0x54604e).
const RoamRule1Factor = 1.5

// WithinRoamRadius is AITactics_IsWithinRoamRadius (0x00545f70) for a monster
// at (x, z) whose home is (homeX, homeZ) and roam radius r, under the tactics
// row's roam-radius rule (row +0x80, a byte): rule 0 uses r, rule 1 uses
// r x 1.5, and any other rule is always within, so such a monster never goes
// home (0x546039..0x546048). The distance is FUN_00430ad0's ground-plane
// difference (y = 0), and the test is STRICT: within only while
// dist < radius (fcomp at 0x5460ae, `test ah,0x5; jnp`), so a monster exactly
// on the radius has strayed.
//
// Which home and radius apply is the caller's: the nest's position and radius
// with a nest, else the context's spawn record (ctx+0x1b4) and ctx+0x1cc; and
// the engine answers "within" outright when there is no nest and the row's
// +0x84 is below 1 (0x545fdb..0x545fe7).
func WithinRoamRadius(homeX, homeZ, x, z, r float64, rule uint8) bool {
	switch rule {
	case 0:
	case 1:
		r *= RoamRule1Factor
	default:
		return true
	}
	return math.Hypot(x-homeX, z-homeZ) < r
}

// HomeDestination is where CAIState_HOMING::MoveHome (0x00545c50) sends a
// monster at (x, z) whose home is (homeX, homeZ) and radius r: home moved
// toward the monster, along normalize(monster - home) (FUN_00430ad0 then
// FUN_004328c0), by rand() % (1 + trunc(r/3)) + r/3 -- HomingScatterRange's
// band (corrected in round 535). A monster standing on its home has no
// direction (FUN_004328c0 leaves a zero vector zero), so the destination is
// home. Not modelled: the owner's slot 243 (+0x3cc) answering non-zero, which
// makes the destination exactly home (0x545d74..0x545d78) -- one of the two
// (1,2,4,x) TID-shape tests (see IdleStayThreshold); every roster species is
// (1,2,1,1). A negative r is not a radius the engine holds (a nest radius,
// or 200.0) and is taken as 0, where the draw is rand() % 1.
func HomeDestination(rng *rand.Rand, homeX, homeZ, x, z, r float64) (destX, destZ float64) {
	if r < 0 {
		r = 0
	}
	offset := float64(crand(rng)%(1+int(r/3))) + r/3
	dx, dz := x-homeX, z-homeZ
	l := math.Hypot(dx, dz)
	if l == 0 {
		return homeX, homeZ
	}
	return homeX + dx/l*offset, homeZ + dz/l*offset
}

// HasArrived is AITactics_HasArrived (0x00541f60): the monster at (x, z) is at
// (destX, destZ) while the distance is STRICTLY under 5.0 (fcomp DWORD
// 0xb45b28 at 0x541fb2, `test ah,0x5; jp`), so exactly 5.0 is not there yet.
// The engine's difference (FUN_00430d40) keeps y; srrevamp's monsters carry
// no height of their own (a roster spawn stands at y = 0 and the mover only
// moves x and z), so the ground-plane distance is compared.
func HasArrived(x, z, destX, destZ float64) bool {
	return math.Hypot(destX-x, destZ-z) < HomingArrivalRadius
}

// BattleDwellMs is the timeout BATTLE enters with: none. CAIState_BATTLE::
// OnEnter (0x00559fb0) calls only the base CAIState::OnEnter (0x00558b70),
// which sets the timeout (+0x14) to 0, and never calls AIState_DwellMs; the
// base OnUpdate (0x00558b90) expires a state only when that timeout is
// non-zero. So, unlike the five states that call AIState_DwellMs (IDLE,
// WANDER, FLEE, HOMING, EMOTION), a fight draws no dwell and does not expire
// by one. The only other writers of +0x14 found are the 3000 ms extensions
// BATTLE inherits -- vtable slot 17 (0x00559310) and CAIState::ExtendDwell,
// slot 18 (0x00559450) -- whose callers were not traced (DwellExtension).
const BattleDwellMs = 0

// DwellExpired is the base CAIState::OnUpdate's (0x00558b90) test: a state
// whose timeout (+0x14, ms) is non-zero expires once the time since it was
// entered (g_tickMs - +0x10) is STRICTLY greater than the timeout. A zero
// timeout -- BATTLE's on entry, or any state no dwell was stored for --
// never expires.
func DwellExpired(timeoutMs, elapsedMs int) bool {
	return timeoutMs != 0 && timeoutMs < elapsedMs
}
