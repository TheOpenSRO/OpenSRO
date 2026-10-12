package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"math"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/gm"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 778: the reverse return scroll and the return scroll, end to end --
// a logged-in character in the world uses a scroll, the reply comes back, the
// cast is fired by hand (the test's own clock) and the OpChangeZoneResult that
// moves the character is checked against the point each option names.

// The scrolls, the real rows' kinds and Param1 (allitems.txt on the RE box):
// ITEM_MALL_REVERSE_RETURN_SCROLL 3795, 3/3/3/3, Param1 1000;
// ITEM_ETC_SCROLL_RETURN_01 61, 3/3/3/1, Param1 30000.
const (
	fixtureReverseScroll = 3795
	fixtureReturnScroll  = 61
	// Round 779: ITEM_ETC_SCROLL_RETURN_THIEFDEN_01, 3/3/3/1, Param1 300000,
	// Param2 0.
	fixtureThiefDenScroll = 2128
)

// The map points: a field point in Donwhang's region (26265 = 102/153), a
// group flag, a floor in the fixture's served dungeon (-32000, 0x8300,
// teleportFixture's point 50 stands in it), one bounded above the rig's
// level, and one in another game world. Synthetic rows in the table's shape.
const scrollOptionalCSV = "ID,ZoneName,Region,X,Y,Z,WorldID,Group,MapPoint,LevelMin,LevelMax\n" +
	"24,SN_ZONE_22002,26265,972,-106,1421,1,-1,1,0,0\n" +
	"29,xxx,27027,1814,452,1834,1,1,1,0,0\n" +
	"30,SN_ZONE_FIXTURE_1F,-32000,120,7,140,1,1,0,50,999\n" +
	"39,SN_ZONE_FIXTURE_HIGH,23088,663,863,526,1,-1,1,90,999\n" +
	"77,SN_ZONE_ELSEWHERE,23088,663,863,526,4,-1,1,0,0\n"

type scrollRig struct {
	t      *testing.T
	chars  *character.MemStore
	inv    *inventory.MemStore
	hub    *world.Hub
	caster *ScrollCaster
	conn   net.Conn
	r      *bufio.Reader
	charID int64

	mu      sync.Mutex
	pending []func()
	// seen is what came before a use's reply (round 779: the stop and the
	// state's 0x30bf).
	seen []*proto.Packet
}

func newScrollRig(t *testing.T, level int) *scrollRig {
	t.Helper()
	ctx := context.Background()
	tab := teleportFixture(t)
	if err := tab.ReadOptional(strings.NewReader(scrollOptionalCSV)); err != nil {
		t.Fatalf("ReadOptional: %v", err)
	}
	SetRecallNetwork(tab)
	t.Cleanup(func() { SetRecallNetwork(nil) })
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: fixtureReverseScroll, CodeName: "ITEM_MALL_REVERSE_RETURN_SCROLL", MaxStack: 50,
			TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 3, RestoreHP: 1000, RestoreHPPct: 1, ReinforceRate1: 1, CanUse: true},
		{ID: fixtureReturnScroll, CodeName: "ITEM_ETC_SCROLL_RETURN_01", MaxStack: 50,
			TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 1, RestoreHP: 30000, RestoreHPPct: 1, ReinforceRate1: 1, CanUse: true},
		{ID: fixtureThiefDenScroll, CodeName: "ITEM_ETC_SCROLL_RETURN_THIEFDEN_01", MaxStack: 50,
			TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 1, RestoreHP: 300000, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	rig := &scrollRig{t: t, chars: character.NewMemStore(), inv: inventory.NewMemStore(items), hub: world.NewHub()}
	accounts := account.NewMemStore()
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatal(err)
	}
	acct, _ := accounts.Authenticate(ctx, "alice", "pw")
	c, err := rig.chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	if err := rig.chars.SetLeveling(ctx, c.ID, level, 0, 0, c.Str, c.Int); err != nil {
		t.Fatal(err)
	}
	rig.charID = c.ID
	for _, id := range []int64{fixtureReverseScroll, fixtureReturnScroll, fixtureThiefDenScroll} {
		if err := rig.inv.AddItem(ctx, c.ID, id, 5); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
	}
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	rig.caster = NewScrollCaster(rig.chars, eq, rig.hub, nil, nil)
	t.Cleanup(func() { activeScrolls.CompareAndSwap(rig.caster, nil) })
	rig.caster.after = func(_ time.Duration, f func()) {
		rig.mu.Lock()
		rig.pending = append(rig.pending, f)
		rig.mu.Unlock()
	}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(rig.chars, eq, rig.hub),
		TeleportHandler(rig.chars, eq, rig.hub, tab, gm.ParseAccounts(""), false, nil, nil),
		UseItemHandler(rig.chars, rig.inv, items, nil, nil, nil, rig.hub, nil, nil, nil, rig.caster))
	t.Cleanup(func() { InstallDungeonEntries(nil) })
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	rig.conn = dialTestServer(t, addr)
	t.Cleanup(func() { rig.conn.Close() })
	rig.r = bufio.NewReader(rig.conn)
	if lr, err := DecodeLoginResult(rig.roundTrip(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %+v %v", lr, err)
	}
	if ewr, err := DecodeEnterWorldResult(rig.roundTrip(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %+v %v", ewr, err)
	}
	return rig
}

func (rig *scrollRig) roundTrip(op uint16, data []byte) *proto.Packet {
	rig.t.Helper()
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		rig.t.Fatalf("write: %v", err)
	}
	return rig.read(2 * time.Second)
}

func (rig *scrollRig) read(wait time.Duration) *proto.Packet {
	rig.t.Helper()
	rig.conn.SetReadDeadline(time.Now().Add(wait))
	p, err := proto.Read(rig.r, nil, nil)
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return nil
		}
		rig.t.Fatalf("read: %v", err)
	}
	return p
}

// slot is the bag slot holding item id and its count.
func (rig *scrollRig) slot(id int64) (int, int) {
	rig.t.Helper()
	slots, err := rig.inv.List(context.Background(), rig.charID)
	if err != nil {
		rig.t.Fatal(err)
	}
	for _, s := range slots {
		if s.ItemID == id {
			return s.Index, s.Quantity
		}
	}
	return -1, 0
}

// clientUse is OpUseItem exactly as the client's UseItemNet.encode_use builds
// it (u16-prefixed name, i64 slot, then u8 option and the map option's u32),
// not through the server's encoder.
func clientUse(name string, slot int, option byte, target uint32) []byte {
	out := make([]byte, 2, 2+len(name)+13)
	binary.LittleEndian.PutUint16(out, uint16(len(name)))
	out = append(out, name...)
	out = binary.LittleEndian.AppendUint64(out, uint64(int64(slot)))
	if option != 0 {
		out = append(out, option)
		if option == 7 {
			out = binary.LittleEndian.AppendUint32(out, target)
		}
	}
	return out
}

func (rig *scrollRig) use(id int64, option byte, target uint32) *UseItemResult {
	rig.t.Helper()
	slot, _ := rig.slot(id)
	if slot < 0 {
		rig.t.Fatalf("no item %d in the bag", id)
	}
	p := rig.roundTrip(OpUseItem, clientUse("Aria", slot, option, target))
	// Round 779: an accepted scroll's 0xB023 and 0x30bf come before the
	// reply, as retail's stop and state precede DoJob's answer.
	for p != nil && p.Opcode != OpUseItemResult {
		rig.seen = append(rig.seen, p)
		p = rig.read(2 * time.Second)
	}
	if p == nil {
		rig.t.Fatal("no OpUseItemResult")
	}
	res, err := DecodeUseItemResult(p.Data)
	if err != nil {
		rig.t.Fatal(err)
	}
	return res
}

// fire runs the casts scheduled so far, as their delays running out would.
func (rig *scrollRig) fire() {
	rig.mu.Lock()
	fs := rig.pending
	rig.pending = nil
	rig.mu.Unlock()
	for _, f := range fs {
		f()
	}
}

// arrival reads up to the OpChangeZoneResult that moves Aria.
func (rig *scrollRig) arrival() *ChangeZoneResult {
	rig.t.Helper()
	for {
		p := rig.read(2 * time.Second)
		if p == nil {
			rig.t.Fatal("no OpChangeZoneResult after the cast")
		}
		if p.Opcode != OpChangeZoneResult {
			continue
		}
		czr, err := DecodeChangeZoneResult(p.Data)
		if err != nil || !czr.OK {
			rig.t.Fatalf("OpChangeZoneResult %+v %v", czr, err)
		}
		return czr
	}
}

// noArrival asserts no move follows within a short wait.
func (rig *scrollRig) noArrival() {
	rig.t.Helper()
	for {
		p := rig.read(300 * time.Millisecond)
		if p == nil {
			return
		}
		if p.Opcode == OpChangeZoneResult {
			rig.t.Fatalf("an unexpected move: % x", p.Data)
		}
	}
}

// standAt moves Aria (a relocated OpMove) to local (lx, lz) of region and
// waits for the hub to hold it.
func (rig *scrollRig) standAt(region int, lx, lz float64) {
	rig.t.Helper()
	e, ok := rig.hub.EntityByCharacterID(rig.charID)
	if !ok {
		rig.t.Fatal("Aria is not in the world")
	}
	fx, fy, ok := entityFrame(e.Zone)
	if !ok {
		rig.t.Fatalf("zone %q has no frame", e.Zone)
	}
	rx, ry := worldmap.RegionXY(region)
	x, z := worldmap.ToWorld(rx, ry, lx, lz, fx, fy)
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: OpMove,
		Data: (&MoveRequest{X: float32(x), Z: float32(z), Relocated: true}).Encode()}, nil, nil); err != nil {
		rig.t.Fatal(err)
	}
	for i := 0; i < 200; i++ {
		if e, _ := rig.hub.EntityByCharacterID(rig.charID); math.Abs(e.Pos.X-float64(float32(x))) < 0.01 && math.Abs(e.Pos.Z-float64(float32(z))) < 0.01 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	rig.t.Fatalf("the hub never took the move to %d/%d", rx, ry)
}

// localOf is the region and local x, z the hub's place for Aria names.
func (rig *scrollRig) localOf() (int, float64, float64) {
	rig.t.Helper()
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	p, ok := placeOfEntity(e)
	if !ok {
		rig.t.Fatalf("no place for zone %q", e.Zone)
	}
	return p.Region, p.X, p.Z
}

func near778(a, b float64) bool { return math.Abs(a-b) < 0.05 }

// The map option to a field point: the reply spends one scroll and names a
// one-second cast (Param1 1000, OURS ms); when it runs out the character
// lands exactly on the table's point (AJStateChanger::FUN_004076f0 copies the
// record's region and x/y/z, no scatter).
func TestRound778ReverseScrollToAMapPoint(t *testing.T) {
	rig := newScrollRig(t, 60)
	res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24)
	if res.Error != "" || res.Code != 0 || res.Remaining != 4 || res.CastMs != 1000 {
		t.Fatalf("use = %+v; want accepted, 4 left, a 1000 ms cast", res)
	}
	if _, n := rig.slot(fixtureReverseScroll); n != 4 {
		t.Fatalf("%d scrolls left, want 4 (spent at the use, DoJob's LAB_0049af45)", n)
	}
	rig.noArrival() // nothing moves before the delay
	rig.fire()
	czr := rig.arrival()
	if czr.Zone != teleportZoneFor(102, 153) {
		t.Fatalf("arrived in %q, want %q (region 102/153)", czr.Zone, teleportZoneFor(102, 153))
	}
	region, lx, lz := rig.localOf()
	if region != 26265 || !near778(lx, 972) || !near778(lz, 1421) {
		t.Fatalf("landed at %d (%v, %v); want 26265 (972, 1421)", region, lx, lz)
	}
}

// The cave's floor under its entrance's flag: the map option into a served
// dungeon lands in the dungeon's own zone at the floor's point, its height
// kept (a dungeon's floors stack).
func TestRound778ReverseScrollToADungeonFloor(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 30); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	rig.fire()
	czr := rig.arrival()
	if czr.Zone != "dungeon/33536" || czr.FrameRegion != "dungeon/33536" {
		t.Fatalf("arrived in %q frame %q; want dungeon/33536", czr.Zone, czr.FrameRegion)
	}
	if czr.X != 120 || czr.Y != 7 || czr.Z != -140 {
		t.Fatalf("arrived at (%v, %v, %v); want (120, 7, -140)", czr.X, czr.Y, czr.Z)
	}
}

// The refusals, each with the engine's code and nothing spent: below the
// floor's level range (0x18fd, FUN_004a1ed0), an id with no record (2), a
// point in another game world (0x18f5, OURS), an option the handler has no
// case for (2), and no recorded recall / death point (0x1885 / 0x1886).
func TestRound778ReverseScrollRefusals(t *testing.T) {
	rig := newScrollRig(t, 30)
	cases := []struct {
		name   string
		option byte
		target uint32
		code   uint16
	}{
		{"below the floor's level", ReverseOptionMap, 30, ScrollErrLevel},
		{"no such point", ReverseOptionMap, 31, ScrollErrUnknownOption},
		{"another world", ReverseOptionMap, 77, ScrollErrArea},
		{"an unknown option", 5, 0, ScrollErrUnknownOption},
		{"no option at all", 0, 0, ScrollErrUnknownOption},
		{"no recall point", ReverseOptionRecall, 0, ScrollErrNoRecallPoint},
		{"no death point", ReverseOptionDeath, 0, ScrollErrNoDeathPoint},
	}
	for _, c := range cases {
		res := rig.use(fixtureReverseScroll, c.option, c.target)
		if res.Code != c.code || res.Error == "" {
			t.Errorf("%s: %+v; want code 0x%x", c.name, res, c.code)
		}
	}
	if _, n := rig.slot(fixtureReverseScroll); n != 5 {
		t.Fatalf("%d scrolls left after refusals, want 5", n)
	}
	rig.noArrival()
}

// One scroll at a time (vslot 0x120, 0x185d): a second use while the first
// is casting is refused and spends nothing.
func TestRound778OneScrollAtATime(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("first use refused: %+v", res)
	}
	res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24)
	if res.Code != ScrollErrAlreadyWorking {
		t.Fatalf("second use: %+v; want 0x185d", res)
	}
	if _, n := rig.slot(fixtureReverseScroll); n != 4 {
		t.Fatalf("%d scrolls left, want 4", n)
	}
	rig.fire()
	rig.arrival()
	if rig.caster.Casting(rig.charID) {
		t.Fatal("still casting after the move")
	}
}

// The recall point: a return scroll used at a place records it
// (SaveCurPosAsLastTelPosition) and takes the character to its return point;
// the reverse scroll's option 2 then brings it back to where it read the
// scroll.
func TestRound778ReturnThenReverseToTheRecallPoint(t *testing.T) {
	rig := newScrollRig(t, 60)
	rig.standAt(25000, 700, 400)
	wantRegion, wantX, wantZ := rig.localOf()
	res := rig.use(fixtureReturnScroll, 0, 0)
	if res.Error != "" || res.CastMs != 30000 {
		t.Fatalf("return scroll: %+v; want accepted with a 30000 ms cast", res)
	}
	p, err := rig.chars.ReturnPoint(context.Background(), rig.charID, character.RecallPoint)
	if err != nil || p.Region != wantRegion || !near778(p.X, wantX) || !near778(p.Z, wantZ) {
		t.Fatalf("recall point %+v %v; want %d (%v, %v)", p, err, wantRegion, wantX, wantZ)
	}
	rig.fire()
	home := rig.arrival()
	// The return point: Aria designated nothing, so her race's gate,
	// STORE_CH_GATE -> GATE_CH (25000, 969, 1369).
	if region, lx, lz := rig.localOf(); region != 25000 || !near778(lx, 969) || !near778(lz, 1369) {
		t.Fatalf("the return scroll landed at %d (%v, %v) in %q; want GATE_CH's 25000 (969, 1369)", region, lx, lz, home.Zone)
	}
	if res := rig.use(fixtureReverseScroll, ReverseOptionRecall, 0); res.Error != "" {
		t.Fatalf("reverse to the recall point refused: %+v", res)
	}
	rig.fire()
	rig.arrival()
	if region, lx, lz := rig.localOf(); region != wantRegion || !near778(lx, wantX) || !near778(lz, wantZ) {
		t.Fatalf("back at %d (%v, %v); want %d (%v, %v)", region, lx, lz, wantRegion, wantX, wantZ)
	}
}

// The death point: recorded where the character fell (finishKill's
// recordDeathPoint), and option 3 lands there.
func TestRound778ReverseToTheDeathPoint(t *testing.T) {
	rig := newScrollRig(t, 60)
	rig.standAt(25000, 300, 1700)
	fellRegion, fellX, fellZ := rig.localOf()
	recordDeathPoint(context.Background(), rig.chars, rig.hub, rig.charID)
	rig.standAt(25000, 1200, 200)
	if res := rig.use(fixtureReverseScroll, ReverseOptionDeath, 0); res.Error != "" {
		t.Fatalf("reverse to the death point refused: %+v", res)
	}
	rig.fire()
	rig.arrival()
	if region, lx, lz := rig.localOf(); region != fellRegion || !near778(lx, fellX) || !near778(lz, fellZ) {
		t.Fatalf("landed at %d (%v, %v); want where she fell, %d (%v, %v)", region, lx, lz, fellRegion, fellX, fellZ)
	}
}

// A dungeon death point keeps the dungeon and its floor's height.
func TestRound778DeathPointInADungeon(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 30); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	rig.fire()
	rig.arrival()
	recordDeathPoint(context.Background(), rig.chars, rig.hub, rig.charID)
	p, _ := rig.chars.ReturnPoint(context.Background(), rig.charID, character.DeathPoint)
	if !worldmap.IsDungeonRegion(p.Region) || worldmap.DungeonRID(p.Region) != 0x8300 || p.X != 120 || p.Y != 7 || p.Z != 140 {
		t.Fatalf("death point %+v; want 0x8300 (120, 7, 140)", p)
	}
	zone, _, pos, _, ok := placeArrival(p.Region, p.X, p.Y, p.Z, p.WorldID)
	if !ok || zone != "dungeon/33536" || pos != (world.Position{X: 120, Y: 7, Z: -140}) {
		t.Fatalf("placeArrival = %q %+v %v", zone, pos, ok)
	}
}

// A cast whose character left the world is dropped: nothing moves.
func TestRound778CastDroppedAfterLeaving(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	rig.hub.Leave(e.Session)
	rig.fire()
	if rig.caster.Casting(rig.charID) {
		t.Fatal("the dropped cast is still recorded")
	}
	rig.noArrival()
}

// The wire: the request's option tail and the result's code/cast tail round
// trip, and the older forms still decode.
func TestRound778UseItemWire(t *testing.T) {
	req := &UseItemRequest{CharacterName: "Aria", InventorySlot: 9, Option: ReverseOptionMap, Target: 30}
	got, err := DecodeUseItemRequest(req.Encode())
	if err != nil || *got != *req {
		t.Fatalf("request round trip %+v %v", got, err)
	}
	if string(req.Encode()) != string(clientUse("Aria", 9, 7, 30)) {
		t.Fatal("the server's encoding differs from the client's")
	}
	old, err := DecodeUseItemRequest(clientUse("Aria", 9, 0, 0))
	if err != nil || old.Option != 0 || old.Target != 0 || old.InventorySlot != 9 {
		t.Fatalf("an option-less request %+v %v", old, err)
	}
	two, _ := DecodeUseItemRequest(clientUse("Aria", 9, 2, 0))
	if two.Option != 2 || two.Target != 0 {
		t.Fatalf("option 2 %+v", two)
	}
	res := &UseItemResult{Error: "x", Code: 0x18fd, CastMs: 1000, Remaining: 3}
	back, err := DecodeUseItemResult(res.Encode())
	if err != nil || back.Code != 0x18fd || back.CastMs != 1000 || back.Remaining != 3 || back.Error != "x" {
		t.Fatalf("result round trip %+v %v", back, err)
	}
	short := res.Encode()
	short = short[:len(short)-6] // a server before round 778
	if back, err := DecodeUseItemResult(short); err != nil || back.Code != 0 || back.Remaining != 3 {
		t.Fatalf("an old result %+v %v", back, err)
	}
}

// placeArrival refuses what OpenSRO cannot place.
func TestRound778PlaceArrivalRefusals(t *testing.T) {
	if _, _, _, _, ok := placeArrival(0, 1, 2, 3, 1); ok {
		t.Error("region 0 was placed")
	}
	if _, _, _, _, ok := placeArrival(26265, 1, 2, 3, 4); ok {
		t.Error("world 4 was placed")
	}
	InstallDungeonEntries(nil)
	if _, _, _, _, ok := placeArrival(-32767, 1, 2, 3, 1); ok {
		t.Error("an unserved dungeon was placed")
	}
	zone, _, pos, _, ok := placeArrival(26265, 972, -106, 1421, 1)
	if !ok || zone != teleportZoneFor(102, 153) || pos.Y != -106 {
		t.Errorf("a field point: %q %+v %v", zone, pos, ok)
	}
	_ = teleport.MainWorld
}
