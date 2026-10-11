package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/gm"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// A synthetic teleport network shaped on the retail rows (round 575's export,
// docs/protocol/teleport_network.md): Jangan's gate GATE_CH (building 2094,
// 97/168 = region 25000, local 969,1369), Donwhang's GATE_WC (2095, 102/153 =
// 26265, 957,1508) and Samarkand's GATE_CA (19555, 106/108 = 27244,
// 270,1421), and their three buildings, each read on the render box's
// teleportdata.txt / teleportbuilding.txt this round; the three links carry
// Jangan's retail fees and rules. The rest is made up: a ferry point whose
// object is an NPC, a dungeon point (negative region), a point with no
// object, and the links to them.
const (
	teleportPointsCSV = "ID,Code,ObjectID,ZoneName,Region,X,Y,Z,Radius,Interaction7,Interaction9\n" +
		"1,GATE_CH,2094,SN_ZONE_22001,25000,969,0,1369,150,1,0\n" +
		"2,GATE_WC,2095,SN_ZONE_22002,26265,957,-80,1508,200,1,0\n" +
		"25,GATE_CA,19555,SN_ZONE_22005,27244,270,180,1421,120,1,0\n" +
		"40,GATE_NPC_CH_FERRY,2011,SN_ZONE_22001,25000,500,0,500,10,0,0\n" +
		"50,GATE_DUNGEON_FIXTURE,0,SN_ZONE_FIXTURE,-32000,100,0,100,10,0,0\n" +
		"55,GATE_WALKIN_FIXTURE,0,SN_ZONE_FIXTURE,26284,960,111,1662,50,0,0\n"
	teleportLinksCSV = "From,To,Fee,Rule1Type,Rule1Data1,Rule1Data2,Rule2Type,Rule2Data1,Rule2Data2," +
		"Rule3Type,Rule3Data1,Rule3Data2,Rule4Type,Rule4Data1,Rule4Data2,Rule5Type,Rule5Data1,Rule5Data2\n" +
		"1,2,5000,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"1,25,5000,1,1,110,2,0,0,0,0,0,0,0,0,0,0,0\n" +
		"2,1,5000,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"1,50,5000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"40,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"55,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n"
	teleportBuildingsCSV = "ID,Code,NameStrID,Region,X,Y,Z,Fortress\n" +
		"2094,STORE_CH_GATE,SN_NPC_CH_GATE,25000,1254,-6,1374,xxx\n" +
		"2095,STORE_WC_GATE,SN_NPC_WC_GATE,26521,962,-35,8,xxx\n" +
		"19555,STORE_CA_GATE,SN_NPC_CA_GATE,27499,1917,250,108,xxx\n"
)

func teleportFixture(t *testing.T) *teleport.Table {
	t.Helper()
	tab, err := teleport.Read(strings.NewReader(teleportPointsCSV), strings.NewReader(teleportLinksCSV), strings.NewReader(teleportBuildingsCSV))
	if err != nil {
		t.Fatalf("teleport.Read on the fixture: %v", err)
	}
	return tab
}

// teleportRig is one server with a teleport handler and the players logged in
// to it, each entered into the world at Jangan's spawn.
type teleportRig struct {
	t       *testing.T
	chars   *character.MemStore
	hub     *world.Hub
	players map[string]*teleportPlayer
}

type teleportPlayer struct {
	conn   net.Conn
	r      *bufio.Reader
	charID int64
}

type teleportRigOpts struct {
	network *teleport.Table
	gms     string // gm.ParseAccounts's list
	free    bool
	// level and gold of the first player, "alice"/"Aria"; a second player,
	// "bob"/"Bram", is logged in when observer is set.
	level    int
	gold     int64
	observer bool
}

func newTeleportRig(t *testing.T, o teleportRigOpts) *teleportRig {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub),
		TeleportHandler(chars, eq, hub, o.network, gm.ParseAccounts(o.gms), o.free, nil, nil))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(srvCtx)

	rig := &teleportRig{t: t, chars: chars, hub: hub, players: map[string]*teleportPlayer{}}
	type who struct {
		user, char string
		level      int
		gold       int64
	}
	people := []who{{"alice", "Aria", o.level, o.gold}}
	if o.observer {
		people = append(people, who{"bob", "Bram", 1, 0})
	}
	for _, w := range people {
		if _, err := accounts.Register(ctx, w.user, "pw"); err != nil {
			t.Fatalf("Register %s: %v", w.user, err)
		}
		acct, err := accounts.Authenticate(ctx, w.user, "pw")
		if err != nil {
			t.Fatalf("Authenticate %s: %v", w.user, err)
		}
		c, err := chars.Create(ctx, acct.ID, w.char)
		if err != nil {
			t.Fatalf("Create %s: %v", w.char, err)
		}
		if err := chars.SetLeveling(ctx, c.ID, w.level, 0, 0, c.Str, c.Int); err != nil {
			t.Fatalf("SetLeveling %s: %v", w.char, err)
		}
		if c.Gold > 0 {
			if err := chars.DeductGold(ctx, c.ID, c.Gold); err != nil {
				t.Fatalf("emptying %s's purse: %v", w.char, err)
			}
		}
		if w.gold > 0 {
			if err := chars.AddGold(ctx, c.ID, w.gold); err != nil {
				t.Fatalf("AddGold %s: %v", w.char, err)
			}
		}
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		p := &teleportPlayer{conn: conn, r: bufio.NewReader(conn), charID: c.ID}
		rig.players[w.char] = p
		lr, err := DecodeLoginResult(rig.roundTrip(w.char, OpLogin, (&LoginRequest{Username: w.user, Password: "pw"}).Encode()).Data)
		if err != nil || !lr.OK {
			t.Fatalf("%s login: %+v %v", w.user, lr, err)
		}
		ewr, err := DecodeEnterWorldResult(rig.roundTrip(w.char, OpEnterWorld, (&EnterWorldRequest{CharacterName: w.char}).Encode()).Data)
		if err != nil || !ewr.OK || ewr.Zone != spawnZone {
			t.Fatalf("%s enter world: %+v %v", w.char, ewr, err)
		}
	}
	if o.observer {
		// Aria hears Bram arrive (0x3015) and Bram is spawned Aria (a group,
		// round 737); drain both so each next packet is their own.
		a, b := rig.players["Aria"], rig.players["Bram"]
		expectPlayerSpawn(t, a.conn, a.r, b.charID)
		expectPlayerSpawn(t, b.conn, b.r, a.charID)
	}
	return rig
}

func (rig *teleportRig) roundTrip(char string, op uint16, data []byte) *proto.Packet {
	rig.t.Helper()
	p := rig.players[char]
	if err := proto.Write(p.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		rig.t.Fatalf("Write: %v", err)
	}
	resp := rig.next(char, 2*time.Second)
	if resp == nil {
		rig.t.Fatalf("%s: no reply to op 0x%04x", char, op)
	}
	return resp
}

// next reads char's next packet, or nil when none arrives within wait.
func (rig *teleportRig) next(char string, wait time.Duration) *proto.Packet {
	rig.t.Helper()
	p := rig.players[char]
	p.conn.SetReadDeadline(time.Now().Add(wait))
	resp, err := proto.Read(p.r, nil, nil)
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return nil
		}
		rig.t.Fatalf("%s: Read: %v", char, err)
	}
	return resp
}

// clientTeleportUse is the request exactly as the client builds it
// (TeleportNet.encode_use: two u16 LE ids), deliberately not through a
// server-side encoder -- wire_shape_test.go's rule.
func clientTeleportUse(gate, dest uint16) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint16(out[0:2], gate)
	binary.LittleEndian.PutUint16(out[2:4], dest)
	return out
}

// use sends Aria's OpTeleportUse and returns the decoded OpTeleportResult.
func (rig *teleportRig) use(gate, dest uint16) *TeleportResult {
	rig.t.Helper()
	resp := rig.roundTrip("Aria", OpTeleportUse, clientTeleportUse(gate, dest))
	if resp.Opcode != OpTeleportResult {
		rig.t.Fatalf("reply opcode 0x%04x, want OpTeleportResult 0x%04x", resp.Opcode, OpTeleportResult)
	}
	res, err := DecodeTeleportResult(resp.Data)
	if err != nil {
		rig.t.Fatalf("DecodeTeleportResult: %v", err)
	}
	return res
}

// arrival reads the OpChangeZoneResult that must follow an ok teleport.
func (rig *teleportRig) arrival() *ChangeZoneResult {
	rig.t.Helper()
	p := rig.next("Aria", 2*time.Second)
	if p == nil || p.Opcode != OpChangeZoneResult {
		rig.t.Fatalf("after the teleport's receipt: got %+v, want an OpChangeZoneResult", p)
	}
	czr, err := DecodeChangeZoneResult(p.Data)
	if err != nil || !czr.OK {
		rig.t.Fatalf("the arrival's OpChangeZoneResult: %+v %v", czr, err)
	}
	return czr
}

// noMove asserts nothing followed a refusal: no OpChangeZoneResult (or any
// other packet) for Aria, and the hub still has her in Jangan at the spawn.
func (rig *teleportRig) noMove() {
	rig.t.Helper()
	if p := rig.next("Aria", 300*time.Millisecond); p != nil {
		rig.t.Fatalf("a refused teleport was followed by op 0x%04x (%d bytes); want nothing", p.Opcode, len(p.Data))
	}
	e, ok := rig.hub.EntityByCharacterID(rig.players["Aria"].charID)
	if !ok || e.Zone != spawnZone || e.Pos != spawnPos {
		rig.t.Fatalf("after a refusal the hub has Aria at %+v (in the world: %v); want %q at %+v", e, ok, spawnZone, spawnPos)
	}
}

func (rig *teleportRig) gold() int64 {
	rig.t.Helper()
	c, err := rig.chars.GetByID(context.Background(), rig.players["Aria"].charID)
	if err != nil {
		rig.t.Fatalf("GetByID: %v", err)
	}
	return c.Gold
}

// wantAt checks a result's position against the destination point named in
// the frame the result gives -- derived with worldmap.ToWorld, never written
// as a literal (the plan's SIGN RULE). The convention ToWorld encodes, and
// AGENTS.md records: region y drives world X, region x drives world Z, and Z
// is mirrored.
func wantAt(t *testing.T, czr *ChangeZoneResult, region, localX, localZ int) {
	t.Helper()
	fx, fy, ok := worldmap.ParseRegionLabel(czr.FrameRegion)
	if !ok {
		t.Fatalf("the arrival's FrameRegion %q is not a region", czr.FrameRegion)
	}
	rx, ry := worldmap.RegionXY(region)
	x, z := worldmap.ToWorld(rx, ry, float64(localX), float64(localZ), fx, fy)
	if math.Abs(float64(czr.X)-x) > 0.01 || math.Abs(float64(czr.Z)-z) > 0.01 || czr.Y != float32(spawnPos.Y) {
		t.Fatalf("arrived at (%v, %v, %v); want the point %d/%d local (%d, %d) in frame %s = (%v, %v, %v)",
			czr.X, czr.Y, czr.Z, rx, ry, localX, localZ, czr.FrameRegion, x, spawnPos.Y, z)
	}
}

// (a) A level-30 character with 10,000 gold uses Jangan's gate to Donwhang:
// the link's 5,000 is charged, the receipt names SN_ZONE_22002, and the move is
// a zone change to "donwhang" -- Donwhang's own centre frame, 102/153 -- at
// GATE_WC's point, which the hub holds and the character left behind sees go.
func TestTeleportChargesTheFeeAndMovesToTheGatePoint(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 10000, observer: true})

	res := rig.use(1, 2)
	if !res.OK || res.Code != 0 || res.Fee != 5000 || res.Waiver != teleport.WaiverNone || res.Destination != "SN_ZONE_22002" {
		t.Fatalf("receipt %+v; want ok, fee 5000, no waiver, destination SN_ZONE_22002", res)
	}
	czr := rig.arrival()
	fx, fy, _ := worldmap.FrameFor("donwhang")
	if czr.Zone != "donwhang" || czr.FrameRegion != teleportTestLabel(fx, fy) {
		t.Fatalf("arrived in zone %q frame %q; want donwhang in its own frame %d/%d", czr.Zone, czr.FrameRegion, fx, fy)
	}
	wantAt(t, czr, 26265, 957, 1508)
	if len(czr.Others) != 0 {
		t.Fatalf("Donwhang should be empty, got Others %+v", czr.Others)
	}
	if g := rig.gold(); g != 5000 {
		t.Fatalf("gold after the teleport %d; want 10000 - 5000", g)
	}
	e, ok := rig.hub.EntityByCharacterID(rig.players["Aria"].charID)
	if !ok || e.Zone != "donwhang" || math.Abs(e.Pos.X-float64(czr.X)) > 0.01 || math.Abs(e.Pos.Z-float64(czr.Z)) > 0.01 {
		t.Fatalf("hub has Aria at %+v; want donwhang at the arrival (%v, %v)", e, czr.X, czr.Z)
	}
	// warpTo's broadcast tail: Bram, left in Jangan, sees her go (retail's
	// 0x3016, round 737).
	b := rig.players["Bram"]
	expectPlayerDespawn(t, b.conn, b.r, rig.players["Aria"].charID)
}

// (b) NEGATIVE: 4,000 gold is short of the 5,000 fee. The engine refuses
// 0x1c07 before it sets the teleport state (GObjPC::HandleTeleportUse,
// 0x513749), so nothing is charged and nothing moves: no OpChangeZoneResult
// follows, and the hub still has the character in Jangan. A handler that
// moved before charging fails here.
func TestTeleportRefusesAShortPurseAndDoesNotMove(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 4000})

	res := rig.use(1, 2)
	if res.OK || res.Code != teleport.ErrNotEnoughMoney || res.Fee != 0 || res.Reason == "" {
		t.Fatalf("result %+v; want refused 0x1c07 with a reason, nothing charged", res)
	}
	rig.noMove()
	if g := rig.gold(); g != 4000 {
		t.Fatalf("gold after a refused teleport %d; want 4000", g)
	}
}

// (c) The waivers, each a move with nothing charged: the engine's own below
// level 21, a GM account (the -gm-accounts gate) and -teleport-free.
func TestTeleportWaivers(t *testing.T) {
	cases := []struct {
		name  string
		opts  teleportRigOpts
		want  teleport.Waiver
		purse int64
	}{
		{"level 20, the engine's waiver", teleportRigOpts{level: 20, gold: 100}, teleport.WaiverLevel, 100},
		{"a GM account", teleportRigOpts{level: 30, gold: 100, gms: "alice"}, teleport.WaiverGM, 100},
		{"-teleport-free", teleportRigOpts{level: 30, gold: 100, free: true}, teleport.WaiverFlag, 100},
		{"a GM list without this account", teleportRigOpts{level: 30, gold: 10000, gms: "bob"}, teleport.WaiverNone, 5000},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.opts.network = teleportFixture(t)
			rig := newTeleportRig(t, tc.opts)
			res := rig.use(1, 2)
			wantFee := int64(0)
			if tc.want == teleport.WaiverNone {
				wantFee = 5000
			}
			if !res.OK || res.Fee != wantFee || res.Waiver != tc.want {
				t.Fatalf("receipt %+v; want ok, fee %d, waiver %d", res, wantFee, tc.want)
			}
			if czr := rig.arrival(); czr.Zone != "donwhang" {
				t.Fatalf("arrived in %q; want donwhang", czr.Zone)
			}
			if g := rig.gold(); g != tc.purse {
				t.Fatalf("gold %d; want %d", g, tc.purse)
			}
		})
	}
}

// The refusals, each with nothing charged and nothing moved.
func TestTeleportRefusals(t *testing.T) {
	cases := []struct {
		name       string
		opts       teleportRigOpts
		gate, dest uint16
		dead       bool
		code       uint16
	}{
		// Jangan -> Samarkand carries (1, 1, 110): level 111 is outside it.
		{"level 111 on a (1,1,110) link", teleportRigOpts{level: 111, gold: 10000}, 1, 25, false, teleport.ErrLevelRange},
		{"no link to that destination", teleportRigOpts{level: 30, gold: 10000}, 1, 99, false, teleportNoLink},
		{"no such gate", teleportRigOpts{level: 30, gold: 10000}, 99, 2, false, teleportNoLink},
		// A link exists (55 -> 2), but point 55 has no associated object -- a
		// walk-in portal's shape (GATE_JINSI_OUT) -- so nothing a player
		// talks to stands for it. (Until round 642 point 40, a ferry, was
		// refused here too; round 642's teleport_npc_test.go serves it.)
		{"a point with no object is not a gate", teleportRigOpts{level: 30, gold: 10000}, 55, 2, false, teleportNoLink},
		// A dungeon destination is served since round 773
		// (dungeon773_test.go); an instanced one is refused there.
		{"no teleport network loaded", teleportRigOpts{level: 30, gold: 10000}, 1, 2, false, 0},
		{"dead", teleportRigOpts{level: 30, gold: 10000}, 1, 2, true, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name != "no teleport network loaded" {
				tc.opts.network = teleportFixture(t)
			}
			rig := newTeleportRig(t, tc.opts)
			if tc.dead {
				if !rig.hub.SetLifeState(rig.players["Aria"].charID, world.LifeAlive, world.LifeDead, time.Now()) {
					t.Fatal("could not mark Aria dead")
				}
			}
			res := rig.use(tc.gate, tc.dest)
			if res.OK || res.Code != tc.code || res.Fee != 0 || res.Reason == "" {
				t.Fatalf("result %+v; want refused with code 0x%x and a reason", res, tc.code)
			}
			if tc.dead {
				// The hub keeps the dead character where it lay.
				if p := rig.next("Aria", 300*time.Millisecond); p != nil {
					t.Fatalf("a dead character's refusal was followed by op 0x%04x", p.Opcode)
				}
			} else {
				rig.noMove()
			}
			if g := rig.gold(); g != tc.opts.gold {
				t.Fatalf("gold %d after a refusal; want %d", g, tc.opts.gold)
			}
		})
	}
}

// Samarkand's gate GATE_CA stands in 106/108, beside the town's 106/107 centre
// (worldmap.ZoneCentre, round 569): the teleport arrives under "samarkand", in
// 106/107's frame, at the gate's point named in that frame -- one region over
// in world X, since region y drives world X.
func TestTeleportToSamarkandArrivesInTheTownsFrame(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 10000})
	res := rig.use(1, 25)
	if !res.OK || res.Fee != 5000 || res.Destination != "SN_ZONE_22005" {
		t.Fatalf("receipt %+v; want ok, fee 5000, SN_ZONE_22005", res)
	}
	czr := rig.arrival()
	fx, fy, _ := worldmap.FrameFor("samarkand")
	if czr.Zone != "samarkand" || czr.FrameRegion != teleportTestLabel(fx, fy) {
		t.Fatalf("arrived in zone %q frame %q; want samarkand in its centre's frame %d/%d", czr.Zone, czr.FrameRegion, fx, fy)
	}
	if czr.FrameRegion == "106/108" {
		t.Fatal("the frame is the gate's own region, not the town's centre")
	}
	wantAt(t, czr, 27244, 270, 1421)
}

// A teleport into Jangan lands at GATE_CH's point, not at Jangan's landing:
// the server sends the point, and the client keeps it (round 576's
// World3D._land_teleport_arrival).
func TestTeleportToJanganSendsTheGatePoint(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 10000})
	// Beside Donwhang's gate structure (building 2095, 103/153 local 962, 8):
	// the teleport measures the range from the requester (round 642's review).
	rig.standAt(26521, 962, 40)
	if res := rig.use(2, 1); !res.OK {
		t.Fatalf("receipt %+v; want ok", res)
	}
	czr := rig.arrival()
	if czr.Zone != "jangan" || czr.FrameRegion != "97/168" {
		t.Fatalf("arrived in %q frame %q; want jangan in 97/168", czr.Zone, czr.FrameRegion)
	}
	wantAt(t, czr, 25000, 969, 1369)
	if czr.X == float32(spawnPos.X) && czr.Z == float32(spawnPos.Z) {
		t.Fatal("the arrival is the zone's landing, not the gate's point")
	}
}

// Round 650, the tester's path: a teleport into Donwhang, then Donwhang's gate
// asked from where the arrival put her, with no move in between (the client
// sends none after landing). GATE_WC's point is in 102/153 and the gate
// structure (2095) in 103/153 at local (962, 8): IsWithinInteractionRange's
// offset crosses the region line (local z 8 + 1920 - 1508 = 420 on z, 5 on
// x), inside the structure's 800. NEGATIVE: 400 further south (the point's
// z - 400 in 102/153) the gate is 820 away, refused 4 with nothing charged.
func TestTeleportDonwhangGateFromItsArrival(t *testing.T) {
	tab := teleportFixture(t)
	rig := newTeleportRig(t, teleportRigOpts{network: tab, level: 30, gold: 20000})
	rig.standAt(25000, 1254, 1400) // beside Jangan's gate structure
	if res := rig.use(1, 2); !res.OK {
		t.Fatalf("Jangan -> Donwhang: %+v; want ok", res)
	}
	wantAt(t, rig.arrival(), 26265, 957, 1508)
	// No move: the hub still holds the arrival.
	if res := rig.use(2, 1); !res.OK {
		t.Fatalf("Donwhang -> Jangan from GATE_WC's point (420 from the gate across 102/153 -> 103/153): %+v; want ok", res)
	}
	wantAt(t, rig.arrival(), 25000, 969, 1369)
	// Back (GATE_CH's point is 285 from Jangan's gate), then 400 south.
	if res := rig.use(1, 2); !res.OK {
		t.Fatalf("Jangan -> Donwhang from GATE_CH's point: %+v; want ok", res)
	}
	wantAt(t, rig.arrival(), 26265, 957, 1508)
	rig.standAt(26265, 957, 1508-400)
	gold := rig.gold()
	if res := rig.use(2, 1); res.OK || res.Code != teleport.ErrTooFar {
		t.Fatalf("Donwhang's gate from 820 away: %+v; want refused with code %d", res, teleport.ErrTooFar)
	}
	if g := rig.gold(); g != gold {
		t.Fatalf("gold %d after a refusal; want %d", g, gold)
	}
}

// Under -single-frame the arrival is the same point named in the one world
// frame (97/168) and kept in the world bucket, as every framed zone is.
func TestTeleportUnderSingleFrame(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 10000})
	if res := rig.use(1, 2); !res.OK {
		t.Fatalf("receipt %+v; want ok", res)
	}
	czr := rig.arrival()
	want := teleportTestLabel(worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
	if czr.Zone != "donwhang" || czr.FrameRegion != want {
		t.Fatalf("arrived in %q frame %q; want donwhang in %s", czr.Zone, czr.FrameRegion, want)
	}
	wantAt(t, czr, 26265, 957, 1508)
	if e, ok := rig.hub.EntityByCharacterID(rig.players["Aria"].charID); !ok || e.Zone != worldmap.WorldBucket {
		t.Fatalf("hub has Aria in %q; want the world bucket", e.Zone)
	}
}

// The result's bytes, built by hand in the layout the client decodes
// (client/scripts/net/teleport.gd's decode_result; teleport_test.gd builds the
// same fixture): u8 ok, u16 code, u8 waiver, u64 fee, then the destination and
// the reason as u16-prefixed strings. And a request that is not exactly four
// bytes is refused.
func TestTeleportWireShapes(t *testing.T) {
	want := []byte{1, 0, 0, 3, 0x88, 0x13, 0, 0, 0, 0, 0, 0}
	want = append(want, 13, 0)
	want = append(want, "SN_ZONE_22002"...)
	want = append(want, 0, 0)
	got := (&TeleportResult{OK: true, Waiver: teleport.WaiverFlag, Fee: 5000, Destination: "SN_ZONE_22002"}).Encode()
	if string(got) != string(want) {
		t.Fatalf("Encode gave % x\nwant        % x", got, want)
	}
	back, err := DecodeTeleportResult(got)
	if err != nil || !back.OK || back.Fee != 5000 || back.Waiver != teleport.WaiverFlag || back.Destination != "SN_ZONE_22002" {
		t.Fatalf("round trip %+v %v", back, err)
	}
	refusal := (&TeleportResult{Code: teleport.ErrLevelRange, Reason: "r"}).Encode()
	if refusal[0] != 0 || binary.LittleEndian.Uint16(refusal[1:3]) != 0x1c15 {
		t.Fatalf("a refusal encodes % x; want ok 0 and code 15 1c", refusal)
	}
	for n := 0; n < len(got); n++ {
		if _, err := DecodeTeleportResult(got[:n]); err == nil {
			t.Fatalf("a result cut to %d bytes decoded", n)
		}
	}
	req, err := DecodeTeleportUseRequest(clientTeleportUse(1, 2))
	if err != nil || req.Gate != 1 || req.Destination != 2 {
		t.Fatalf("the client's request decodes to %+v %v; want gate 1 destination 2", req, err)
	}
	for _, bad := range [][]byte{nil, {1, 0, 2}, {1, 0, 2, 0, 0}} {
		if _, err := DecodeTeleportUseRequest(bad); err == nil {
			t.Fatalf("a %d-byte request decoded", len(bad))
		}
	}
}

// teleportTestLabel spells a region "x/y", as frameFor does.
func teleportTestLabel(x, y int) string { return fmt.Sprintf("%d/%d", x, y) }

// standAt moves Aria to region-local (lx, lz) of region `region`, named in the
// frame of the zone the hub keeps her in, the way the client reports a
// position (OpMove, relocated), and waits until the hub holds it. Round 642's
// review: the teleport measures the interaction range from there.
func (rig *teleportRig) standAt(region int, lx, lz float64) {
	rig.t.Helper()
	id := rig.players["Aria"].charID
	e, ok := rig.hub.EntityByCharacterID(id)
	if !ok {
		rig.t.Fatal("Aria is not in the world")
	}
	fx, fy, ok := entityFrame(e.Zone)
	if !ok {
		rig.t.Fatalf("zone %q has no frame", e.Zone)
	}
	rx, ry := worldmap.RegionXY(region)
	x, z := worldmap.ToWorld(rx, ry, lx, lz, fx, fy)
	if err := proto.Write(rig.players["Aria"].conn, &proto.Packet{Opcode: OpMove,
		Data: (&MoveRequest{X: float32(x), Z: float32(z), Relocated: true}).Encode()}, nil, nil); err != nil {
		rig.t.Fatalf("Write OpMove: %v", err)
	}
	for i := 0; i < 200; i++ {
		if e, _ := rig.hub.EntityByCharacterID(id); math.Abs(e.Pos.X-float64(float32(x))) < 0.01 && math.Abs(e.Pos.Z-float64(float32(z))) < 0.01 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	rig.t.Fatalf("the hub never took Aria's move to %d/%d (%v, %v)", rx, ry, lx, lz)
}
