package session

import (
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 749's fix verification (docs/rounds/r749_review.md, "Fix verification
// (honest play)"): honest players under the production bound
// (-trust-client-positions off), with the latency, heights and arrivals a
// public server sees. The client is modelled as World3D + MoveOrderSync do it
// at 1d06b4ab: it walks its click at once at the run speed, sends a stop when
// its walk ends short (a wall, an approach in reach, a sky run's end, no echo
// in MoveOrderSync.ECHO_TIMEOUT_MS), and answers every own 0xB023 by snapping
// to its (x, z), taking the ground's height there, and sending a stop from it
// (_apply_own_correction).
//
// The TestR749vFP* tests are the false positives the verification found; the
// fixes landed (round 749's second fix round), so they assert now -- the gate
// is gone. The TestR749vHonest* tests are scenarios that must keep passing.
// (The client's answer to every correction they model was the 1d06b4ab
// client's; since the fix it answers only when a 0x7021 may be in flight --
// the server no longer issues the corrections they would answer.)

// echoTimeout is MoveOrderSync.ECHO_TIMEOUT_MS (1.0 s since the fix, FP4).
const echoTimeout = 1000 * time.Millisecond

// fpGate fails t: a false positive the fixes must have removed.
func fpGate(t *testing.T, format string, args ...any) {
	t.Helper()
	t.Errorf(format, args...)
}

// warm walks Aria 10 east and back, both arrived, and lets her stand `rest`:
// a character's allowance accrues at the run speed of its last leg or claim,
// which a character fresh from the world entry does not have yet (see
// TestR749vFP5FirstWalkAfterEntryBanksNothing).
func (f *deadWorldFixture) warm(t *testing.T, advance func(time.Duration), rest time.Duration) {
	t.Helper()
	for _, x := range []float64{10, 0} {
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(x, 0, 0))
		if !f.echoed(t) {
			t.Fatalf("warm-up: the click to %v was refused", x)
		}
		advance(200 * time.Millisecond) // 10 units: arrived just now
	}
	advance(rest)
	drainQuiet(t, f.connB, f.rB)
}

// stopAt sends the client's stop report (OpMove, the stop flag) at (x, y, z).
func (f *deadWorldFixture) stopAt(t *testing.T, x, y, z float64) {
	t.Helper()
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(x), Y: float32(y), Z: float32(z), Stopped: true}).Encode())
}

// correction reads Aria's own 0xB023 within 250 ms: the server's refusal of
// her last claim. ok false when none came (the claim was taken).
func (f *deadWorldFixture) correction(t *testing.T) (pos world.Position, ok bool) {
	t.Helper()
	for {
		f.connA.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
		p, err := proto.Read(f.rA, nil, nil)
		if err != nil {
			return world.Position{}, false
		}
		if p.Opcode != OpMovementStop {
			continue
		}
		id, at, _ := stopWorld(t, spawnZone, p.Data)
		if id == f.aria {
			return at, true
		}
	}
}

// echoed reports whether Aria's 0x7021 was answered with her own 0xB021
// within 250 ms (MoveOrderSync.confirm's receipt).
func (f *deadWorldFixture) echoed(t *testing.T) bool {
	t.Helper()
	for {
		f.connA.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
		p, err := proto.Read(f.rA, nil, nil)
		if err != nil {
			return false
		}
		if p.Opcode == proto.OpMovementResponse {
			return true
		}
	}
}

// answerCorrections plays the honest client's _apply_own_correction against
// up to n corrections: snap to the correction's (x, z), stand on the ground
// there (groundY), send a stop from it. It returns how many corrections came.
func (f *deadWorldFixture) answerCorrections(t *testing.T, first world.Position, groundY float64, n int) int {
	t.Helper()
	count, at := 1, first
	for count < n {
		f.stopAt(t, at.X, groundY, at.Z)
		next, ok := f.correction(t)
		if !ok {
			return count
		}
		count++
		at = next
	}
	return count
}

// The heights below are MEASURED on the user's Map.pk2 (docs/rounds/
// r749_review.md, "Fix verification"): the client stands a body at the raw
// .m height less its grid's anchor (block 0 vertex 8 of the frame region,
// MapmTerrainBuilder.near_row_middle_height); production runs -full-map, so
// -single-frame, so every town's anchor is Jangan's (-2.5).
const (
	// hotanGroundY is the client's ground at Hotan's landing (92/135 local
	// 960, 960: raw 243.8) in the single frame. The server lands it at
	// spawnPos.Y = 0.
	hotanGroundY = 246.3
	// skyRunRise is Hotan's own centre region, a 300-unit run +x from local
	// (60, 960) to (360, 960): raw 117.8 -> 243.6.
	skyRunRise = 243.6 - 117.8
	// legBulge is Jangan's fields, 99/168, the leg (1500, 120) -> (1800,
	// 120): ends 45.1 and -23.7, its middle 146.3 -- 135.6 above the line.
	legBulge = 146.3 - (45.1-23.7)/2
)

// FP1: a teleport or zone change to Hotan (or Samarkand, Donwhang) under the
// production -full-map. The server lands the character at height 0; the
// client stands it on the ground at 246.3 and tells the server nothing
// (World3D._land_teleport_arrival / _on_change_zone_result: placed() only).
// A click within 146 of the landing is refused by the destination height
// bound; the client's no-echo stop is refused by the claim height bound; and
// every correction is answered by a stop the same bound refuses -- a loop at
// the round trip, for as long as the player plays there.
func TestR749vFP1ArrivalHeightLoop(t *testing.T) {
	strictPositions(t)
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 0)
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "hotan"}).Encode())
	if czr, err := DecodeChangeZoneResult(f.read(t, f.connA, f.rA).Data); err != nil || !czr.OK {
		t.Fatalf("setup: the zone change answered %+v (err %v)", czr, err)
	}
	drainQuiet(t, f.connA, f.rA)
	drainQuiet(t, f.connB, f.rB)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	t.Logf("Hotan arrival: the server has Aria at height %.1f; her client stands her at %.1f", e.Pos.Y, hotanGroundY)
	advance(3 * time.Second)

	// A click on the ground 40 east (an NPC, a monster).
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(e.Pos.X+40, hotanGroundY, e.Pos.Z))
	clickTaken := f.echoed(t)
	// The client walked it (0.8 s) and, with no echo by 1.5 s, reports where
	// it stands.
	advance(echoTimeout)
	f.stopAt(t, e.Pos.X+40, hotanGroundY, e.Pos.Z)
	first, corrected := f.correction(t)
	loops := 0
	if corrected {
		loops = f.answerCorrections(t, first, hotanGroundY, 25)
	}
	t.Logf("a 40-unit click: echoed %v; the stop corrected %v; corrections answered by the honest client: %d (cap 25)", clickTaken, corrected, loops)
	// The control: the same spot claimed at the server's height is taken --
	// the refusal is the height bound's.
	f.stopAt(t, first.X, 0, first.Z)
	if _, again := f.correction(t); again && corrected {
		t.Errorf("control: a stop at the server's own height was corrected too -- the cause is not the height")
	}
	if !clickTaken || corrected {
		fpGate(t, "an honest walk 40 units from a Hotan landing: click echoed %v, stop corrected %v, then %d corrections in a row (want the click taken and no correction)", clickTaken, corrected, loops)
	}
}

// FP2: a sky run (the heading form) keeps its start's height for the whole run
// (Mover.At); 300 units over Hotan's own centre region rise 125.8. The run's
// end is refused on height, and the correction loop follows.
func TestR749vFP2SkyRunHeight(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	f.send(t, f.connA, proto.OpMovementRequest, []byte{0, proto.MovementCommandForward, 0, 0}) // run +x
	if !f.echoed(t) {
		t.Fatal("setup: the sky run was refused")
	}
	advance(6 * time.Second) // 300 units
	f.stopAt(t, 300, skyRunRise, 0)
	first, corrected := f.correction(t)
	loops := 0
	if corrected {
		loops = f.answerCorrections(t, first, skyRunRise, 25)
	}
	t.Logf("a 6 s sky run rising %.1f: the stop corrected %v (to %+v); corrections in a row: %d (cap 25)", skyRunRise, corrected, first, loops)
	if corrected {
		fpGate(t, "an honest 300-unit sky run rising %.1f: its end was corrected, then %d corrections in a row", skyRunRise, loops)
	}
}

// FP3: a destination leg's height is the straight line between its ends
// (Mover.At); a stop in the middle of Jangan's fields' leg (99/168) stands
// 135.6 above it.
func TestR749vFP3LegMiddleHeight(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	// Ends at 0 and 0 (the measured ends' mean is 10.7: the line is shifted to
	// the fixture's height 0, the bulge kept).
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(300, 0, 0))
	if !f.echoed(t) {
		t.Fatal("setup: the click was refused")
	}
	advance(3 * time.Second) // 150 units: the middle
	f.stopAt(t, 150, legBulge, 0)
	first, corrected := f.correction(t)
	loops := 0
	if corrected {
		loops = f.answerCorrections(t, first, legBulge, 25)
	}
	t.Logf("a stop in the middle of a 300-unit leg, %.1f above its line: corrected %v; corrections in a row: %d (cap 25)", legBulge, corrected, loops)
	if corrected {
		fpGate(t, "an honest stop %.1f above the leg's straight line was corrected, then %d corrections in a row", legBulge, loops)
	}
}

// lagCase is one walk under latency: the client clicks far east at hub time
// 0 and walks; its 0x7021 reaches the server `click` later; it stops after
// `walk` (a wall, an approach in reach, the echo timeout) and that report
// reaches the server `stop` after it was sent -- but never before the click
// (TCP keeps the order). `rest` is how long it stood before the click
// (the allowance banks while standing, one second's worth at most).
type lagCase struct {
	name              string
	rest, click, walk time.Duration
	stop              time.Duration
	fresh             bool // no walk since the world entry (no warm-up)
}

func runLagCase(t *testing.T, c lagCase) (admitted bool, lead float64) {
	t.Helper()
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	if !c.fresh {
		f.warm(t, advance, 0)
	}
	now := time.Duration(0)
	to := func(at time.Duration) {
		if at > now {
			advance(at - now)
			now = at
		}
	}
	to(c.rest)
	t0 := now
	to(t0 + c.click)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(2000, 0, 0))
	if !f.echoed(t) {
		t.Fatal("setup: the click was refused")
	}
	stopArrives := t0 + c.walk + c.stop
	if stopArrives < t0+c.click {
		stopArrives = t0 + c.click
	}
	to(stopArrives)
	x := PlayerRunSpeed * c.walk.Seconds()
	f.stopAt(t, x, 0, 0)
	_, corrected := f.correction(t)
	served := PlayerRunSpeed * (stopArrives - t0 - c.click).Seconds()
	return !corrected, x - served
}

// Latency: a steady link, jitter, and spikes, on a walk that a stop ends.
func TestR749vFP4LagSpikes(t *testing.T) {
	cases := []lagCase{
		{"steady 150 ms, wall at 1 s", 2 * time.Second, 150 * time.Millisecond, time.Second, 150 * time.Millisecond, false},
		{"jitter: click 300 ms, stop 50 ms", 2 * time.Second, 300 * time.Millisecond, time.Second, 50 * time.Millisecond, false},
		{"spike 1.0 s on the click, stop bunched behind it", 2 * time.Second, time.Second, 900 * time.Millisecond, 50 * time.Millisecond, false},
		{"spike 1.2 s, stop bunched", 2 * time.Second, 1200 * time.Millisecond, 1100 * time.Millisecond, 50 * time.Millisecond, false},
		{"spike 1.6 s: the echo timeout stops the walk at 1.0 s", 2 * time.Second, 1600 * time.Millisecond, echoTimeout, 50 * time.Millisecond, false},
		{"spike 3 s: the echo timeout stops the walk at 1.0 s", 2 * time.Second, 3 * time.Second, echoTimeout, 50 * time.Millisecond, false},
		{"spike 0.5 s within 0.2 s of the last arrival (little banked)", 200 * time.Millisecond, 500 * time.Millisecond, 400 * time.Millisecond, 50 * time.Millisecond, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			admitted, lead := runLagCase(t, c)
			t.Logf("%s: the client was %.1f ahead of the server's leg; admitted %v", c.name, lead, admitted)
			if !admitted {
				fpGate(t, "%s: an honest stop %.1f ahead of the leg was corrected (the bound takes %.0f + the allowance banked)", c.name, lead, claimSlack)
			}
		})
	}
}

// FP5: a character fresh from the world entry (or a zone change before its
// first walk) banks nothing however long it stands: Hub.Enter leaves
// allowSpeed 0, and StartMove brings the allowance up to now at that speed
// before it sets the leg's (claim.go accrueLocked). Its first walk has the
// free slack only, so a 0.5 s spike on it is corrected.
func TestR749vFP5FirstWalkAfterEntryBanksNothing(t *testing.T) {
	c := lagCase{name: "spike 0.5 s on the first walk after the world entry, after standing 10 s",
		rest: 10 * time.Second, click: 500 * time.Millisecond, walk: 400 * time.Millisecond, stop: 50 * time.Millisecond, fresh: true}
	admitted, lead := runLagCase(t, c)
	t.Logf("%s: %.1f ahead; admitted %v", c.name, lead, admitted)
	if !admitted {
		fpGate(t, "%s: a stop %.1f ahead was corrected -- 10 s of standing banked nothing", c.name, lead)
	}
}

// Redirects under a steady 300 ms uplink with jitter: the server starts each
// leg where its own leg had the character, the client where it stood; the
// approach that ends the chase is reported and must be taken.
func TestR749vHonestChaseUnderJitter(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	type click struct {
		at, lag time.Duration
		x, z    float64
	}
	// A monster circling: four re-aims 0.4 s apart, uplink 300/100/400/200 ms.
	clicks := []click{
		{0, 300 * time.Millisecond, 200, 0},
		{400 * time.Millisecond, 100 * time.Millisecond, 200, 100},
		{800 * time.Millisecond, 400 * time.Millisecond, 150, 200},
		{1200 * time.Millisecond, 200 * time.Millisecond, 50, 250},
	}
	// The client's own walk (it walks every click at once).
	px, pz := 0.0, 0.0
	tc := time.Duration(0)
	walk := func(to time.Duration, tx, tz float64) {
		d := PlayerRunSpeed * (to - tc).Seconds()
		dx, dz := tx-px, tz-pz
		if l := math.Hypot(dx, dz); l > 0 {
			if d > l {
				d = l
			}
			px, pz = px+dx/l*d, pz+dz/l*d
		}
		tc = to
	}
	// Deliveries in order (TCP), each no earlier than the one before.
	now, last := time.Duration(0), time.Duration(0)
	for i, c := range clicks {
		if i > 0 {
			walk(c.at, clicks[i-1].x, clicks[i-1].z)
		}
		arrive := c.at + c.lag
		if arrive < last {
			arrive = last
		}
		last = arrive
		advance(arrive - now)
		now = arrive
		f.send(t, f.connA, proto.OpMovementRequest, clickTo(c.x, 0, c.z))
		if !f.echoed(t) {
			t.Fatalf("re-aim %d refused", i)
		}
	}
	// In reach at 1.7 s: the client stops and reports; 200 ms uplink.
	walk(1700*time.Millisecond, clicks[3].x, clicks[3].z)
	arrive := 1900 * time.Millisecond
	advance(arrive - now)
	f.stopAt(t, px, 0, pz)
	if at, corrected := f.correction(t); corrected {
		t.Fatalf("the chase's approach stop at (%.1f, %.1f) was corrected to %+v", px, pz, at)
	}
}

// The bucket against an honest chase: re-aims at the fastest roster monster's
// 15 a second (75 / 5.0) plus a player's 8 clicks a second for 10 s.
func TestR749vHonestBucketChase(t *testing.T) {
	sess := gateway.NewTestSession(749)
	now := time.Now()
	dropped := 0
	for i := 0; i < 230; i++ { // 23 a second for 10 s
		if !moveBucketTake(sess, now.Add(time.Duration(i)*time.Second/23)) {
			dropped++
		}
	}
	if dropped != 0 {
		t.Fatalf("an honest 23 clicks a second for 10 s lost %d", dropped)
	}
	// A 4 s uplink stall of re-aims at 15 a second, delivered at once.
	sess = gateway.NewTestSession(750)
	dropped = 0
	for i := 0; i < 60; i++ {
		if !moveBucketTake(sess, now) {
			dropped++
		}
	}
	t.Logf("a 4 s stall of 15 re-aims a second (60) delivered at once: %d dropped", dropped)
	if dropped != 0 {
		t.Fatalf("a 4 s stall's re-aims lost %d", dropped)
	}
}

// A speed buff mid-walk: the server re-bases the leg on its next pass (up to
// 250 ms late) and its client hears the speed a round trip later; the stop
// is taken.
func TestR749vHonestSpeedBuffMidWalk(t *testing.T) {
	strictPositions(t)
	moverPassAuto.Store(false)
	t.Cleanup(func() { moverPassAuto.Store(true) })
	f := startDeadWorldFixture(t)
	t.Cleanup(func() { buffBooks.SetGMSpeedFactor(f.aria, 1) })
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(2000, 0, 0))
	if !f.echoed(t) {
		t.Fatal("setup: the click was refused")
	}
	advance(time.Second) // 50 walked
	buffBooks.SetGMSpeedFactor(f.aria, 1.5)
	drainQuiet(t, f.connA, f.rA)
	advance(250 * time.Millisecond) // the pass re-bases 250 ms late
	moverPass(f.hub)
	// The client heard 75 at 1.1 s (100 ms downlink): 50 + 0.1 x 50 + 0.9 x 75 at 2.0 s.
	advance(750 * time.Millisecond)
	x := 50 + 0.1*50 + 0.9*75
	f.stopAt(t, x, 0, 0)
	if at, corrected := f.correction(t); corrected {
		t.Fatalf("a stop after a speed buff at %.1f was corrected to %+v", x, at)
	}
}

// A stun mid-walk: the server halts the leg and corrects its client (0xB023
// to the mover); the client's answering stop, from the halt point, is taken
// and the exchange ends there (no loop on flat ground).
func TestR749vHonestStunHaltEnds(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(300, 0, 0))
	if !f.echoed(t) {
		t.Fatal("setup: the click was refused")
	}
	advance(time.Second)
	haltForState(f.hub, f.aria)
	at, ok := f.correction(t)
	if !ok {
		t.Fatal("no 0xB023 for the halt")
	}
	f.stopAt(t, at.X, 0, at.Z)
	if again, corrected := f.correction(t); corrected {
		t.Fatalf("the client's stop from the halt point was corrected again to %+v", again)
	}
}

// Ghost Walk with a click in flight: the server's Relocate lands the caster,
// then the click it had sent before starts a leg from the landing that its
// client does not walk; the client's next stop, from the landing, is taken.
func TestR749vHonestGhostWalkWithClickInFlight(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	land := world.Position{X: 60, Y: 0, Z: 0}
	if _, ok := f.hub.Relocate(e.Session, land, world.MoveRelocate, 0); !ok {
		t.Fatal("setup: relocate")
	}
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(-200, 0, 0))
	f.echoed(t)
	advance(500 * time.Millisecond)
	f.stopAt(t, land.X, 0, land.Z)
	if at, corrected := f.correction(t); corrected {
		t.Fatalf("a stop at the Ghost Walk landing was corrected to %+v", at)
	}
}

// A walk across a region line (region 97/168 into 98/168 runs at world x 960
// from the fixture's spawn): the mover pass refiles it, and a stop on the far
// side is taken.
func TestR749vHonestRegionCrossing(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	advance := fakeHubClock(t, f.hub)
	f.warm(t, advance, 2*time.Second)
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(1500, 0, 0))
	if !f.echoed(t) {
		t.Fatal("setup: the click was refused")
	}
	for i := 0; i < 22; i++ { // 22 s: 1,100 units
		advance(time.Second)
		moverPass(f.hub)
	}
	f.stopAt(t, 1100, 0, 0)
	if at, corrected := f.correction(t); corrected {
		t.Fatalf("a stop past the region line was corrected to %+v", at)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if r, _, _ := regionLocalOf(e.Zone, e.Pos); r == janganRegion {
		t.Fatalf("Aria at %+v is still filed in the spawn region", e.Pos)
	}
}

// /unstuck past the arrival's grace (FP6): since the fix it is the server's
// (unstuck.go). The character, stuck 300 east, asks; the server puts it at the
// zone's landing spot -- Jangan's spawn spot, worldmap.LandingSpotFor -- and
// says so with its own 0xB023 and OpUnstuckResult; a second ask within the
// cooldown is refused with the wait; and nothing ever returns it to a logout
// spot.
func TestR749vFP6UnstuckAfterGrace(t *testing.T) {
	strictPositions(t)
	f := startDeadWorldFixture(t)
	t.Cleanup(func() { unstuckLast.Delete(f.aria) })
	advance := fakeHubClock(t, f.hub)
	// Walk 300 east (into a building, say) and get stuck there.
	f.send(t, f.connA, proto.OpMovementRequest, clickTo(300, 0, 0))
	if !f.echoed(t) {
		t.Fatal("setup: the click was refused")
	}
	advance(10 * time.Second)
	landingsMu.Lock()
	delete(landings, f.aria) // the arrival's grace long gone
	landingsMu.Unlock()
	f.send(t, f.connA, OpUnstuck, nil)
	at, moved := f.correction(t)
	wantX, wantZ, _ := worldmap.LandingSpotFor(spawnZone, spawnPos.X, spawnPos.Z)
	if !moved || math.Abs(at.X-wantX) > 1e-3 || math.Abs(at.Z-wantZ) > 1e-3 {
		fpGate(t, "/unstuck past the grace: put %v at %+v, want the zone's landing spot (%.1f, %.1f)", moved, at, wantX, wantZ)
	}
	p, _ := readOp(t, f, f.connA, f.rA, OpUnstuckResult)
	if r, ok := DecodeUnstuckResult(p.Data); !ok || !r.OK {
		t.Fatalf("/unstuck answered %+v", r)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); math.Abs(e.Pos.X-wantX) > 1e-3 {
		t.Fatalf("the server has Aria at %+v", e.Pos)
	}
	// The client stands on its ground there and walks on: taken.
	f.stopAt(t, wantX, 37, wantZ)
	if again, corrected := f.correction(t); corrected {
		t.Fatalf("the client's stop at the landing spot was corrected to %+v", again)
	}
	// Again at once: refused, with the wait.
	f.send(t, f.connA, OpUnstuck, nil)
	p, _ = readOp(t, f, f.connA, f.rA, OpUnstuckResult)
	if r, ok := DecodeUnstuckResult(p.Data); !ok || r.OK || r.Wait == 0 || r.Wait > uint16(unstuckCooldown/time.Second) {
		t.Fatalf("a second /unstuck at once answered %+v, want a refusal with the wait", r)
	}
}
