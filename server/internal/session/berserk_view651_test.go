package session

// Round 651: a character that is berserk when another player arrives is drawn
// berserk by the arrival -- retail carries the body mode in every spawn's
// state block (the client's 0x9d1300 -> +0x470, applied by FUN_009d17e0;
// the server's GObjPC::FUN_004a9b70 writes chardata+3), and OpenSRO sends it
// as the 0x30bf kind 4 the client already applies (sendBodyModesInView).

import (
	"bufio"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// bodyModesUntilQuiet reads conn until it stays quiet for 300 ms and returns
// every kind-4 state change it saw, in order, as "id:value".
func (f *deadWorldFixture) bodyModesUntilQuiet(t *testing.T, conn net.Conn, r *bufio.Reader) []StateChange {
	t.Helper()
	var out []StateChange
	for {
		conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			return out
		}
		if p.Opcode != OpStateChange {
			continue
		}
		if sc, ok := DecodeStateChange(p.Data); ok && sc.Kind == StateKindBodyMode {
			out = append(out, *sc)
		}
	}
}

// warpAndBack moves Bram to donwhang and back into Aria's zone, reading each
// OpChangeZoneResult, and returns the body modes Bram heard after coming back.
func (f *deadWorldFixture) warpBramAndBack(t *testing.T) []StateChange {
	t.Helper()
	for _, zone := range []string{"donwhang", "jangan"} {
		f.send(t, f.connB, OpChangeZone, (&ChangeZoneRequest{Zone: zone}).Encode())
		for {
			p := f.read(t, f.connB, f.rB)
			if p.Opcode != OpChangeZoneResult {
				continue
			}
			r, err := DecodeChangeZoneResult(p.Data)
			if err != nil || !r.OK || r.Zone != zone {
				t.Fatalf("Bram's change to %s: %+v err %v", zone, r, err)
			}
			break
		}
		if zone == "donwhang" {
			f.bodyModesUntilQuiet(t, f.connB, f.rB)
		}
	}
	return f.bodyModesUntilQuiet(t, f.connB, f.rB)
}

// Aria goes berserk; Bram leaves the zone and comes back. Coming back, Bram is
// spawned Aria with body mode 1 in her record -- the arrival's view of her,
// where retail carries it (round 737; until then a 0x30BF followed the
// arrival list) -- and hears no body mode besides.
func TestRound651ArrivalSeesARunningBerserk(t *testing.T) {
	f, zerk := berserkFixture(t, 10*time.Second)
	f.goBerserk(t)
	f.bodyModesUntilQuiet(t, f.connA, f.rA)
	for _, zone := range []string{"donwhang", "jangan"} {
		f.send(t, f.connB, OpChangeZone, (&ChangeZoneRequest{Zone: zone}).Encode())
		if p := f.read(t, f.connB, f.rB); p.Opcode != OpChangeZoneResult {
			t.Fatalf("Bram's change to %s answered %#04x", zone, p.Opcode)
		}
		if zone == "donwhang" {
			f.bodyModesUntilQuiet(t, f.connB, f.rB)
		}
	}
	rec := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0]
	if rec.BodyMode != bodyModeBerserk {
		t.Fatalf("Bram, back beside a berserk Aria, spawned her with body mode %d; want %d", rec.BodyMode, bodyModeBerserk)
	}
	if got := f.bodyModesUntilQuiet(t, f.connB, f.rB); len(got) != 0 {
		t.Fatalf("and then heard body modes %+v; want none", got)
	}
	if !zerk.Active(f.aria) {
		t.Fatal("Aria is no longer berserk")
	}
}

// Once Aria's berserk has ended, an arrival hears no body mode for her.
func TestRound651ArrivalAfterTheEndHearsNothing(t *testing.T) {
	f, zerk := berserkFixture(t, 10*time.Second)
	f.goBerserk(t)
	endBerserk(f.hub, zerk, f.aria)
	f.bodyModesUntilQuiet(t, f.connA, f.rA)
	if got := f.warpBramAndBack(t); len(got) != 0 {
		t.Fatalf("Bram, back beside an Aria whose berserk ended, heard body modes %+v", got)
	}
}

// The mover's own berserk is not replayed to it: a zone change ends it
// (endBerserk), and the arrival's replay does not tell the mover "1" first.
func TestRound651TheMoverIsNotToldItsOwnBerserk(t *testing.T) {
	f, _ := berserkFixture(t, 10*time.Second)
	f.goBerserk(t)
	f.bodyModesUntilQuiet(t, f.connB, f.rB)
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpChangeZoneResult {
		t.Fatalf("Aria got %#04x, want OpChangeZoneResult", p.Opcode)
	}
	got := f.bodyModesUntilQuiet(t, f.connA, f.rA)
	if len(got) != 1 || got[0].ObjectID != uint32(f.aria) || got[0].Value != 0 {
		t.Fatalf("Aria, moved while berserk, heard body modes %+v; want only her own end (0)", got)
	}
}

// The x2 is the berserk's and goes with it: the same blow is doubled while
// the activation runs and plain once it has ended (the tracker's Boost is
// what the attack and skill paths apply, performAttack).
func TestRound651DamageDoublesOnlyWhileBerserk(t *testing.T) {
	zerk := berserk.NewTracker()
	const id = int64(651)
	zerk.EnsureSeeded(id, berserk.Orbs)
	if got := zerk.Boost(id, 40); got != 40 {
		t.Fatalf("before the activation a 40 blow is %d, want 40", got)
	}
	if !zerk.Activate(id) {
		t.Fatal("could not activate with five orbs")
	}
	if got := zerk.Boost(id, 40); got != 80 {
		t.Fatalf("while berserk a 40 blow is %d, want 80", got)
	}
	if !zerk.End(id) {
		t.Fatal("End found no berserk")
	}
	if got := zerk.Boost(id, 40); got != 40 {
		t.Fatalf("after the end a 40 blow is %d, want 40", got)
	}
}
