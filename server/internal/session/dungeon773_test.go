package session

import (
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The fixture's dungeon point 50 (region -32000, i.e. 0x8300) stands at
// dungeon (100, 0, 100). The walk-in fixture adds a zone for point 55 -- a
// walk-in portal's shape, one link to Donwhang's gate -- placed in that
// dungeon at (100, 0, 150), 50 units from the arrival.
const dungeonFixtureZone = "dungeon/33536"

func dungeonWalkInFixture(t *testing.T) *teleport.Table {
	t.Helper()
	tab := teleportFixture(t)
	if err := tab.ReadWalkIns(strings.NewReader("Code,PointID,Region,X,Y,Z\nGATE_WALKIN_FIXTURE,55,-32000,100,0,150\n")); err != nil {
		t.Fatalf("ReadWalkIns: %v", err)
	}
	return tab
}

// A teleport to a dungeon point lands in the dungeon's own zone, bucket and
// frame, at the point's dungeon-space x, y and z mirrored (dx, dy, -dz).
func TestRound773TeleportIntoADungeon(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 10000})
	res := rig.use(1, 50)
	if !res.OK {
		t.Fatalf("teleport into the dungeon refused: %+v", res)
	}
	czr := rig.arrival()
	if czr.Zone != dungeonFixtureZone || czr.FrameRegion != dungeonFixtureZone {
		t.Fatalf("arrived in zone %q frame %q; want %q in its own frame", czr.Zone, czr.FrameRegion, dungeonFixtureZone)
	}
	if czr.X != 100 || czr.Y != 0 || czr.Z != -100 {
		t.Fatalf("arrived at (%v, %v, %v); want (100, 0, -100)", czr.X, czr.Y, czr.Z)
	}
	e, ok := rig.hub.EntityByCharacterID(rig.players["Aria"].charID)
	if !ok || e.Zone != dungeonFixtureZone {
		t.Fatalf("hub has Aria in %q; want %q", e.Zone, dungeonFixtureZone)
	}
}

// Under -single-frame too a dungeon keeps its own bucket and frame.
func TestRound773DungeonArrivalIgnoresTheOneWorld(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	bucket, _, frame, oneWorld := arrival("dungeon/32769")
	if bucket != "dungeon/32769" || frame != "dungeon/32769" || oneWorld {
		t.Fatalf("arrival = %q %q %v", bucket, frame, oneWorld)
	}
	if ZoneBucket("dungeon/32769") != "dungeon/32769" {
		t.Fatal("a dungeon was merged into the one world's bucket")
	}
}

// Only the open world's dungeons are served: a point in another game world
// (the job temple's 60, the Medusa rooms') stays refused.
func TestRound773InstancedDungeonsStayRefused(t *testing.T) {
	if _, _, _, _, ok := teleportArrival(teleport.Point{Region: -32752, X: 1, Z: 1, WorldID: 60}); ok {
		t.Fatal("an instanced dungeon point was given an arrival")
	}
	zone, bucket, pos, frame, ok := teleportArrival(teleport.Point{Region: -32767, X: 1011, Y: 3, Z: -862, WorldID: 1})
	if !ok || zone != "dungeon/32769" || bucket != zone || frame != zone || pos != (world.Position{X: 1011, Y: 3, Z: 862}) {
		t.Fatalf("Donwhang cave arrival = %q %q %+v %q %v", zone, bucket, pos, frame, ok)
	}
}

// The entry of each dungeon: a link's destination from the open field first
// (Donwhang's GATE_DUNGEON_DH_OUT), else the lowest-id point a link lands on.
func TestRound773DungeonEntries(t *testing.T) {
	pts := "ID,Code,ObjectID,ZoneName,Region,X,Y,Z,Radius,Interaction7,Interaction9,WorldID\n" +
		"10,GATE_DUNGEON_DH_OUT,0,Z,-32767,1011,0,-862,90,0,0,1\n" +
		"11,GATE_DUNGEON_DH_IN,0,Z,27027,1814,452,1834,90,0,0,1\n" +
		"5,DH_INSIDE,0,Z,-32767,5,0,5,90,0,0,1\n" +
		"6,DH_INSIDE2,0,Z,-32767,6,0,6,90,0,0,1\n" +
		"57,TOMB_B1,0,Z,-32761,2,223,6495,70,0,0,1\n" +
		"59,TOMB_B2,0,Z,-32762,-13674,0,5596,70,0,0,1\n" +
		"60,TOMB_B2b,0,Z,-32762,-3858,0,5592,70,0,0,1\n" +
		"173,TEMPLE,0,Z,-32752,-4027,58,-3717,10,0,0,60\n"
	links := "From,To,Fee,Rule1Type,Rule1Data1,Rule1Data2,Rule2Type,Rule2Data1,Rule2Data2," +
		"Rule3Type,Rule3Data1,Rule3Data2,Rule4Type,Rule4Data1,Rule4Data2,Rule5Type,Rule5Data1,Rule5Data2\n" +
		"6,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"11,10,0,1,50,999,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"57,60,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"57,59,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"11,173,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n"
	tab, err := teleport.Read(strings.NewReader(pts), strings.NewReader(links), strings.NewReader("ID,Code,NameStrID,Region,X,Y,Z,Fortress\n"))
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	InstallDungeonEntries(tab)
	t.Cleanup(func() { InstallDungeonEntries(nil) })
	if p, ok := dungeonEntry(0x8001); !ok || p != (world.Position{X: 1011, Y: 0, Z: 862}) {
		t.Fatalf("Donwhang cave entry %+v %v; want GATE_DUNGEON_DH_OUT", p, ok)
	}
	if p, ok := dungeonEntry(-32762); !ok || p.X != -13674 {
		t.Fatalf("tomb B2 entry %+v %v; want the lowest-id point landed on, 59", p, ok)
	}
	if ServedDungeon(0x8010) {
		t.Fatal("the job temple (WorldID 60) is served")
	}
	if got := ServedDungeons(); len(got) != 2 || got[0] != 0x8001 || got[1] != 0x8006 {
		t.Fatalf("ServedDungeons = %x", got)
	}
	bucket, pos, frame, _ := arrival("dungeon/32769")
	if bucket != "dungeon/32769" || frame != bucket || pos != (world.Position{X: 1011, Y: 0, Z: 862}) {
		t.Fatalf("a zone change to the cave lands %q %q %+v; want its entry", bucket, frame, pos)
	}
}

// Region-coded positions in a dungeon are the rid and dungeon space: the
// stop (0xB023) and the echo's source (i32 x10, round 773's OURS form).
func TestRound773DungeonWireForms(t *testing.T) {
	zone := "dungeon/32769"
	pos := world.Position{X: 1011.5, Y: -4, Z: 862.25}
	region, lx, lz := regionLocalOf(zone, pos)
	if region != 0x8001 || lx != 1011.5 || lz != -862.25 {
		t.Fatalf("regionLocalOf = %#x %v %v", region, lx, lz)
	}
	if x, z := worldOfRegionLocal(zone, region, lx, lz); x != pos.X || z != pos.Z {
		t.Fatalf("worldOfRegionLocal = %v %v", x, z)
	}
	st, ok := DecodeMoveStop(encodeMoveStop(world.Entity{CharacterID: 7, Zone: zone, Pos: pos}))
	if !ok || st.Region != 0x8001 || st.X != 1011.5 || st.Y != -4 || st.Z != -862.25 {
		t.Fatalf("0xB023 %+v", st)
	}
	m := &proto.Movement{Kind: 1, Region: 0x8001, X: 1100, Y: -4, Z: -900}
	echo, ok := DecodeMoveEcho(encodeMoveEcho(7, m.Encode(), region, pos, lx, lz))
	if !ok || echo.SrcRegion != 0x8001 || echo.SrcX != 10115 || echo.SrcZ != -8622 || echo.SrcY != -4 {
		t.Fatalf("0xB021 %+v", echo)
	}
	if echo.Move.Region != 0x8001 || echo.Move.X != 1100 || echo.Move.Z != -900 {
		t.Fatalf("0xB021 movement %+v", echo.Move)
	}
	pr, x, y, z, ok := partyPosition(world.Entity{Zone: zone, Pos: pos})
	if !ok || pr != 0x8001 || x != 1011 || y != -4 || z != -862 {
		t.Fatalf("partyPosition = %#x %d %d %d %v", pr, x, y, z, ok)
	}
}

// moveIn sends Aria's 0x7021 to dungeon-space (x, y, z) of rid and returns
// the echo, or nil when none comes.
func (rig *teleportRig) moveIn(rid uint16, x, y, z int32) *MoveEcho {
	rig.t.Helper()
	m := &proto.Movement{Kind: 1, Region: rid, X: x, Y: y, Z: z}
	p := rig.players["Aria"]
	if err := proto.Write(p.conn, &proto.Packet{Opcode: proto.OpMovementRequest, Data: m.Encode()}, nil, nil); err != nil {
		rig.t.Fatalf("Write: %v", err)
	}
	for {
		resp := rig.next("Aria", 500*time.Millisecond)
		if resp == nil {
			return nil
		}
		if resp.Opcode == proto.OpMovementResponse {
			e, ok := DecodeMoveEcho(resp.Data)
			if !ok {
				rig.t.Fatalf("undecodable echo % x", resp.Data)
			}
			return &e
		}
	}
}

// A dungeon's 0x7021 is taken in that dungeon only, and its echo carries the
// dungeon form; a field destination or another dungeon's is refused.
func TestRound773MovingInADungeon(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: teleportFixture(t), level: 30, gold: 10000})
	if res := rig.use(1, 50); !res.OK {
		t.Fatalf("teleport refused: %+v", res)
	}
	rig.arrival()
	if e := rig.moveIn(0x8301, 120, 0, 100); e != nil {
		t.Fatalf("another dungeon's destination was taken: %+v", e)
	}
	e := rig.moveIn(0x8300, 120, 0, 100)
	if e == nil {
		t.Fatal("no echo for a destination in the character's own dungeon")
	}
	if e.SrcRegion != 0x8300 || e.SrcX != 1000 || e.SrcZ != 1000 {
		t.Fatalf("echo source %#x (%d, %d); want 0x8300 (1000, 1000)", e.SrcRegion, e.SrcX, e.SrcZ)
	}
	got, _ := rig.hub.EntityByCharacterID(rig.players["Aria"].charID)
	if got.Move == nil || got.Move.Dest != (world.Position{X: 120, Y: 0, Z: -100}) {
		t.Fatalf("leg %+v; want to world (120, 0, -100)", got.Move)
	}
	// A field-form destination from inside a dungeon.
	field := &proto.Movement{Kind: 1, Region: 0x6168, LocalX: 10, LocalZ: 10}
	if err := proto.Write(rig.players["Aria"].conn, &proto.Packet{Opcode: proto.OpMovementRequest, Data: field.Encode()}, nil, nil); err != nil {
		t.Fatal(err)
	}
	for {
		p := rig.next("Aria", 400*time.Millisecond)
		if p == nil {
			break
		}
		if p.Opcode == proto.OpMovementResponse {
			t.Fatalf("a field destination from a dungeon was taken")
		}
	}
}

// A walk-in zone fires when the mover's path enters it -- the link's
// restrictions pass, no fee is taken -- and the character arrives at the
// link's destination with a teleport receipt ahead of the zone change. One
// that arrived standing in the zone would not fire until it walked out.
func TestRound773WalkInFiresOnEntering(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: dungeonWalkInFixture(t), level: 30, gold: 10000})
	if res := rig.use(1, 50); !res.OK {
		t.Fatalf("teleport refused: %+v", res)
	}
	rig.arrival()
	goldBefore := rig.gold()
	// From (100, 0, 100) to (100, 0, 200): through the zone's centre at
	// (100, 0, 150).
	if e := rig.moveIn(0x8300, 100, 0, 200); e == nil {
		t.Fatal("no echo")
	}
	deadline := time.Now().Add(5 * time.Second)
	var receipt *TeleportResult
	for time.Now().Before(deadline) {
		p := rig.next("Aria", time.Second)
		if p == nil {
			continue
		}
		if p.Opcode == OpTeleportResult {
			r, err := DecodeTeleportResult(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			receipt = r
			break
		}
	}
	if receipt == nil || !receipt.OK || receipt.Fee != 0 {
		t.Fatalf("walk-in receipt %+v; want ok, no fee", receipt)
	}
	czr := rig.arrival()
	if czr.Zone != "donwhang" {
		t.Fatalf("walked in to %q; want donwhang (the link 55 -> 2)", czr.Zone)
	}
	if g := rig.gold(); g != goldBefore {
		t.Fatalf("gold %d after a walk-in; want %d (no fee)", g, goldBefore)
	}
}

// The zone's geometry: a path through it is crossed, one beside it not, and
// a dungeon zone keeps its height band.
func TestRound773WalkInGeometry(t *testing.T) {
	z := walkInZone{x: 100, y: 0, z: -150, dungeon: true}
	if !z.crossed(world.Position{X: 100, Z: -100}, world.Position{X: 100, Z: -200}) {
		t.Fatal("a path through the centre was not crossed")
	}
	if z.crossed(world.Position{X: 130, Z: -100}, world.Position{X: 130, Z: -200}) {
		t.Fatal("a path 30 units beside the centre was crossed")
	}
	if z.crossed(world.Position{X: 100, Y: 300, Z: -100}, world.Position{X: 100, Y: 300, Z: -200}) {
		t.Fatal("a path a floor above was crossed")
	}
	if !z.within(world.Position{X: 110, Y: 20, Z: -150}) || z.within(world.Position{X: 116, Z: -150}) {
		t.Fatal("within")
	}
}

// An NPC of a served dungeon is filed in the dungeon's bucket at its
// dungeon-space point mirrored; one of a dungeon not served is left out.
func TestRound773NPCsInADungeon(t *testing.T) {
	tab := teleportFixture(t)
	InstallDungeonEntries(tab)
	t.Cleanup(func() { InstallDungeonEntries(nil) })
	in := npcspawn.NPC{Record: npcspawn.Record{RefID: 2001, UID: npcspawn.UIDBase + 1, Region: 0x8300, X: 100, Y: 5, Z: 100}}
	out := npcspawn.NPC{Record: npcspawn.Record{RefID: 2002, UID: npcspawn.UIDBase + 2, Region: 0x8301, X: 100, Z: 100}}
	if n := InstallNPCs([]npcspawn.NPC{in, out}, nil); n != 1 {
		t.Fatalf("filed %d NPCs; want the served dungeon's one", n)
	}
	t.Cleanup(func() { InstallNPCs(nil, nil) })
	if n := NPCsInWindow(combat.CellOf(dungeonFixtureZone, 100, -100)); n != 1 {
		t.Fatalf("%d NPC(s) in the dungeon's window at its point; want 1", n)
	}
}

// A walk the client reports itself (OpMove: an older client's walked
// positions, a stop, the QA walk) crosses walk-in zones too -- the mover pass
// sees only the server's own movers -- while a placement (Relocated) into one
// does not fire it.
func TestRound773WalkInFiresOnAReportedWalk(t *testing.T) {
	SetTrustClientPositions(true)
	t.Cleanup(func() { SetTrustClientPositions(false) })
	rig := newTeleportRig(t, teleportRigOpts{network: dungeonWalkInFixture(t), level: 30, gold: 10000})
	if res := rig.use(1, 50); !res.OK {
		t.Fatalf("teleport refused: %+v", res)
	}
	rig.arrival()
	conn := rig.players["Aria"].conn
	// Placed on the zone's centre (world (100, 0, -150)): no fire.
	if err := proto.Write(conn, &proto.Packet{Opcode: OpMove, Data: (&MoveRequest{X: 100, Z: -150, Relocated: true}).Encode()}, nil, nil); err != nil {
		t.Fatal(err)
	}
	for p := rig.next("Aria", 400*time.Millisecond); p != nil; p = rig.next("Aria", 400*time.Millisecond) {
		if p.Opcode == OpTeleportResult {
			t.Fatal("a placement into the zone fired it")
		}
	}
	// Out of it, then walked back through it.
	for _, z := range []float32{-200, -100} {
		if err := proto.Write(conn, &proto.Packet{Opcode: OpMove, Data: (&MoveRequest{X: 100, Z: z}).Encode()}, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(3 * time.Second)
	var receipt *TeleportResult
	for receipt == nil && time.Now().Before(deadline) {
		p := rig.next("Aria", time.Second)
		if p != nil && p.Opcode == OpTeleportResult {
			r, err := DecodeTeleportResult(p.Data)
			if err != nil {
				t.Fatal(err)
			}
			receipt = r
		}
	}
	if receipt == nil || !receipt.OK {
		t.Fatalf("reported walk through the zone: receipt %+v; want ok", receipt)
	}
	if czr := rig.arrival(); czr.Zone != "donwhang" {
		t.Fatalf("walked in to %q; want donwhang", czr.Zone)
	}
}
