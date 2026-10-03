package session

import (
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// A kind-4 value-1 state change carries one more byte (chardata+5), as
// GObjPC::BroadcastStateChange (0x4a8340) appends it and the client's
// 0x8a80a0 reads it; every other change stays six bytes.
func TestBodyModeStateChangeLayout(t *testing.T) {
	on := (&StateChange{ObjectID: 7, Kind: StateKindBodyMode, Value: 1}).Encode()
	if len(on) != 7 {
		t.Fatalf("kind 4 value 1 is %d bytes, want 7 (% x)", len(on), on)
	}
	off := (&StateChange{ObjectID: 7, Kind: StateKindBodyMode, Value: 0}).Encode()
	if len(off) != 6 {
		t.Fatalf("kind 4 value 0 is %d bytes, want 6", len(off))
	}
	back, ok := DecodeStateChange(on)
	if !ok || back.Kind != 4 || back.Value != 1 {
		t.Fatalf("round trip: %+v ok %v", back, ok)
	}
	if _, ok := DecodeStateChange(on[:6]); ok {
		t.Fatal("a kind-4 value-1 change without its extra byte decoded")
	}
}

// Going berserk broadcasts the body mode on to the zone, the berserker
// included, and its end is pushed when the activation runs out -- the tracker
// only expires lazily, so without the push nothing would say it (round 629's
// review; the engine's SetBodyMode does it on its own timer).
func TestBerserkBroadcastsBodyModeOnAndOff(t *testing.T) {
	old := berserkEndDelay
	berserkEndDelay = func(time.Time) time.Duration { return 50 * time.Millisecond }
	t.Cleanup(func() { berserkEndDelay = old })
	zerk := berserk.NewTracker()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			if p.Opcode != OpBerserk {
				return nil
			}
			return handleBerserk(ctx, sess, p, chars, hub, zerk)
		}
	})
	if err := f.chars.SetHwanCount(context.Background(), f.aria, 5); err != nil {
		t.Fatalf("SetHwanCount: %v", err)
	}
	expect := func(who string, p *proto.Packet, value byte) {
		t.Helper()
		if p.Opcode != OpStateChange {
			t.Fatalf("%s got %#04x, want 0x30bf", who, p.Opcode)
		}
		sc, ok := DecodeStateChange(p.Data)
		if !ok || sc.ObjectID != uint32(f.aria) || sc.Kind != StateKindBodyMode || sc.Value != value {
			t.Fatalf("%s got %+v, want {Aria, kind 4, value %d}", who, sc, value)
		}
	}
	f.send(t, f.connA, OpBerserk, (&CharacterNameRequest{Name: "Aria"}).Encode())
	expect("Aria", f.read(t, f.connA, f.rA), 1)
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpBerserkResult {
		t.Fatalf("Aria's second packet is %#04x, want the berserk result", p.Opcode)
	}
	expect("Bram", f.read(t, f.connB, f.rB), 1)
	expect("Aria", f.read(t, f.connA, f.rA), 0)
	expect("Bram", f.read(t, f.connB, f.rB), 0)
}

// berserkFixture is a two-player world whose zone change and revive end a
// running berserk (startDeadWorldFixtureZerk), with the berserk request
// served, Aria holding five orbs, and the end timer delayed by delay.
func berserkFixture(t *testing.T, delay time.Duration) (*deadWorldFixture, *berserk.Tracker) {
	t.Helper()
	old := berserkEndDelay
	berserkEndDelay = func(time.Time) time.Duration { return delay }
	t.Cleanup(func() { berserkEndDelay = old })
	zerk := berserk.NewTracker()
	f := startDeadWorldFixtureZerk(t, zerk, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			if p.Opcode != OpBerserk {
				return nil
			}
			return handleBerserk(ctx, sess, p, chars, hub, zerk)
		}
	})
	if err := f.chars.SetHwanCount(context.Background(), f.aria, 5); err != nil {
		t.Fatalf("SetHwanCount: %v", err)
	}
	return f, zerk
}

// expectBodyMode reads one packet and requires it to be Aria's 0x30bf kind 4
// with value.
func (f *deadWorldFixture) expectBodyMode(t *testing.T, who string, p *proto.Packet, value byte) {
	t.Helper()
	if p.Opcode != OpStateChange {
		t.Fatalf("%s got %#04x, want 0x30bf", who, p.Opcode)
	}
	sc, ok := DecodeStateChange(p.Data)
	if !ok || sc.ObjectID != uint32(f.aria) || sc.Kind != StateKindBodyMode || sc.Value != value {
		t.Fatalf("%s got %+v, want {Aria, kind 4, value %d}", who, sc, value)
	}
}

// goBerserk sends Aria's activation and reads its three packets.
func (f *deadWorldFixture) goBerserk(t *testing.T) {
	t.Helper()
	f.send(t, f.connA, OpBerserk, (&CharacterNameRequest{Name: "Aria"}).Encode())
	f.expectBodyMode(t, "Aria", f.read(t, f.connA, f.rA), 1)
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpBerserkResult {
		t.Fatalf("Aria's second packet is %#04x, want the berserk result", p.Opcode)
	}
	f.expectBodyMode(t, "Bram", f.read(t, f.connB, f.rB), 1)
}

// A second activation while berserk is refused before the orbs are looked at
// (READ: GObjPC_HandleBerserkMsg_0a7's error 3 on GetBodyMode() == 1), and
// nobody hears a body-mode change.
func TestBerserkActivationRefusedWhileBerserk(t *testing.T) {
	f, zerk := berserkFixture(t, time.Hour)
	f.goBerserk(t)
	zerk.SetCharges(f.aria, 5)
	f.send(t, f.connA, OpBerserk, (&CharacterNameRequest{Name: "Aria"}).Encode())
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpBerserkResult {
		t.Fatalf("Aria got %#04x, want the berserk result", p.Opcode)
	}
	r, err := DecodeBerserkResult(p.Data)
	if err != nil || r.Activated || !r.Active {
		t.Fatalf("second activation answered %+v (err %v), want refused while still active", r, err)
	}
	if zerk.Charges(f.aria) != 5 {
		t.Errorf("a refused activation spent the orbs: %d left", zerk.Charges(f.aria))
	}
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("Bram heard something for a refused activation")
	}
}

// A revive ends a running berserk (READ: GObjPC::Revive's SetBodyMode(2, ...)
// replaces body mode 1): the tracker is no longer active, the zone hears body
// mode 0 before the revive result, and the activation's own end timer stands
// down.
func TestReviveEndsBerserk(t *testing.T) {
	f, zerk := berserkFixture(t, 400*time.Millisecond)
	f.goBerserk(t)
	f.kill(t, f.aria, time.Now())
	f.send(t, f.connA, OpRevive, nil)
	f.expectBodyMode(t, "Aria", f.read(t, f.connA, f.rA), 0)
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpReviveResult {
		t.Fatalf("Aria's packet after the body mode is %#04x, want OpReviveResult", p.Opcode)
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpCharacterStatsResult {
		t.Fatalf("Aria's packet after the revive is %#04x, want the stats push", p.Opcode)
	}
	f.expectBodyMode(t, "Bram", f.read(t, f.connB, f.rB), 0)
	if zerk.Active(f.aria) {
		t.Fatal("still berserk after the revive")
	}
	time.Sleep(500 * time.Millisecond)
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Error("the ended activation's timer still pushed an end")
	}
}

// A zone change ends a running berserk (world entry's body mode READ; that a
// zone change is a re-entry INFERRED -- endBerserk): the mover hears body mode
// 0 in the new zone after its result, the old zone only its OpEntityLeft, and
// the activation's own end timer stands down.
func TestZoneChangeEndsBerserk(t *testing.T) {
	f, zerk := berserkFixture(t, 400*time.Millisecond)
	f.goBerserk(t)
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpChangeZoneResult {
		t.Fatalf("Aria got %#04x, want OpChangeZoneResult", p.Opcode)
	}
	f.expectBodyMode(t, "Aria", f.read(t, f.connA, f.rA), 0)
	if p := f.read(t, f.connB, f.rB); p.Opcode != OpEntityLeft {
		t.Fatalf("Bram got %#04x, want OpEntityLeft", p.Opcode)
	}
	if zerk.Active(f.aria) {
		t.Fatal("still berserk after the zone change")
	}
	time.Sleep(500 * time.Millisecond)
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Error("the ended activation's timer still pushed an end")
	}
}
