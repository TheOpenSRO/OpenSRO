package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/teleport"
	"github.com/OpenSRO/srrevamp/server/internal/world"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// Round 686: the town gates' return point (recall.go). The designate request
// and its reply are written here as the client builds and reads them -- a u16
// LE teleportdata id, and {1} or {2, u16 code} -- not through the server's
// codec (wire_shape_test.go's rule).

// The opcodes as literals, so a renumbering on one side shows up here.
const (
	wireRecallDesignate       uint16 = 0x0111
	wireRecallDesignateResult uint16 = 0x0112
)

// recallNetworkFixture is teleportFixture plus Constantinople's gate:
// GATE_EU (point 20, building 19554 STORE_EU_GATE at 105/79 = region 26959),
// shaped on the retail rows like the rest of the fixture (teleportdata.txt /
// teleportbuilding.txt read on the render box, round 686), and the ferry NPC
// point 40 offering interaction 7 so the structure test is what refuses it.
func recallNetworkFixture(t *testing.T) *teleport.Table {
	t.Helper()
	points := strings.Replace(teleportPointsCSV,
		"40,GATE_NPC_CH_FERRY,2011,SN_ZONE_22001,25000,500,0,500,10,0,0\n",
		"40,GATE_NPC_CH_FERRY,2011,SN_ZONE_22001,25000,500,0,500,10,1,0\n"+
			"20,GATE_EU,19554,SN_ZONE_22004,26959,950,84,1070,100,1,0\n", 1)
	buildings := teleportBuildingsCSV + "19554,STORE_EU_GATE,SN_NPC_EU_GATE,26959,700,200,886,xxx\n"
	tab, err := teleport.Read(strings.NewReader(points), strings.NewReader(teleportLinksCSV), strings.NewReader(buildings))
	if err != nil {
		t.Fatalf("teleport.Read on the recall fixture: %v", err)
	}
	return tab
}

// recallFixture is the dead world (Aria and Bram in jangan, -player-dead-state
// on) with the teleport handler and the return point both over the recall
// network, and -single-frame as given.
func recallFixture(t *testing.T, single bool) *deadWorldFixture {
	t.Helper()
	SetPlayerDeadState(true)
	t.Cleanup(func() { SetPlayerDeadState(false) })
	SetSingleFrame(single)
	t.Cleanup(func() { SetSingleFrame(false) })
	network := recallNetworkFixture(t)
	SetRecallNetwork(network)
	t.Cleanup(func() { SetRecallNetwork(nil) })
	return startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return TeleportHandler(chars, nil, hub, network, gm.ParseAccounts("alice"), false, nil, nil)
	})
}

// walkTo sends Aria's OpMove to region (rx, ry) local (lx, lz), named in the
// frame the hub keeps her in. It has no answer; the next request's answer
// comes after it.
func (f *deadWorldFixture) walkTo(t *testing.T, rx, ry int, lx, lz float64) {
	t.Helper()
	e, ok := f.hub.EntityByCharacterID(f.aria)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	fx, fy, ok := entityFrame(e.Zone)
	if !ok {
		t.Fatalf("Aria's zone %q has no frame", e.Zone)
	}
	x, z := worldmap.ToWorld(rx, ry, lx, lz, fx, fy)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(x), Z: float32(z)}).Encode())
}

// designate sends Aria's request for gate and returns the reply's bytes.
func (f *deadWorldFixture) designate(t *testing.T, gate uint16) []byte {
	t.Helper()
	req := make([]byte, 2)
	binary.LittleEndian.PutUint16(req, gate)
	f.send(t, f.connA, wireRecallDesignate, req)
	f.connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(f.rA, nil, nil)
	if err != nil {
		t.Fatalf("no answer to the designate request for gate %d: %v", gate, err)
	}
	if p.Opcode != wireRecallDesignateResult {
		t.Fatalf("the designate request answered %#04x, want %#04x", p.Opcode, wireRecallDesignateResult)
	}
	return p.Data
}

func (f *deadWorldFixture) appointed(t *testing.T) int64 {
	t.Helper()
	id, err := f.chars.AppointedTeleport(context.Background(), f.aria)
	if err != nil {
		t.Fatalf("AppointedTeleport: %v", err)
	}
	return id
}

// reviveAtReturnPoint kills Aria where she stands, asks for option 1 and
// returns the zone change it answers, draining the revive and the push.
func (f *deadWorldFixture) reviveAtReturnPoint(t *testing.T) *ChangeZoneResult {
	t.Helper()
	f.kill(t, f.aria, aiT0)
	f.send(t, f.connA, OpRevive, []byte{ReviveOptionReturnPoint})
	p := f.read(t, f.connA, f.rA)
	czr, err := DecodeChangeZoneResult(p.Data)
	if p.Opcode != OpChangeZoneResult || err != nil || !czr.OK {
		t.Fatalf("option 1 answered %#04x %+v (err %v), want the zone change to the return point", p.Opcode, czr, err)
	}
	for _, want := range []uint16{OpReviveResult, OpCharacterStatsResult} {
		if p := f.read(t, f.connA, f.rA); p.Opcode != want {
			t.Fatalf("after the zone change Aria received %#04x, want %#04x", p.Opcode, want)
		}
	}
	return czr
}

// wantArrivalAt checks a zone change lands in `zone` at region/local, named
// in the result's own frame (the same derivation as wantAt).
func wantArrivalAt(t *testing.T, czr *ChangeZoneResult, zone string, region, localX, localZ int) {
	t.Helper()
	if czr.Zone != zone {
		t.Fatalf("the return went to zone %q (frame %s), want %q", czr.Zone, czr.FrameRegion, zone)
	}
	wantAt(t, czr, region, localX, localZ)
}

// The user's case: a level-30 character designates Donwhang's gate there,
// dies in Jangan and takes option 1 -- and comes back at GATE_WC's point in
// donwhang (102/153 local 957, 1508), not at Jangan's. With -single-frame on
// and off (srrevamp-01 runs it). Before round 686 nothing answers the
// request.
func TestDesignatedGateIsWhereOptionOneReturns(t *testing.T) {
	for _, single := range []bool{false, true} {
		t.Run(map[bool]string{false: "own frames", true: "single frame"}[single], func(t *testing.T) {
			f := recallFixture(t, single)
			f.setLevel(t, f.aria, 30)
			f.goDonwhang(t)
			// GATE_WC's own point, 420 units from its building at 103/153
			// (962, 8): inside the structure's 800.
			f.walkTo(t, 102, 153, 957, 1508)
			if got := f.designate(t, 2); len(got) != 1 || got[0] != 1 {
				t.Fatalf("designating Donwhang's gate answered % x, want 01", got)
			}
			if id := f.appointed(t); id != 2095 {
				t.Fatalf("the stored return gate is %d, want STORE_WC_GATE 2095", id)
			}
			// Back to Jangan, and killed there.
			f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "jangan"}).Encode())
			if czr, err := DecodeChangeZoneResult(f.read(t, f.connA, f.rA).Data); err != nil || !czr.OK {
				t.Fatalf("the walk home answered %+v (err %v)", czr, err)
			}
			czr := f.reviveAtReturnPoint(t)
			wantArrivalAt(t, czr, "donwhang", 26265, 957, 1508)
			e, _ := f.hub.EntityByCharacterID(f.aria)
			if e.Life != world.LifeAlive || e.Zone != ZoneBucket("donwhang") {
				t.Errorf("after option 1 Aria is life %d in %q; want alive in %q", e.Life, e.Zone, ZoneBucket("donwhang"))
			}
			// Designating the same gate again is answered 1 and changes
			// nothing (GObjPC_HandleDesignateRecallMsg_059 skips the write, not the reply).
			f.walkTo(t, 102, 153, 957, 1508)
			if got := f.designate(t, 2); len(got) != 1 || got[0] != 1 {
				t.Fatalf("designating the same gate again answered % x, want 01", got)
			}
		})
	}
}

// A character that never designated a gate returns to its race's: China to
// GATE_CH's point in jangan (97/168 local 969, 1369 -- STORE_CH_GATE's), and
// Europe to GATE_EU's in constantinople (105/79 local 950, 1070 --
// STORE_EU_GATE's). The race is the character's own, through round 682's
// RaceOf of its Gender (characterCountry) -- no stub: Aria is made a Europe
// character with the store's own SetGender. Before round 686 both went to
// jangan's zone arrival.
func TestUndesignatedReturnPointIsTheRaceGate(t *testing.T) {
	for _, single := range []bool{false, true} {
		for _, race := range []struct {
			name    string
			gender  string
			country int
			zone    string
			region  int
			lx, lz  int
		}{
			{"china", character.GenderChinaWoman, equipment.CountryChina, "jangan", 25000, 969, 1369},
			{"europe", character.GenderEuropeMan, equipment.CountryEurope, "constantinople", 26959, 950, 1070},
		} {
			t.Run(race.name+map[bool]string{false: ", own frames", true: ", single frame"}[single], func(t *testing.T) {
				f := recallFixture(t, single)
				if err := f.chars.SetGender(context.Background(), f.aria, race.gender); err != nil {
					t.Fatal(err)
				}
				// The probe of the probe: the race really reads as wanted.
				if c, _ := f.chars.GetByID(context.Background(), f.aria); characterCountry(c) != race.country {
					t.Fatalf("a %s character reads country %d, want %d", race.gender, characterCountry(c), race.country)
				}
				f.setLevel(t, f.aria, 30)
				f.goDonwhang(t)
				if id := f.appointed(t); id != 0 {
					t.Fatalf("a new character's stored return gate is %d, want 0 (none)", id)
				}
				czr := f.reviveAtReturnPoint(t)
				wantArrivalAt(t, czr, race.zone, race.region, race.lx, race.lz)
			})
		}
	}
}

// NEGATIVE: the designation's refusals, each the code GObjPC_HandleDesignateRecallMsg_059 sends and
// none of them changing the stored gate. From Jangan's spawn: Donwhang's gate
// is three regions away (IsWithinInteractionRange's 3); Jangan's own gate
// building is 1,700 units off (4, too far); the ferry NPC's point is not a
// structure (3, the type mask 0x30, even offering interaction 7 here); a
// teleportdata id that is no point, and the walk-in point with no object
// (0, the object lookup's).
func TestDesignateIsRefusedOutOfRange(t *testing.T) {
	f := recallFixture(t, false)
	f.setLevel(t, f.aria, 30)
	// Jangan-local (100, 100): 1,700 units from STORE_CH_GATE (1254, 1374).
	f.walkTo(t, 97, 168, 100, 100)
	for _, c := range []struct {
		name string
		gate uint16
		want []byte
	}{
		{"Donwhang's gate from Jangan", 2, []byte{2, 3, 0}},
		{"Jangan's gate from across the town", 1, []byte{2, 4, 0}},
		{"the ferry NPC's point", 40, []byte{2, 3, 0}},
		{"no such point", 999, []byte{2, 0, 0}},
		{"a point with no object", 55, []byte{2, 0, 0}},
	} {
		if got := f.designate(t, c.gate); string(got) != string(c.want) {
			t.Errorf("%s answered % x, want % x", c.name, got, c.want)
		}
	}
	if id := f.appointed(t); id != 0 {
		t.Fatalf("after five refusals the stored return gate is %d, want 0", id)
	}
	// Beside the building it is accepted: the probe that the refusals above
	// are the range's and not a broken handler's.
	f.walkTo(t, 97, 168, 1200, 1374)
	if got := f.designate(t, 1); string(got) != "\x01" {
		t.Fatalf("Jangan's gate from 54 units answered % x, want 01", got)
	}
	if id := f.appointed(t); id != 2094 {
		t.Fatalf("the stored return gate is %d, want STORE_CH_GATE 2094", id)
	}
	// And a later request from too far changes nothing.
	f.walkTo(t, 97, 168, 100, 100)
	if got := f.designate(t, 1); string(got) != "\x02\x04\x00" {
		t.Errorf("from 1,700 units again: % x, want 02 04 00", got)
	}
	if id := f.appointed(t); id != 2094 {
		t.Errorf("a refused request changed the stored gate to %d", id)
	}
}

// A character that leaves the world dead is saved at ITS return point
// (savedPlace): the designated Donwhang gate. Needs -persist-position.
func TestLeavingDeadSavesTheDesignatedGate(t *testing.T) {
	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false) })
	f := recallFixture(t, false)
	f.setLevel(t, f.aria, 30)
	f.goDonwhang(t)
	f.walkTo(t, 102, 153, 957, 1508)
	if got := f.designate(t, 2); string(got) != "\x01" {
		t.Fatalf("designating answered % x", got)
	}
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "jangan"}).Encode())
	f.read(t, f.connA, f.rA)
	f.kill(t, f.aria, aiT0)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	WorldDisconnectHandler(f.hub, f.chars)(e.Session)
	ok := waitFor(t, 2*time.Second, func() bool {
		c, err := f.chars.GetByID(context.Background(), f.aria)
		if err != nil || c.Zone != "donwhang" {
			return false
		}
		fx, fy, _ := worldmap.ParseRegionLabel(c.Frame)
		x, z := worldmap.ToWorld(102, 153, 957, 1508, fx, fy)
		return math.Abs(c.PosX-x) < 0.01 && math.Abs(c.PosZ-z) < 0.01
	})
	if !ok {
		c, _ := f.chars.GetByID(context.Background(), f.aria)
		t.Errorf("Aria left dead in jangan and was saved in %q frame %q at (%v, %v), want GATE_WC's point in donwhang", c.Zone, c.Frame, c.PosX, c.PosZ)
	}
}

// With -player-dead-state off a kill respawns the character and moves it to
// its return point at once (returnAfterKill): the designated gate too.
func TestFlagOffRespawnGoesToTheDesignatedGate(t *testing.T) {
	f := recallFixture(t, false)
	SetPlayerDeadState(false)
	f.setLevel(t, f.aria, 30)
	f.goDonwhang(t)
	f.walkTo(t, 102, 153, 957, 1508)
	if got := f.designate(t, 2); string(got) != "\x01" {
		t.Fatalf("designating answered % x", got)
	}
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "jangan"}).Encode())
	f.read(t, f.connA, f.rA)
	returnAfterKill(context.Background(), f.chars, nil, f.hub, f.aria)
	p := f.read(t, f.connA, f.rA)
	czr, err := DecodeChangeZoneResult(p.Data)
	if p.Opcode != OpChangeZoneResult || err != nil || !czr.OK {
		t.Fatalf("the respawn's move answered %#04x %+v (err %v)", p.Opcode, czr, err)
	}
	wantArrivalAt(t, czr, "donwhang", 26265, 957, 1508)
}

// The codec, both ways, against the bytes the client reads (RecallNet).
func TestRecallDesignateWire(t *testing.T) {
	if OpRecallDesignate != wireRecallDesignate || OpRecallDesignateResult != wireRecallDesignateResult {
		t.Fatalf("opcodes %#04x/%#04x, want %#04x/%#04x", OpRecallDesignate, OpRecallDesignateResult, wireRecallDesignate, wireRecallDesignateResult)
	}
	if got := (&RecallDesignateResult{OK: true}).Encode(); string(got) != "\x01" {
		t.Errorf("ok encodes % x, want 01", got)
	}
	if got := (&RecallDesignateResult{Code: 4}).Encode(); string(got) != "\x02\x04\x00" {
		t.Errorf("code 4 encodes % x, want 02 04 00", got)
	}
	if _, err := DecodeRecallDesignateRequest([]byte{1}); err == nil {
		t.Error("a one-byte request decoded")
	}
	if r, err := DecodeRecallDesignateRequest([]byte{0x14, 0x00}); err != nil || r.Gate != 20 {
		t.Errorf("14 00 decoded to %+v (%v), want gate 20", r, err)
	}
	if RaceGate(equipment.CountryEurope) != "STORE_EU_GATE" || RaceGate(equipment.CountryChina) != "STORE_CH_GATE" || RaceGate(7) != "STORE_CH_GATE" {
		t.Error("the race gates are not FUN_0042bb20's: Europe STORE_EU_GATE, anything else STORE_CH_GATE")
	}
}

// Without a teleport network the return point keeps its pre-686 place for a
// China character -- jangan's zone arrival -- so a server with no
// -teleport-dir behaves as before.
func TestReturnPointWithoutANetworkIsTheZoneArrival(t *testing.T) {
	SetRecallNetwork(nil)
	chars := character.NewMemStore()
	c, _ := chars.Create(context.Background(), 1, "Aria")
	zone, bucket, pos, frame := returnPointFor(context.Background(), chars, c.ID)
	wb, wp, wf, _ := arrival(spawnZone)
	if zone != spawnZone || bucket != wb || pos != wp || frame != wf {
		t.Fatalf("no network: %q %q %+v %q, want spawnZone's arrival %q %q %+v %q", zone, bucket, pos, frame, spawnZone, wb, wp, wf)
	}
}

// Round 675's report again, with the return point now Jangan's gate rather
// than the zone arrival: killed in donwhang, back by option 1 at GATE_CH's
// point (285 units from its building), the gate still takes her to Donwhang
// -- with -single-frame on and off, with and without the landing report.
func TestTeleportFromJanganAfterReturningToTheRaceGate(t *testing.T) {
	SetPlayerDeadState(true)
	t.Cleanup(func() { SetPlayerDeadState(false) })
	for _, single := range []bool{false, true} {
		t.Run(map[bool]string{false: "own frames", true: "single frame"}[single], func(t *testing.T) {
			SetSingleFrame(single)
			t.Cleanup(func() { SetSingleFrame(false) })
			SetRecallNetwork(teleportFixture(t))
			t.Cleanup(func() { SetRecallNetwork(nil) })
			f, logs := deathTeleportFixture(t)
			f.setLevel(t, f.aria, 30)
			f.goDonwhang(t)
			czr := f.reviveAtReturnPoint(t)
			wantArrivalAt(t, czr, "jangan", 25000, 969, 1369)
			// A step from where she fell is dropped by the return guard; the
			// server keeps her at the gate point, inside the gate's 800.
			f.moveAria(t, 1500, 1500, false)
			e, _ := f.hub.EntityByCharacterID(f.aria)
			fx, fy, _ := entityFrame(e.Zone)
			_, _, lx, lz := worldmap.FromWorld(e.Pos.X, e.Pos.Z, fx, fy)
			if math.Abs(lx-969) > 0.5 || math.Abs(lz-1369) > 0.5 {
				t.Fatalf("the server has her at Jangan-local (%.1f, %.1f), want GATE_CH's (969, 1369)", lx, lz)
			}
			f.teleportToDonwhang(t, logs, "after the race gate return")
		})
	}
}

// failingChars is a store whose character reads fail (round 686's review).
type failingChars struct {
	*character.MemStore
}

func (f failingChars) GetByID(context.Context, int64) (*character.Character, error) {
	return nil, errors.New("synthetic read failure")
}

// captureLog points slog's default logger at a buffer for the test.
func captureLog(t *testing.T) *syncBuffer {
	t.Helper()
	buf := &syncBuffer{}
	was := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(was) })
	return buf
}

// A failed read is never silent (round 686's review). A character that
// cannot be read goes to its designated gate when that still reads -- here
// Donwhang's -- and otherwise to spawnZone's arrival, each with an error line
// naming its id; a designated gate that cannot be read falls to the race's
// gate with an error line.
func TestReturnPointLogsFailedReads(t *testing.T) {
	SetRecallNetwork(recallNetworkFixture(t))
	t.Cleanup(func() { SetRecallNetwork(nil) })
	ctx := context.Background()
	mem := character.NewMemStore()
	c, _ := mem.Create(ctx, 1, "Aria")

	logs := captureLog(t)
	zone, _, _, _ := returnPointFor(ctx, failingChars{MemStore: mem}, c.ID)
	if wz, _, _, _ := arrival(spawnZone); zone != spawnZone || wz == "" {
		t.Errorf("unreadable, nothing designated: zone %q, want spawnZone's arrival %q", zone, spawnZone)
	}
	for _, want := range []string{"reading the character failed", "could not be read; returning it to the zone arrival", fmt.Sprintf("character_id=%d", c.ID)} {
		if !strings.Contains(logs.String(), want) {
			t.Errorf("no %q in the log:\n%s", want, logs.String())
		}
	}

	if err := mem.SetAppointedTeleport(ctx, c.ID, 2095); err != nil {
		t.Fatal(err)
	}
	if zone, _, _, _ := returnPointFor(ctx, failingChars{MemStore: mem}, c.ID); zone != "donwhang" {
		t.Errorf("unreadable but designated Donwhang: zone %q, want donwhang", zone)
	}

	logs = captureLog(t)
	if zone, _, _, _ := returnPointFor(ctx, readableFailingGate{mem}, c.ID); zone != "jangan" {
		t.Errorf("a gate read failure for a China character: zone %q, want jangan (the race's gate)", zone)
	}
	if !strings.Contains(logs.String(), "reading the designated gate failed") || !strings.Contains(logs.String(), fmt.Sprintf("character_id=%d", c.ID)) {
		t.Errorf("the gate read failure was not logged:\n%s", logs.String())
	}
}

// readableFailingGate reads the character but not its designated gate.
type readableFailingGate struct{ *character.MemStore }

func (r readableFailingGate) AppointedTeleport(context.Context, int64) (int64, error) {
	return 0, errors.New("synthetic gate read failure")
}

// The designate refusals log at Debug, not Info (round 686's review): a
// client repeating a refused request must not flood an Info log.
func TestDesignateRefusalsLogAtDebug(t *testing.T) {
	buf := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelInfo}))
	SetPlayerDeadState(true)
	t.Cleanup(func() { SetPlayerDeadState(false) })
	network := recallNetworkFixture(t)
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return TeleportHandler(chars, nil, hub, network, gm.ParseAccounts("alice"), false, logger, nil)
	})
	for i := 0; i < 5; i++ {
		if got := f.designate(t, 999); string(got) != "\x02\x00\x00" {
			t.Fatalf("an unknown gate answered % x", got)
		}
	}
	if strings.Contains(buf.String(), "recall designate refused") {
		t.Errorf("refusals reached an Info log:\n%s", buf.String())
	}
}
