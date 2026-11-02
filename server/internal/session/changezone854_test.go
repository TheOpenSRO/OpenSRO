package session

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 854: OpChangeZone (0x0026, OpenSRO's own message) is a GM's tool.
// Before, any living player could warp to any zone with it -- the developer
// panel's zone box and town buttons, open in every build since round 849, or
// a crafted packet. The original has no message by which a client chooses its
// own zone: every legitimate move has a server-side reason, and those paths
// never go through handleChangeZone.

// closeZoneChange turns the suite's open OpChangeZone (TestMain) off for t.
func closeZoneChange(t *testing.T) {
	t.Helper()
	zoneChangeAnyone.Store(false)
	t.Cleanup(func() { zoneChangeAnyone.Store(true) })
}

// expectStayed fails t unless name's character is where it was.
func expectStayed(t *testing.T, rig *arrivalRig, name string, before world.Entity) {
	t.Helper()
	after, ok := rig.hub.EntityByCharacterID(rig.ids[name])
	if !ok {
		t.Fatalf("%s left the world", name)
	}
	if after.Zone != before.Zone || after.Pos != before.Pos {
		t.Fatalf("%s moved: %s %+v -> %s %+v", name, before.Zone, before.Pos, after.Zone, after.Pos)
	}
}

// A plain account's OpChangeZone is refused -- with or without a spot, to a
// town or a dungeon, even a malformed one -- and moves nothing: not the hub,
// not the other player's view of it.
func TestRound854NonGMChangeZoneIsRefused(t *testing.T) {
	closeZoneChange(t)
	rig := newArrivalRig(t)
	rig.listen("Bram", 100*time.Millisecond)
	rig.listen("Aria", 100*time.Millisecond)
	before, _ := rig.hub.EntityByCharacterID(rig.ids["Bram"])
	for _, req := range [][]byte{
		(&ChangeZoneRequest{Zone: "donwhang"}).Encode(),
		(&ChangeZoneRequest{Zone: "97/168", HasSpot: true, SpotX: 969, SpotZ: 1369}).Encode(),
		(&ChangeZoneRequest{Zone: "102/153", HasSpot: true, SpotX: 10, SpotZ: 10}).Encode(),
		(&ChangeZoneRequest{Zone: "dungeon/32769"}).Encode(),
		{0xff},
	} {
		rig.send("Bram", OpChangeZone, req)
		czr, err := DecodeChangeZoneResult(rig.until("Bram", OpChangeZoneResult).Data)
		if err != nil || czr.OK || czr.Reason != zoneChangeRefusal {
			t.Fatalf("Bram's OpChangeZone % x answered %+v %v; want refused %q", req, czr, err, zoneChangeRefusal)
		}
		expectStayed(t, rig, "Bram", before)
	}
	if h := rig.listen("Aria", 300*time.Millisecond); len(h.despawned) != 0 || len(h.spawned) != 0 {
		t.Fatalf("Aria saw Bram leave or arrive (%v / %v) after refused zone changes", h.despawned, h.spawned)
	}
	// Bram's GM /goto is refused by the GM gate, and moves nothing either.
	rig.send("Bram", OpGMCommand, (&GMCommandRequest{Name: "Bram", Line: "/goto donwhang"}).Encode())
	if res, err := DecodeGMCommandResult(rig.until("Bram", OpGMCommandResult).Data); err != nil || !res.Refused || res.IsGM || res.Zone != "" {
		t.Fatalf("Bram's /goto answered %+v %v; want the GM gate's refusal", res, err)
	}
	for _, p := range rig.listen("Bram", 300*time.Millisecond).packets {
		if p.Opcode == OpChangeZoneResult {
			t.Fatalf("a non-GM's /goto moved: % x", p.Data)
		}
	}
	expectStayed(t, rig, "Bram", before)
}

// A GM's OpChangeZone (the developer panel) still warps.
func TestRound854GMChangeZoneStillWorks(t *testing.T) {
	closeZoneChange(t)
	rig := newArrivalRig(t)
	rig.send("Aria", OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
	if err != nil || !czr.OK || czr.Zone != "donwhang" {
		t.Fatalf("Aria's OpChangeZone answered %+v %v; want donwhang", czr, err)
	}
	if e, _ := rig.hub.EntityByCharacterID(rig.ids["Aria"]); e.Zone != "donwhang" {
		t.Fatalf("the hub has Aria in %q, want donwhang", e.Zone)
	}
}

// A GM's /goto <zone> is the server's own warp now, guard or not: the reply
// names no zone for the client to ask for, and the OpChangeZoneResult that
// follows lands at the zone's landing -- the one a client-asked change landed
// at -- with the arrival held under the guard, labelled "gm /goto".
func TestRound854GMGotoZoneIsTheServersWarp(t *testing.T) {
	for _, guard := range []bool{false, true} {
		name := "guard off"
		if guard {
			name = "guard on"
		}
		t.Run(name, func(t *testing.T) {
			closeZoneChange(t)
			if guard {
				guardOn(t, time.Hour, 0)
			}
			rig := newArrivalRig(t)
			if guard {
				rig.bothIn()
			}
			rig.send("Aria", OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/goto donwhang"}).Encode())
			res, err := DecodeGMCommandResult(rig.until("Aria", OpGMCommandResult).Data)
			if err != nil || res.Refused || res.Zone != "" || res.HasPos {
				t.Fatalf("/goto donwhang answered %+v %v; want accepted, no zone or point for the client", res, err)
			}
			czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
			if err != nil || !czr.OK || czr.Zone != "donwhang" {
				t.Fatalf("/goto's arrival %+v %v; want donwhang", czr, err)
			}
			_, mid, _, _ := arrival("donwhang")
			want := changeZoneLanding(&ChangeZoneRequest{Zone: "donwhang"}, mid, true)
			if czr.X != float32(want.X) || czr.Z != float32(want.Z) {
				t.Fatalf("/goto landed at (%v, %v), want the zone's landing (%v, %v)", czr.X, czr.Z, want.X, want.Z)
			}
			e, _ := rig.hub.EntityByCharacterID(rig.ids["Aria"])
			if e.Zone != "donwhang" {
				t.Fatalf("the hub has Aria in %q, want donwhang", e.Zone)
			}
			if guard {
				arrivals.Lock()
				via := ""
				if a := arrivals.byChar[rig.ids["Aria"]]; a != nil {
					via = a.why
				}
				arrivals.Unlock()
				if via != "gm /goto" || !heldInHub(rig.hub, rig.ids["Aria"]) {
					t.Fatalf("held=%v via %q; want held via \"gm /goto\"", heldInHub(rig.hub, rig.ids["Aria"]), via)
				}
			}
		})
	}
}

// Every legitimate move still moves a plain account with OpChangeZone shut:
// the gate teleport (0x705A), /unstuck, the dead window's return point, the
// respawn after a kill (each Bram, not a GM, on the arrival rig), and in
// their own rigs the scrolls, a dungeon's gate and walk-in portal, a walk-in
// by a reported walk, the guild recall and the relog's arrival.
func TestRound854LegitimateMovesNeedNoZoneChange(t *testing.T) {
	cases := []struct {
		via string
		run func(rig *arrivalRig)
	}{
		{"gate teleport", func(rig *arrivalRig) {
			rig.send("Bram", OpTeleportUse, clientTeleportUse(1, 2))
		}},
		{"/unstuck", func(rig *arrivalRig) {
			rig.send("Bram", OpUnstuck, nil)
		}},
		{"death: return point", func(rig *arrivalRig) {
			deadStateForTest(rig.t, true)
			killForTest(rig, "Bram")
			rig.send("Bram", OpRevive, []byte{byte(ReviveOptionReturnPoint)})
		}},
		{"death: respawn after a kill", func(rig *arrivalRig) {
			returnAfterKill(context.Background(), rig.chars, rig.eq, rig.hub, rig.ids["Bram"])
		}},
	}
	for _, c := range cases {
		t.Run(c.via, func(t *testing.T) {
			closeZoneChange(t)
			// With the arrival guard on, as cmd/server runs (/unstuck is a
			// warp only then).
			guardOn(t, time.Hour, 0)
			rig := newArrivalRig(t)
			rig.bothIn()
			c.run(rig)
			czr, err := DecodeChangeZoneResult(rig.until("Bram", OpChangeZoneResult).Data)
			if err != nil || !czr.OK {
				t.Fatalf("%s: OpChangeZoneResult %+v %v; want the move", c.via, czr, err)
			}
			if !heldInHub(rig.hub, rig.ids["Bram"]) {
				t.Fatalf("%s: Bram not filed at the arrival", c.via)
			}
		})
	}
	// The relog's arrival: newArrivalRig's own OpEnterWorld, above, with the
	// gate shut. The rest, each with the gate shut.
	for _, sub := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"return and reverse return scrolls", TestRound786ScrollsAreHeld},
		{"return scroll then reverse to the recall point", TestRound778ReturnThenReverseToTheRecallPoint},
		{"gate teleport into a dungeon", TestRound773TeleportIntoADungeon},
		{"walk-in portal", TestRound773WalkInFiresOnEntering},
		{"walk-in by a reported walk", TestRound773WalkInFiresOnAReportedWalk},
		{"guild recall", TestGuild844RecallAnswer},
	} {
		t.Run(sub.name, func(t *testing.T) {
			closeZoneChange(t)
			sub.run(t)
		})
	}
}
