package session

import (
	"bytes"
	"context"
	"log/slog"
	"math"
	"strings"
	"sync"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 675: "after I died, the Jangan teleport stopped working". These tests
// walk the server's half of the report -- die, come back by each of the ways
// a character comes back, walk to Jangan's gate, ask for Donwhang -- with and
// without -single-frame, which opensro-01 runs (-full-map turns it on). They
// speak the wire and the fixtures only, so the same file runs against the
// tree before the round. They PASS there too: the live log (WORLD_ISSUES,
// round 675) shows the player's client never sent the request, and no server
// state left by a death refuses it. They pin that, so a later change to the
// return point, the return guard or the dead state cannot start refusing
// the gate unseen.

// syncBuffer is a bytes.Buffer safe for the session goroutines' logger.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// deathTeleportFixture is the dead-world fixture (Aria and Bram in jangan)
// with the teleport handler over the synthetic network (teleportFixture:
// GATE_CH 1 -> GATE_WC 2, Jangan's building at 97/168 (1254, 1374)), Aria a
// GM so the fee is waived, and the handler's log captured.
func deathTeleportFixture(t *testing.T) (*deadWorldFixture, *syncBuffer) {
	t.Helper()
	logs := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelInfo}))
	network := teleportFixture(t)
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return TeleportHandler(chars, nil, hub, network, gm.ParseAccounts("alice"), false, logger, nil)
	})
	return f, logs
}

// moveAria sends Aria's OpMove to Jangan-local (lx, lz), named in the frame
// the hub keeps her in -- what her client sends -- and waits until the
// session has handled it: the hub took it, or the return guard dropped it,
// as it would the client's.
func (f *deadWorldFixture) moveAria(t *testing.T, lx, lz float64, relocated bool) {
	t.Helper()
	e, ok := f.hub.EntityByCharacterID(f.aria)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	fx, fy, ok := entityFrame(e.Zone)
	if !ok {
		t.Fatalf("Aria's zone %q has no frame", e.Zone)
	}
	x, z := worldmap.ToWorld(97, 168, lx, lz, fx, fy)
	before := f.sees(f.aria, f.bram)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(x), Z: float32(z), Relocated: relocated}).Encode())
	// The move has no answer; a revive request has one, and the session
	// handles one packet at a time, so its answer means the move was handled.
	// A move across Bram's view line is first answered by his spawn or
	// despawn (round 737).
	f.send(t, f.connA, OpRevive, []byte{1})
	if p := f.readAfterAriaMoved(t, before); p.Opcode != OpReviveResult {
		t.Fatalf("the probe after a move answered %#04x, want OpReviveResult", p.Opcode)
	}
}

// teleportToDonwhang sends Aria's OpTeleportUse from Jangan's gate (1) to
// Donwhang (2) and wants the receipt and the arrival, with no refusal logged.
func (f *deadWorldFixture) teleportToDonwhang(t *testing.T, logs *syncBuffer, how string) {
	t.Helper()
	f.send(t, f.connA, OpTeleportUse, clientTeleportUse(1, 2))
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpTeleportResult {
		t.Fatalf("%s: the teleport answered %#04x, want OpTeleportResult", how, p.Opcode)
	}
	res, err := DecodeTeleportResult(p.Data)
	if err != nil || !res.OK {
		t.Fatalf("%s: the Jangan gate refused Donwhang: %+v (err %v); log:\n%s", how, res, err, logs.String())
	}
	p = f.read(t, f.connA, f.rA)
	czr, err := DecodeChangeZoneResult(p.Data)
	if p.Opcode != OpChangeZoneResult || err != nil || !czr.OK || czr.Zone != "donwhang" {
		t.Fatalf("%s: after the receipt Aria received %#04x %+v (err %v), want the arrival in donwhang", how, p.Opcode, czr, err)
	}
	if strings.Contains(logs.String(), "teleport refused") {
		t.Errorf("%s: a refusal was logged:\n%s", how, logs.String())
	}
}

// drainOptionOne reads what option 1 answers: the zone change to the return
// point, the revive result and the stats push.
func (f *deadWorldFixture) drainOptionOne(t *testing.T) {
	t.Helper()
	for _, want := range []uint16{OpChangeZoneResult, OpReviveResult, OpCharacterStatsResult} {
		if p := f.read(t, f.connA, f.rA); p.Opcode != want {
			t.Fatalf("option 1 answered %#04x, want %#04x", p.Opcode, want)
		}
		if want == OpChangeZoneResult {
			f.expectSpawnIfInView(t) // Bram, at the return point (round 737)
		}
	}
}

// Option 1 under -player-dead-state, the user's path: killed in donwhang,
// back at the return point in jangan, then the walk to the gate -- the
// client's landing report first, as World3D._place_at_region_local sends
// it, or a step straight past the gate with no landing report (the return
// guard drops that one, and the server measures from the landing, 508 units
// from the gate building -- inside its 800, IsWithinInteractionRange's
// structure limit). Each way, with -single-frame on
// and off, the gate takes her to Donwhang.
func TestTeleportFromJanganAfterReturnPointRevive(t *testing.T) {
	SetPlayerDeadState(true)
	t.Cleanup(func() { SetPlayerDeadState(false) })
	for _, single := range []bool{false, true} {
		for _, landingFirst := range []bool{true, false} {
			name := map[bool]string{false: "own frames", true: "single frame"}[single] +
				map[bool]string{true: ", landing reported", false: ", no landing report"}[landingFirst]
			t.Run(name, func(t *testing.T) {
				SetSingleFrame(single)
				t.Cleanup(func() { SetSingleFrame(false) })
				f, logs := deathTeleportFixture(t)
				f.setLevel(t, f.aria, 30)
				f.goDonwhang(t)
				f.kill(t, f.aria, aiT0)
				f.send(t, f.connA, OpRevive, []byte{ReviveOptionReturnPoint})
				f.drainOptionOne(t)
				if landingFirst {
					// Jangan's landing spot (worldmap.LandingSpot), relocated.
					f.moveAria(t, 1002, 1020, true)
				}
				// A step past the gate building (1254, 1374): 276 units from
				// it, but more than returnGuardRadius (400) on x from both
				// landing points (960, 960) and (1002, 1020) -- so without the
				// landing report the guard drops it and the server keeps her
				// at the landing, 508 units from the building.
				f.moveAria(t, 1500, 1500, false)
				e, _ := f.hub.EntityByCharacterID(f.aria)
				fx, fy, _ := entityFrame(e.Zone)
				_, _, lx, lz := worldmap.FromWorld(e.Pos.X, e.Pos.Z, fx, fy)
				wantX, wantZ := 1500.0, 1500.0
				if !landingFirst {
					wantX, wantZ = 960, 960
				}
				if math.Abs(lx-wantX) > 0.5 || math.Abs(lz-wantZ) > 0.5 {
					t.Fatalf("the server has her at Jangan-local (%.1f, %.1f), want (%.0f, %.0f)", lx, lz, wantX, wantZ)
				}
				f.teleportToDonwhang(t, logs, name)
			})
		}
	}
}

// Option 2 at level 10 under -player-dead-state: killed beside Jangan's gate
// and revived where she lies, she uses the gate at once.
func TestTeleportFromJanganAfterPresentPointRevive(t *testing.T) {
	SetPlayerDeadState(true)
	t.Cleanup(func() { SetPlayerDeadState(false) })
	for _, single := range []bool{false, true} {
		t.Run(map[bool]string{false: "own frames", true: "single frame"}[single], func(t *testing.T) {
			SetSingleFrame(single)
			t.Cleanup(func() { SetSingleFrame(false) })
			f, logs := deathTeleportFixture(t)
			f.setLevel(t, f.aria, PresentPointMaxLevel)
			f.moveAria(t, 1230, 1340, true)
			f.kill(t, f.aria, aiT0)
			f.send(t, f.connA, OpRevive, []byte{ReviveOptionPresentPoint})
			for _, want := range []uint16{OpReviveResult, OpCharacterStatsResult} {
				if p := f.read(t, f.connA, f.rA); p.Opcode != want {
					t.Fatalf("option 2 answered %#04x, want %#04x", p.Opcode, want)
				}
			}
			f.teleportToDonwhang(t, logs, "option 2")
		})
	}
}

// -player-dead-state off: a monster's kill respawns her at once and
// returnAfterKill takes her home with the return guard armed. The gate works
// from there.
func TestTeleportFromJanganAfterFlagOffReturn(t *testing.T) {
	SetPlayerDeadState(false)
	for _, single := range []bool{false, true} {
		t.Run(map[bool]string{false: "own frames", true: "single frame"}[single], func(t *testing.T) {
			SetSingleFrame(single)
			t.Cleanup(func() { SetSingleFrame(false) })
			f, logs := deathTeleportFixture(t)
			f.setLevel(t, f.aria, 30)
			f.goDonwhang(t)
			returnAfterKill(context.Background(), f.chars, nil, f.hub, f.aria)
			if p := f.read(t, f.connA, f.rA); p.Opcode != OpChangeZoneResult {
				t.Fatalf("the flag-off return answered %#04x, want OpChangeZoneResult", p.Opcode)
			}
			f.expectSpawnIfInView(t) // Bram, at the return point (round 737)
			f.moveAria(t, 1230, 1340, false)
			f.teleportToDonwhang(t, logs, "flag off")
		})
	}
}

// A refused teleport is logged at INFO with its reason and code -- the
// server's half of telling a refusal from a request that never came. Dead,
// she is refused ("you are dead", code 0) and the line says so.
func TestRefusedTeleportIsLogged(t *testing.T) {
	SetPlayerDeadState(true)
	t.Cleanup(func() { SetPlayerDeadState(false) })
	f, logs := deathTeleportFixture(t)
	f.kill(t, f.aria, aiT0)
	f.send(t, f.connA, OpTeleportUse, clientTeleportUse(1, 2))
	p := f.read(t, f.connA, f.rA)
	res, err := DecodeTeleportResult(p.Data)
	if p.Opcode != OpTeleportResult || err != nil || res.OK || res.Reason != deadRefusal {
		t.Fatalf("a dead teleport answered %#04x %+v (err %v), want the refusal %q", p.Opcode, res, err, deadRefusal)
	}
	line := logs.String()
	for _, want := range []string{"level=INFO", `msg="teleport refused"`, "account=alice", "code=0x0", `reason="you are dead"`} {
		if !strings.Contains(line, want) {
			t.Errorf("the refusal's log line lacks %s:\n%s", want, line)
		}
	}
}
