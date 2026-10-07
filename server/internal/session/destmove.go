package session

import (
	"encoding/binary"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// Moving by destination, as retail does (round 749; docs/protocol/
// crowd_scale.md C3, docs/rounds/r737.md "C3 as a spec", docs/protocol/
// opcodes/movement.md "0xB021 in full").
//
// READ, both binaries (round 737, re-read in round 749):
//
//   - The client sends one 0x7021 per accepted click: `01 | region u16 |
//     x i16 | y i16 | z i16`, the raw region-local coordinates truncated
//     (FUN_009ec570 -> 0x9ec240 -> 0x9ec080), or the heading form `00 |
//     command u8 | angle u16` for a click on the sky (FUN_009ebec0).
//   - GObjPC::FUN_004b0ea0 is the handler. It refuses silently: a dead
//     character, a running trade (interaction state other than 0 or 1), the
//     motion states 8, 0x10 and CHANGEMOTION (0x12), the abnormal-state bits
//     0xc1 / 0x4000, a kind other than 0 or 1, a destination outside the 3 x
//     3 regions around the mover (FUN_0048c2d0), and, while moving, a
//     destination within 5.0 (0xb45b28) of the one set.
//   - An accepted move sends 0xB021 to every PC in the mover's 3 x 3 blocks,
//     the mover included (0x484d90 -> CMsgBlockObject::FUN_00534150): `u32
//     uid | the movement | u8 flag | (flag 1) source region u16, x * 10 u16,
//     y f32, z * 10 u16`, and sets the motion state to WALK or RUN.
//   - The server steps the mover itself and sends nothing per step and
//     nothing on arrival. A stop that is sent -- GObjPC::FUN_004a9430 with its
//     send argument, the CGObjChar slot-300 stop -- broadcasts 0xB023 to the
//     3 x 3 (FUN_00430a00(0xb023), the uid, then FUN_00487c80: `u16 region,
//     f32 x, f32 y, f32 z, u16 angle`), and the client's 0xB023 reader
//     NetProcessInNavAndSkill::FUN_008a4f80 reads exactly that (4, 2, then
//     0xe bytes) and snaps the object there (FUN_009e00f0, FUN_009e11e0).
//     Both registered in the client's dispatch table (0xb021 ->
//     FUN_008a5750, 0xb023 -> FUN_008a4f80).
//
// OURS, disclosed (the server has no navigation mesh for players, round 744):
//
//   - The server does not step the mover: world.Mover keeps the leg and
//     computes the position, and moverPass refiles the movers whose position
//     crossed a block line (moverPassPeriod).
//   - A wall, an approach that arrived in reach, a sit or a stop short of the
//     destination is the client's to report: OpMove with the stop flag
//     (moveFlagStopped). A placement is OpMove with the relocated flag. Each
//     is a CLAIM (world.Hub.Claim, round 749's review F1): measured from the
//     server's own anchor -- the leg's travelled segment, or the last point
//     the server fixed -- with a free slack (claimSlack) and, beyond it, a
//     clocked allowance of at most a second of run banked while standing.
//     That is the speed bound: no chain of claims moves a character faster
//     than its run speed, beyond one slack and one banked second. A
//     placement may also land on a point the server named (an arrival, a GM
//     /tp or /goto), once, within landingGrace. A claim the server takes is
//     relayed to the window as retail's 0xB023; one it does not take puts
//     the character back on its anchor, and the window -- the mover
//     included -- hears that 0xB023. -trust-client-positions (QA) takes all.
//   - The accepted 0xB021 goes to the mover too, as retail's does; OpenSRO's
//     client walks its own click at once and takes its own echo as a receipt.
//     A stop the mover reported is relayed to the others only: its own
//     client is already there.

// OpMovementStop is retail's 0xB023 (READ above): u32 uid, u16 region, f32
// x, y, z region-local, u16 wire angle.
const OpMovementStop uint16 = 0xB023

// moveFlagStopped is the OpMove flags byte's bit 2 (OURS, round 749): the
// position is where the client's walk stopped short of what the server was
// told -- a wall, an approach in reach, a sit, a stop. An older server reads
// it as a walked position.
const moveFlagStopped byte = 4

// The claim's bounds (OURS, world.Bound). claimSlack is the free distance
// from the anchor: a click walk ends within its stop distance (2.39) of the
// destination the wire truncated (up to 1.42 away), and a click within 5.0 of
// the point being walked to is walked but not sent (the server would refuse
// it: READ 0xb45b28) -- 5 + 2.39 + 1.42 = 8.8 (round 749's review, F5).
// claimHeight bounds a claim's or a destination's height (F10) from the last
// height the client itself gave, plus the ground distance from where it gave
// it (world.Entity.HeightAllows; round 749's verification, FP1-FP3: never from
// a height the server only guesses -- an arrival's 0, a leg's straight line, a
// run's start -- which pinned honest players at Hotan in a correction loop).
// claimSanity is the absolute range every height must lie in: raw .m heights
// reach 4,056 (GATE_RC_MOUNTAIN_GATE, MEASURED by the verification), and a
// frame's anchor shifts them by a few hundred at most. Both OURS.
const (
	claimSlack  = 9.0
	claimHeight = 100.0
	claimSanity = 10000.0
)

// moverPassPeriod is how often the movers are refiled (OURS): a block
// crossing is seen within it -- 12.5 units at the base run speed of 50.
const moverPassPeriod = 250 * time.Millisecond

// trustPositions is cmd/server's -trust-client-positions (OURS, OFF by
// default): every position a client reports in OpMove is taken, as before
// round 749. The QA runs place their players anywhere (OPENSRO_QA_AT and its kin).
var trustPositions atomic.Bool

// SetTrustClientPositions is cmd/server's -trust-client-positions.
func SetTrustClientPositions(on bool) { trustPositions.Store(on) }

// regionLocalOf is pos of a character in zone (a hub bucket) as retail
// addresses it: the region and the local x, z there, in the frame the zone's
// client was given (entityFrame, as the spawn record's position). A zone with
// no frame -- none OpenSRO serves -- gives region 0 and the frame
// coordinates, as the record does.
func regionLocalOf(zone string, pos world.Position) (region uint16, lx, lz float64) {
	if fx, fy, ok := entityFrame(zone); ok {
		rx, ry, x, z := worldmap.FromWorld(pos.X, pos.Z, fx, fy)
		return uint16(worldmap.RegionID(rx, ry)), x, z
	}
	return 0, pos.X, pos.Z
}

// worldOfRegionLocal is regionLocalOf's inverse.
func worldOfRegionLocal(zone string, region uint16, lx, lz float64) (x, z float64) {
	if fx, fy, ok := entityFrame(zone); ok {
		rx, ry := worldmap.RegionXY(int(region))
		return worldmap.ToWorld(rx, ry, lx, lz, fx, fy)
	}
	return lx, lz
}

// regionsAdjacent is FUN_0048c2d0: each region byte within one of the other's.
func regionsAdjacent(a, b uint16) bool {
	d := func(x, y int) bool { return x-y <= 1 && y-x <= 1 }
	return d(int(a>>8), int(b>>8)) && d(int(a&0xff), int(b&0xff))
}

// encodeMoveEcho is 0xB021's payload (READ, asm 0x4b0ff8..0x4b1197): the uid,
// the movement as asked, flag 1 and the source -- where the server had the
// character when it took the move. Flag 1 is always safe: the client's reader
// takes it, and retail's own test for it is a defect (round 737, INFERRED).
// The source x and z are u16 ftol(x * 10) (0xb45c60); a dungeon's would be
// i32, which OpenSRO serves none of.
func encodeMoveEcho(uid uint32, movement []byte, srcRegion uint16, src world.Position, lx, lz float64) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uid)
	out = append(out, movement...)
	out = append(out, 1)
	out = binary.LittleEndian.AppendUint16(out, srcRegion)
	out = binary.LittleEndian.AppendUint16(out, uint16(int32(lx*10)))
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(src.Y)))
	out = binary.LittleEndian.AppendUint16(out, uint16(int32(lz*10)))
	return out
}

// encodeMoveStop is 0xB023's payload for e as it stands.
func encodeMoveStop(e world.Entity) []byte {
	region, lx, lz := regionLocalOf(e.Zone, e.Pos)
	out := binary.LittleEndian.AppendUint32(nil, uint32(e.CharacterID))
	out = binary.LittleEndian.AppendUint16(out, region)
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(lx)))
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(e.Pos.Y)))
	out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(lz)))
	return binary.LittleEndian.AppendUint16(out, proto.EncodeMovementAngle(world.WireAngle(e.Heading)))
}

// MoveStop is 0xB023 decoded (tests and tools).
type MoveStop struct {
	UID     uint32
	Region  uint16
	X, Y, Z float32
	Angle   uint16
}

// DecodeMoveStop reads a 0xB023 payload; ok false when it is short.
func DecodeMoveStop(b []byte) (MoveStop, bool) {
	if len(b) < 20 {
		return MoveStop{}, false
	}
	f := func(o int) float32 { return math.Float32frombits(binary.LittleEndian.Uint32(b[o:])) }
	return MoveStop{UID: binary.LittleEndian.Uint32(b), Region: binary.LittleEndian.Uint16(b[4:]),
		X: f(6), Y: f(10), Z: f(14), Angle: binary.LittleEndian.Uint16(b[18:])}, true
}

// MoveEcho is 0xB021 decoded (tests and tools): the movement and the source.
type MoveEcho struct {
	UID       uint32
	Move      *proto.Movement
	Angle     uint16 // the heading form's
	Flag      byte
	SrcRegion uint16
	SrcX      uint16 // local x * 10
	SrcY      float32
	SrcZ      uint16 // local z * 10
}

// DecodeMoveEcho reads a 0xB021 payload of a field region.
func DecodeMoveEcho(b []byte) (MoveEcho, bool) {
	if len(b) < 5 {
		return MoveEcho{}, false
	}
	e := MoveEcho{UID: binary.LittleEndian.Uint32(b)}
	m, a, err := proto.DecodeMovement(b[4:], false)
	if err != nil {
		return MoveEcho{}, false
	}
	e.Move, e.Angle = m, a
	n := 4 + len(m.Encode())
	if len(b) < n+1 {
		return MoveEcho{}, false
	}
	e.Flag = b[n]
	if e.Flag == 1 {
		if len(b) < n+11 {
			return MoveEcho{}, false
		}
		r := b[n+1:]
		e.SrcRegion = binary.LittleEndian.Uint16(r)
		e.SrcX = binary.LittleEndian.Uint16(r[2:])
		e.SrcY = math.Float32frombits(binary.LittleEndian.Uint32(r[4:]))
		e.SrcZ = binary.LittleEndian.Uint16(r[8:])
	}
	return e, true
}

// handleMovementRequest is 0x7021 (READ above; OURS where the comments say).
func handleMovementRequest(sess *gateway.Session, p *proto.Packet, hub *world.Hub, chars character.Store) error {
	// Round 749's review, F8 (OURS: retail's handler has no rate gate): a
	// click beyond the session's bucket is dropped, silently as every refusal
	// (its client takes a missing echo as a refusal: MoveOrderSync).
	if !moveBucketTake(sess, time.Now()) {
		return nil
	}
	m, angle, err := proto.DecodeMovement(p.Data, false)
	if err != nil || (m.Kind != proto.MovementKindHeading && m.Kind != 1) {
		return nil // a kind other than 0 or 1 is refused
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok || e.Life == world.LifeDead {
		return nil
	}
	// Round 749's review, F4 (READ, GObjPC::FUN_004b0ea0): the abnormal
	// states that stop a move -- the bits 0xc1 | 0x4000 (`test al,0xc1` at
	// 0x4b0fa6), stun, freeze, sleep, root: statuseffect.Holder.CanMove --
	// and an established trade (interaction state 2; 0 and 1 pass).
	if !statusFX.characterCanMove(e.CharacterID) || tradeEstablishedOn(hub, e.CharacterID) {
		return nil
	}
	order := world.MoveOrder{Speed: float64(buffBooks.RunSpeed(e.CharacterID))}
	if m.Kind == proto.MovementKindHeading {
		// The heading form steps only while the command's bit 0 is set
		// (READ, CGObjMoverByCmd::vslot_004); the arrow keys' turn-only
		// commands 0x10 / 0x20 are not modelled (OURS: OpenSRO's client
		// binds no arrow key, keymap.gd NOT_BOUND).
		if m.HeadingByte&proto.MovementCommandForward == 0 {
			return nil
		}
		order.Heading, order.HeadingRadians = true, world.HeadingFromWire(angle)
		order.Command, order.WireAngle = m.HeadingByte, angle
	} else {
		if m.Region&proto.MovementRegionWorldBit != 0 {
			return nil // a dungeon: OpenSRO serves none (OURS)
		}
		here, _, _ := regionLocalOf(e.Zone, e.Pos)
		if !regionsAdjacent(here, m.Region) {
			return nil // outside the 3 x 3 regions (FUN_0048c2d0)
		}
		x, z := worldOfRegionLocal(e.Zone, m.Region, float64(m.LocalX), float64(m.LocalZ))
		order.Dest = world.Position{X: x, Y: float64(m.LocalY), Z: z}
		// Round 749's review, F10, and its verification, FP1 (OURS): a
		// destination's height is bounded as a claim's is, from the last
		// height the client gave (world.Entity.HeightAllows).
		if !e.HeightAllows(x, order.Dest.Y, z, claimHeight, claimSanity) {
			return nil
		}
	}
	now := time.Now()
	// Round 640, OURS: a character its own protection wall holds does not
	// move; its client is told where it is held (walls.go).
	if wallRoots(e.CharacterID) {
		rootedMoveAnswer(sess, e)
		return nil
	}
	// CHANGEMOTION is refused; a sitter stands at once (motion.go).
	if accepted, _ := motions.movedUnrooted(e.CharacterID, now); !accepted {
		return nil
	}
	r, st := hub.StartMove(sess, order)
	if st != world.MoveAccepted {
		return nil
	}
	motions.walking(e.CharacterID, legEnd(r.Entity.Move, now))
	// A move is the player's own cancel of a running auto-attack (keepup.go).
	keepUp.Cancel(e.CharacterID)
	region, lx, lz := regionLocalOf(r.Entity.Zone, r.Entity.Pos)
	data := encodeMoveEcho(uint32(e.CharacterID), movementBytes(m, angle), region, r.Entity.Pos, lx, lz)
	afterRelocate(sess, r, true, gateway.MustFrame(&proto.Packet{Opcode: proto.OpMovementResponse, Data: data}))
	ensureMoverPass(hub)
	// The periodic save is two Postgres writes: after the echo and the
	// watchers' 0xB021, not before (savePositionEvery).
	savePositionEvery(chars, sess, r.Entity, now)
	return nil
}

// movementBytes is the 0x48bad0 serialiser's output for m with no extra byte,
// the heading form carrying the wire angle as it came (Movement.Encode takes
// radians).
func movementBytes(m *proto.Movement, angle uint16) []byte {
	if m.Kind == proto.MovementKindHeading {
		return []byte{proto.MovementKindHeading, m.HeadingByte, byte(angle), byte(angle >> 8)}
	}
	c := *m
	c.HasExtra = false
	return c.Encode()
}

// legEnd is when leg m arrives, or the far future for a heading run.
func legEnd(m *world.Mover, now time.Time) time.Time {
	if m == nil {
		return now
	}
	if m.Heading || m.Speed <= 0 {
		return now.Add(24 * time.Hour)
	}
	return m.Start.Add(time.Duration(m.Length() / m.Speed * float64(time.Second)))
}

// claimBound is a stop's or a placement's world.Bound for characterID now:
// its run speed, the slack, the height, -trust-client-positions, and for a
// placement the points the server named (used up when one is taken).
func claimBound(characterID int64, placement bool, now time.Time) world.Bound {
	b := world.Bound{Speed: float64(buffBooks.RunSpeed(characterID)), Slack: claimSlack, Height: claimHeight,
		Sanity: claimSanity, Trust: trustPositions.Load()}
	if placement {
		b.Named = func(x, z float64) bool { return landingTake(characterID, x, z, now) }
	}
	return b
}

// stopRelay is the 0xB023 of r's entity, to its watchers that hold it (and
// to the mover with self), with what a crossing owes.
func stopRelay(sess *gateway.Session, r world.MoveResult, self bool) {
	afterRelocate(sess, r, self, gateway.MustFrame(&proto.Packet{Opcode: OpMovementStop, Data: encodeMoveStop(r.Entity)}))
}

// correctMover ends sess's character's leg where the server has it and tells
// the window, the mover included: a report or relocation the server did not
// take. The client snaps there (FUN_008a4f80).
func correctMover(sess *gateway.Session, hub *world.Hub) {
	r, ok := hub.Correct(sess)
	if !ok {
		return
	}
	motions.walking(r.Entity.CharacterID, time.Now())
	stopRelay(sess, r, true)
}

// haltForSit ends a leg still running when its character sits or dies (OURS: the
// engine stops a walker before it sits, slot 0x4b0, which sends 0xB023): its
// client stopped before it asked, so only the window is told.
func haltForSit(sess *gateway.Session, hub *world.Hub) {
	r, moved, ok := hub.Halt(sess)
	if !ok || !moved {
		return
	}
	motions.walking(r.Entity.CharacterID, time.Now())
	stopRelay(sess, r, false)
}

// landings holds, per character, the points the server itself named for it
// to stand at (OURS): an arrival's (the world entry's, a zone change's, a
// teleport's, a return's) and the client's spawn spot in that region, and a
// GM's /tp or /goto point. Round 749's review, F2: each point is taken ONCE
// and only within landingGrace of being named -- the arrival's placement on
// its ground -- so a logout spot is no free recall.
var (
	landingsMu sync.Mutex
	landings   = map[int64][]landingPoint{}
)

type landingPoint struct {
	x, z     float64
	deadline time.Time
}

// landingGrace is how long a named point is taken (warpLandingGrace's reason:
// a slow machine's zone load).
const landingGrace = warpLandingGrace

// noteLandings names pts for characterID until now + landingGrace. An
// arrival replaces the points named before it; a GM's point is added.
func noteLandings(characterID int64, now time.Time, replace bool, pts ...[2]float64) {
	landingsMu.Lock()
	defer landingsMu.Unlock()
	if replace {
		delete(landings, characterID)
	}
	for _, p := range pts {
		landings[characterID] = append(landings[characterID], landingPoint{x: p[0], z: p[1], deadline: now.Add(landingGrace)})
	}
}

// noteArrivalLanding names an arrival at pos in zone (a world entry, a zone
// change, a teleport, a return): the point and the client's spawn spot there.
func noteArrivalLanding(characterID int64, zone string, pos world.Position) {
	pts := [][2]float64{{pos.X, pos.Z}}
	if x, z, ok := worldmap.LandingSpotFor(zone, pos.X, pos.Z); ok {
		pts = append(pts, [2]float64{x, z})
	}
	noteLandings(characterID, time.Now(), true, pts...)
}

// noteGMLanding names a GM /tp or /goto point.
func noteGMLanding(characterID int64, now time.Time, x, z float64) {
	noteLandings(characterID, now, false, [2]float64{x, z})
}

func forgetLandings(characterID int64) {
	landingsMu.Lock()
	defer landingsMu.Unlock()
	delete(landings, characterID)
}

// landingTake reports whether (x, z) is one of characterID's named points,
// within warpLandingTolerance on x and z (the height is the client's) and
// inside its grace, and uses it up when it is. Expired points are dropped.
func landingTake(characterID int64, x, z float64, now time.Time) bool {
	landingsMu.Lock()
	defer landingsMu.Unlock()
	pts := landings[characterID]
	kept := pts[:0]
	took := false
	for _, p := range pts {
		if now.After(p.deadline) {
			continue
		}
		if !took && math.Abs(x-p.x) <= warpLandingTolerance && math.Abs(z-p.z) <= warpLandingTolerance {
			took = true
			continue
		}
		kept = append(kept, p)
	}
	if len(kept) == 0 {
		delete(landings, characterID)
	} else {
		landings[characterID] = kept
	}
	return took
}

// The mover pass: one goroutine per hub while it has movers (OURS).
var (
	moverPasses   sync.Map // *world.Hub -> *atomic.Bool (running)
	moverPassAuto atomic.Bool
)

func init() { moverPassAuto.Store(true) }

// ensureMoverPass starts hub's pass if it is not running. The pass ends
// itself when no character has a leg, and the next accepted move starts it
// again, so an idle hub (and a test's) holds no goroutine.
func ensureMoverPass(hub *world.Hub) {
	if !moverPassAuto.Load() {
		return
	}
	v, _ := moverPasses.LoadOrStore(hub, new(atomic.Bool))
	running := v.(*atomic.Bool)
	if !running.CompareAndSwap(false, true) {
		return
	}
	go func() {
		t := time.NewTicker(moverPassPeriod)
		defer t.Stop()
		for range t.C {
			moverPass(hub)
			if hub.Moving() > 0 {
				continue
			}
			running.Store(false)
			// A move accepted between the count and the store found the
			// pass still running and did not start one: take it back.
			if hub.Moving() == 0 || !running.CompareAndSwap(false, true) {
				return
			}
		}
	}()
}

// moverPass refiles every mover whose position crossed a block line and
// delivers what each crossing owes (afterRelocate with no move message): the
// mover the group spawns and despawns, those players its 0x3015 / 0x3016.
func moverPass(hub *world.Hub) {
	pass := hub.AdvanceMovers(moverSpeed)
	for _, r := range pass.Crossings {
		afterRelocate(r.Entity.Session, r, false, nil)
	}
	// A heading run past world.HeadingRunLimit ended (round 749's review,
	// F10): the window and the mover hear where the server stopped it.
	for _, r := range pass.Ended {
		motions.walking(r.Entity.CharacterID, time.Now())
		stopRelay(r.Entity.Session, r, true)
	}
}

// moverSpeed is a mover's run speed now (the buff book's, a GM's /speed
// included): the pass re-bases a leg whose speed a buff changed.
func moverSpeed(characterID int64) float64 {
	return float64(buffBooks.RunSpeed(characterID))
}

// The 0x7021 bucket (round 749's review, F8; OURS -- retail's handler has
// none, READ). An honest client sends one 0x7021 per click and, for an
// approach re-aimed every tick at a target on the move, one per 5.0 units the
// target's point moves: at most about (75 + 50) / 5 = 25 a second against the
// fastest roster monster (Earth Ghost's run 75, characterdata col 47) at the
// base run speed. moveBucketRate is above that, moveBucketBurst holds two
// seconds of it; a session past them has its clicks dropped.
const (
	moveBucketRate  = 30.0
	moveBucketBurst = 60.0
	moveBucketKey   = "session.move.bucket"
)

type moveBucket struct {
	tokens float64
	at     time.Time
}

// moveBucketTake takes one token from sess's bucket, refilled at
// moveBucketRate up to moveBucketBurst; false when it is empty. Only the
// session's own read loop calls it.
func moveBucketTake(sess *gateway.Session, now time.Time) bool {
	v, _ := sess.Get(moveBucketKey)
	b, _ := v.(*moveBucket)
	if b == nil {
		b = &moveBucket{tokens: moveBucketBurst, at: now}
		sess.Set(moveBucketKey, b)
	}
	b.tokens = math.Min(moveBucketBurst, b.tokens+now.Sub(b.at).Seconds()*moveBucketRate)
	b.at = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// moveTrades is each hub's trade hub (round 749's review, F4), registered by
// TradeHandler, for the move's established-trade gate.
var moveTrades sync.Map // *world.Hub -> *trade.Hub

func tradeEstablishedOn(hub *world.Hub, characterID int64) bool {
	v, ok := moveTrades.Load(hub)
	return ok && v.(*trade.Hub).Established(characterID)
}

// haltForState ends characterID's leg where the server has it when a state
// that stops a move lands on it (READ: freeze, stun and sleep call vslot
// 0x570 on apply, GObjPC::FUN_004aa340, which stops the move; the slot-300
// stop sends 0xB023 to the 3 x 3, the mover included -- round 749's review,
// F4). Its client snaps there (FUN_008a4f80).
func haltForState(hub *world.Hub, characterID int64) {
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok || e.Session == nil {
		return
	}
	r, moved, ok := hub.Halt(e.Session)
	if !ok || !moved {
		return
	}
	motions.walking(characterID, time.Now())
	stopRelay(e.Session, r, true)
}
