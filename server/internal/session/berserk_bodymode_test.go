package session

import (
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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
