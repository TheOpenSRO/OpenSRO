package session

import (
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The wire layout is GObjPC::BroadcastStateChange's: u32 id, u8 kind, u8 value.
func TestStateChangeLayout(t *testing.T) {
	got := (&StateChange{ObjectID: 0x01020304, Kind: StateKindMotion, Value: MotionSit}).Encode()
	want := []byte{0x04, 0x03, 0x02, 0x01, 0x01, 0x04}
	if string(got) != string(want) {
		t.Fatalf("StateChange encodes % x, want % x", got, want)
	}
	back, ok := DecodeStateChange(got)
	if !ok || back.ObjectID != 0x01020304 || back.Kind != 1 || back.Value != 4 {
		t.Fatalf("round trip: %+v ok %v", back, ok)
	}
	if _, ok := DecodeStateChange(got[:5]); ok {
		t.Error("a 5-byte payload decoded")
	}
	if OpMotionRequest != 0x704f || OpStateChange != 0x30bf {
		t.Errorf("opcodes %#04x/%#04x, want the retail 0x704f/0x30bf", OpMotionRequest, OpStateChange)
	}
}

// FUN_004b1480's toggle: 4 from STAND sits, 4 from SIT stands, each through
// 1.5 s of CHANGEMOTION in which every request is refused.
func TestMotionToggleThroughTheTransition(t *testing.T) {
	const id = 605010
	t.Cleanup(func() { motions.clear(id) })
	t0 := time.Now()
	motions.enter(id, t0)

	v, ok := motions.request(id, MotionSit, t0)
	if !ok || v != MotionSit {
		t.Fatalf("N while standing: value %d ok %v, want 4", v, ok)
	}
	if s := motions.state(id, t0.Add(MotionChangeDuration-time.Millisecond)); s != MotionChangeMotion {
		t.Errorf("1.499 s after N the state is %#x, want CHANGEMOTION 0x12", s)
	}
	if _, ok := motions.request(id, MotionSit, t0.Add(time.Second)); ok {
		t.Error("a second N inside the transition was accepted; the engine refuses 0x12")
	}
	if s := motions.state(id, t0.Add(MotionChangeDuration)); s != MotionSit {
		t.Fatalf("1.5 s after N the state is %#x, want SIT", s)
	}

	t1 := t0.Add(10 * time.Second)
	v, ok = motions.request(id, MotionSit, t1)
	if !ok || v != MotionStand {
		t.Fatalf("N while sitting: value %d ok %v, want 0 (stand)", v, ok)
	}
	if s := motions.state(id, t1.Add(time.Second)); s != MotionChangeMotion {
		t.Errorf("getting up: state %#x, want CHANGEMOTION", s)
	}
	if s := motions.state(id, t1.Add(MotionChangeDuration)); s != MotionStand {
		t.Errorf("1.5 s after the second N the state is %#x, want STAND", s)
	}
}

// The requests FUN_004b1480 does nothing for.
func TestMotionRequestsTheEngineRefuses(t *testing.T) {
	const id = 605011
	t.Cleanup(func() { motions.clear(id) })
	t0 := time.Now()
	motions.enter(id, t0)
	for _, req := range []byte{MotionStand, MotionWalk, MotionRun, 0x0c, 0x07} {
		if v, ok := motions.request(id, req, t0); ok {
			t.Errorf("request %#x while standing was accepted with value %d", req, v)
		}
	}
	if s := motions.state(id, t0); s != MotionStand {
		t.Errorf("a refused request moved the state to %#x", s)
	}
}

// A move while seated is accepted and stands the character at once (the
// movement handler's SetMotionState(WALK/RUN), no transition); a move in the
// transition is refused (state 0x12 blocks 0x4b0ea0).
func TestMoveWhileSeated(t *testing.T) {
	const id = 605012
	t.Cleanup(func() { motions.clear(id) })
	t0 := time.Now()
	motions.enter(id, t0)
	motions.request(id, MotionSit, t0)
	if ok, _ := motions.moved(id, t0.Add(time.Second)); ok {
		t.Error("a move inside the sit-down transition was accepted")
	}
	seatedAt := t0.Add(MotionChangeDuration)
	ok, left := motions.moved(id, seatedAt)
	if !ok || !left {
		t.Fatalf("a move while sitting: accepted %v left %v, want both", ok, left)
	}
	if s := motions.state(id, seatedAt); s != MotionStand {
		t.Errorf("after the move the state is %#x, want STAND at once", s)
	}
	if _, ok := motions.regenRate(id, seatedAt.Add(100*time.Millisecond)); ok {
		t.Error("a character that just moved regenerates")
	}
}

// A landed blow stands a sitter through the transition; a blow that landed
// nothing and a blow on a standing character change nothing.
func TestStandOnHit(t *testing.T) {
	const id = 605013
	t.Cleanup(func() { motions.clear(id) })
	hub := world.NewHub() // no entity: nobody to broadcast to
	t0 := time.Now().Add(-10 * time.Second)
	motions.enter(id, t0)

	standOnHit(hub, id, 25)
	if s := motions.state(id, time.Now()); s != MotionStand {
		t.Fatalf("a blow on a standing character moved it to %#x", s)
	}
	motions.request(id, MotionSit, t0)
	standOnHit(hub, id, 0)
	if s := motions.state(id, time.Now()); s != MotionSit {
		t.Fatalf("a blow that landed nothing stood the sitter up (state %#x)", s)
	}
	standOnHit(hub, id, 25)
	now := time.Now()
	if s := motions.state(id, now); s != MotionChangeMotion {
		t.Fatalf("a landed blow on a sitter left state %#x, want CHANGEMOTION", s)
	}
	if !seatedCastRefused(refdata.SitGateActionOff, id, now) {
		t.Error("an 'ao'/'pw' skill is allowed while getting up; the skill gate refuses CHANGEMOTION (0x58e0d3)")
	}
	if s := motions.state(id, now.Add(MotionChangeDuration)); s != MotionStand {
		t.Errorf("1.5 s after the blow the state is %#x, want STAND", s)
	}
}

// Over the wire: Aria's N reaches Aria and Bram as 0x30bf {Aria, 1, 4}; her move
// inside the transition is dropped, so Bram hears nothing of it; her second N
// once seated broadcasts 0 (stand). A request from a dead character is dropped.
func TestMotionRequestBroadcasts(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return MotionHandler(hub)
	})
	t.Cleanup(func() { motions.clear(f.aria); motions.clear(f.bram) })
	expect := func(who string, p *proto.Packet, value byte) {
		t.Helper()
		if p.Opcode != OpStateChange {
			t.Fatalf("%s got %#04x, want 0x30bf", who, p.Opcode)
		}
		sc, ok := DecodeStateChange(p.Data)
		if !ok || sc.ObjectID != uint32(f.aria) || sc.Kind != StateKindMotion || sc.Value != value {
			t.Fatalf("%s got %+v, want {Aria %d, kind 1, value %d}", who, sc, f.aria, value)
		}
	}

	f.send(t, f.connA, OpMotionRequest, []byte{MotionSit})
	expect("Aria", f.read(t, f.connA, f.rA), MotionSit)
	expect("Bram", f.read(t, f.connB, f.rB), MotionSit)

	f.send(t, f.connA, OpMove, (&MoveRequest{X: 5, Y: 0, Z: 5}).Encode())
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("Bram heard a move Aria made while sitting down")
	}
	time.Sleep(MotionChangeDuration)
	f.send(t, f.connA, OpMotionRequest, []byte{MotionSit})
	expect("Aria", f.read(t, f.connA, f.rA), MotionStand)
	expect("Bram", f.read(t, f.connB, f.rB), MotionStand)

	f.kill(t, f.bram, time.Now())
	f.send(t, f.connB, OpMotionRequest, []byte{MotionSit})
	if !f.nothing(t, f.connA, f.rA) {
		t.Error("a dead character's N was broadcast")
	}
}

// The skill-use gate's motion-state refusals, read: only a skill carrying
// 'ao'/'pw' (SIT and CHANGEMOTION) or a kind-1 'msch' (SIT) is refused to a
// seated caster; every other skill, the plain attacks among them, is not.
func TestSeatedCastRefusedFollowsTheGate(t *testing.T) {
	const id = 605014
	t.Cleanup(func() { motions.clear(id) })
	t0 := time.Now().Add(-10 * time.Second)
	motions.enter(id, t0)
	now := time.Now()
	for _, gate := range []int{0, refdata.SitGateActionOff, refdata.SitGateTransform} {
		if seatedCastRefused(gate, id, now) {
			t.Errorf("gate %d refused a standing caster", gate)
		}
	}
	motions.request(id, MotionSit, t0) // seated since t0 + 1.5 s
	if seatedCastRefused(0, id, now) {
		t.Error("a skill with no 'ao', 'pw' or kind-1 'msch' was refused to a seated caster; the gate lets it through")
	}
	if !seatedCastRefused(refdata.SitGateActionOff, id, now) {
		t.Error("an 'ao'/'pw' skill was allowed to a seated caster (0x58e0cb)")
	}
	if !seatedCastRefused(refdata.SitGateTransform, id, now) {
		t.Error("a kind-1 'msch' skill was allowed to a seated caster (0x58ded4)")
	}
	// Getting up: 'ao'/'pw' still refused, the kind-1 'msch' branch tests SIT only.
	motions.request(id, MotionSit, now)
	if !seatedCastRefused(refdata.SitGateActionOff, id, now) {
		t.Error("an 'ao'/'pw' skill was allowed in CHANGEMOTION")
	}
	if seatedCastRefused(refdata.SitGateTransform, id, now) {
		t.Error("a kind-1 'msch' skill was refused in CHANGEMOTION; its branch tests SIT only")
	}
}

// A player who enters after Aria sat down, or changes zone into hers, is told
// so IN the result that spawns her body (round 607's review: a separate 0x30bf
// after the list reached the client before the world scene, or the new zone's
// bodies, existed).
func TestLateArrivalHearsWhoIsSeated(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return MotionHandler(hub)
	})
	t.Cleanup(func() { motions.clear(f.aria); motions.clear(f.bram) })
	if _, ok := motions.request(f.aria, MotionSit, time.Now().Add(-10*time.Second)); !ok {
		t.Fatal("could not sit Aria")
	}
	// Bram re-enters the world.
	f.send(t, f.connB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	p := f.read(t, f.connB, f.rB)
	ewr, err := DecodeEnterWorldResult(p.Data)
	if p.Opcode != OpEnterWorldResult || err != nil || len(ewr.Seated) != 1 || ewr.Seated[0] != f.aria {
		t.Fatalf("Bram's enter-world result: %#04x %+v (err %v), want Seated [Aria %d]", p.Opcode, ewr, err, f.aria)
	}
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("a separate packet followed the enter-world result; the seated state belongs in it")
	}
	// Bram leaves for another zone and comes back into Aria's.
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK || len(czr.Seated) != 0 {
		t.Fatalf("change to donwhang: %+v, want OK with nobody seated", czr)
	}
	f.nothing(t, f.connA, f.rA) // drain Aria's notice of Bram leaving (not asserted)
	czr := changeZone(t, f, f.connB, f.rB, "jangan")
	if !czr.OK || len(czr.Seated) != 1 || czr.Seated[0] != f.aria {
		t.Fatalf("change back to jangan: %+v, want Seated [Aria %d]", czr, f.aria)
	}
}

// The Seated tail is sent only when someone sits, so every other payload is
// byte for byte what it was; with it, Restored is written even when false,
// and both round-trip.
func TestSeatedTailIsASuffix(t *testing.T) {
	base := EnterWorldResult{OK: true, Zone: "jangan", FrameRegion: "97/168"}
	plain := base.Encode()
	withSeated := base
	withSeated.Seated = []int64{7, 9}
	enc := withSeated.Encode()
	if string(enc[:len(plain)]) != string(plain) {
		t.Fatal("the seated tail changed the bytes before it")
	}
	if len(enc) != len(plain)+1+2+16 {
		t.Fatalf("tail is %d bytes, want 1 (Restored) + 2 + 16", len(enc)-len(plain))
	}
	back, err := DecodeEnterWorldResult(enc)
	if err != nil || back.Restored || len(back.Seated) != 2 || back.Seated[0] != 7 || back.Seated[1] != 9 {
		t.Fatalf("round trip: %+v, %v", back, err)
	}
	if back, err = DecodeEnterWorldResult(plain); err != nil || back.Seated != nil {
		t.Fatalf("a payload with no tail decoded Seated %v (err %v)", back.Seated, err)
	}
	cz := ChangeZoneResult{OK: true, Zone: "jangan", FrameRegion: "97/168"}
	czPlain := cz.Encode()
	cz.Seated = []int64{7}
	czEnc := cz.Encode()
	if string(czEnc[:len(czPlain)]) != string(czPlain) || len(czEnc) != len(czPlain)+2+8 {
		t.Fatal("ChangeZoneResult's seated tail is not a suffix")
	}
	if b, err := DecodeChangeZoneResult(czEnc); err != nil || len(b.Seated) != 1 || b.Seated[0] != 7 {
		t.Fatalf("ChangeZoneResult round trip: %+v, %v", b, err)
	}
}
