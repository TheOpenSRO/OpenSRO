package session

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The wire is GObjPC::FUN_004b1630's: u32 id, u8 the requested byte.
func TestEmoteLayout(t *testing.T) {
	got := (&Emote{ObjectID: 0x01020304, Emote: 6}).Encode()
	want := []byte{0x04, 0x03, 0x02, 0x01, 0x06}
	if string(got) != string(want) {
		t.Fatalf("Emote encodes % x, want % x", got, want)
	}
	back, ok := DecodeEmote(got)
	if !ok || back.ObjectID != 0x01020304 || back.Emote != 6 {
		t.Fatalf("round trip: %+v ok %v", back, ok)
	}
	if _, ok := DecodeEmote(got[:4]); ok {
		t.Error("a 4-byte payload decoded")
	}
	if OpEmote != 0x3091 {
		t.Errorf("opcode %#04x, want the retail 0x3091", OpEmote)
	}
}

// Over the wire: Aria's emote reaches Aria and Bram as 0x3091 {Aria, byte},
// the byte echoed as it came (the engine tests nothing); an empty request and
// a dead character's are dropped (OURS).
func TestEmoteBroadcasts(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return EmoteHandler(hub)
	})
	expect := func(who string, p *proto.Packet, emote byte) {
		t.Helper()
		if p.Opcode != OpEmote {
			t.Fatalf("%s got %#04x, want 0x3091", who, p.Opcode)
		}
		e, ok := DecodeEmote(p.Data)
		if !ok || e.ObjectID != uint32(f.aria) || e.Emote != emote {
			t.Fatalf("%s got %+v, want {Aria %d, %d}", who, e, f.aria, emote)
		}
	}
	for _, b := range []byte{0, 6, 0x2a} {
		f.send(t, f.connA, OpEmote, []byte{b})
		expect("Aria", f.read(t, f.connA, f.rA), b)
		expect("Bram", f.read(t, f.connB, f.rB), b)
	}
	f.send(t, f.connA, OpEmote, nil)
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("an empty emote request was broadcast")
	}
	f.kill(t, f.aria, time.Now())
	f.send(t, f.connA, OpEmote, []byte{1})
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("a dead character's emote was broadcast")
	}
}

// FUN_004b1480's case 2/3 (round 781): from STAND either is accepted at once
// (no transition) and sets the run flag; a request equal to a mover's WALK or
// RUN is refused; from SIT or the transition neither is.
func TestWalkRunRequest(t *testing.T) {
	const id = 781001
	t.Cleanup(func() { motions.clear(id) })
	t0 := time.Now()
	motions.enter(id, t0)
	if motions.walkingMode(id) {
		t.Fatal("a fresh entry walks; the mover's default is the run")
	}
	v, ok := motions.request(id, MotionWalk, t0)
	if !ok || v != MotionWalk || !motions.walkingMode(id) {
		t.Fatalf("Walk while standing: value %d ok %v walking %v, want 2 and walking", v, ok, motions.walkingMode(id))
	}
	if s := motions.state(id, t0); s != MotionStand {
		t.Errorf("Walk moved the state to %#x; there is no transition", s)
	}
	if motionSpeed(id) != PlayerWalkSpeed {
		t.Errorf("walking speed %v, want %v", motionSpeed(id), float64(PlayerWalkSpeed))
	}
	// Standing, a second Walk is still taken: the state is STAND, not WALK.
	if _, ok := motions.request(id, MotionWalk, t0); !ok {
		t.Error("a second Walk while standing was refused; only a mover is WALK")
	}
	// On a leg, the state is WALK: a Walk is refused, a Run is taken.
	motions.walking(id, t0.Add(10*time.Second))
	if _, ok := motions.request(id, MotionWalk, t0.Add(time.Second)); ok {
		t.Error("Walk while walking was accepted; a request equal to the state is refused")
	}
	v, ok = motions.request(id, MotionRun, t0.Add(time.Second))
	if !ok || v != MotionRun || motions.walkingMode(id) {
		t.Fatalf("Run while walking: value %d ok %v walking %v", v, ok, motions.walkingMode(id))
	}
	if motionSpeed(id) != float64(buffBooks.RunSpeed(id)) {
		t.Errorf("running speed %v, want the run speed %d", motionSpeed(id), buffBooks.RunSpeed(id))
	}
	if _, ok := motions.request(id, MotionRun, t0.Add(2*time.Second)); ok {
		t.Error("Run while running was accepted")
	}
	// Seated or getting up: refused.
	t1 := t0.Add(time.Minute)
	if _, ok := motions.request(id, MotionSit, t1); !ok {
		t.Fatal("N after the leg was refused")
	}
	for _, req := range []byte{MotionWalk, MotionRun} {
		if _, ok := motions.request(id, req, t1.Add(time.Second)); ok {
			t.Errorf("request %d in the transition was accepted", req)
		}
		if _, ok := motions.request(id, req, t1.Add(MotionChangeDuration)); ok {
			t.Errorf("request %d while seated was accepted", req)
		}
	}
	// A zone change runs again (OURS).
	motions.stand(id, t1.Add(time.Hour))
	motions.request(id, MotionWalk, t1.Add(time.Hour))
	motions.runAgain(id)
	if motions.walkingMode(id) {
		t.Error("runAgain left the walk")
	}
}

// Over the wire: Walk reaches Aria and Bram as 0x30bf {Aria, 1, 2}, Run as
// {Aria, 1, 3}, and the record's run flag follows.
func TestWalkRunBroadcastsAndRecord(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return MotionHandler(hub)
	})
	t.Cleanup(func() { motions.clear(f.aria); motions.clear(f.bram) })
	expect := func(who string, p *proto.Packet, value byte) {
		t.Helper()
		sc, ok := DecodeStateChange(p.Data)
		if p.Opcode != OpStateChange || !ok || sc.ObjectID != uint32(f.aria) || sc.Kind != StateKindMotion || sc.Value != value {
			t.Fatalf("%s got %#04x %+v, want 0x30bf {Aria, 1, %d}", who, p.Opcode, sc, value)
		}
	}
	f.send(t, f.connA, OpMotionRequest, []byte{MotionWalk})
	expect("Aria", f.read(t, f.connA, f.rA), MotionWalk)
	expect("Bram", f.read(t, f.connB, f.rB), MotionWalk)
	if runFlagOf(f.aria) != 0 {
		t.Error("the record's run flag is 1 after a Walk")
	}
	f.send(t, f.connA, OpMotionRequest, []byte{MotionRun})
	expect("Aria", f.read(t, f.connA, f.rA), MotionRun)
	expect("Bram", f.read(t, f.connB, f.rB), MotionRun)
	if runFlagOf(f.aria) != 1 {
		t.Error("the record's run flag is 0 after a Run")
	}
}
