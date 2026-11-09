package session

// Round 869 (docs/protocol/game_worlds.md 14 items 3-8): the instances on a
// live gateway -- the 0x705A portal entry's refusals in order and its two
// replies, the warp into a layer and back with the return point untouched,
// the exit NPC, the re-entry limit (same instance allowed, another refused
// 0x1c32, kept across a restart), the close warnings and the close back to
// the return point, the carried state.

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// gwRef is a world 1 and a world 63 shaped as the spec's
// (game_worlds.md 1, forgotten_world.md 1): 50 layers of 4, 2 h / 10 min,
// band 35..50, the four ON limits, the 60/10/5-minute warnings, group 1 at
// 300 minutes, the start 0x7EE4 (1063, 693, 1125) and a few of its regions.
func gwRef(t *testing.T) *gameworld.Ref {
	t.Helper()
	tabs := gwTables()
	// Round 870: a test's own tables on top (fgw870_test.go).
	if gwRefExtra != nil {
		gwRefExtra(tabs)
	}
	ref, err := gameworld.Build(func(n string) *reftable.Table { return tabs[n] })
	if err != nil {
		t.Fatal(err)
	}
	return ref
}

// gwRefExtra, when set, adds tables to the next gwRef.
var gwRefExtra func(tabs map[string]*reftable.Table)

// gwTables is gwRef's tables.
func gwTables() map[string]*reftable.Table {
	tabs := map[string]*reftable.Table{}
	w := reftable.New("ID", "WorldCodeName128", "Type", "WorldMaxCount", "WorldMaxUserCount", "WorldEntryType",
		"WorldEntranceType", "WorldLeaveType", "WorldDurationTime", "WorldEmptyRemainTime", "ConfigGroupCodeName128")
	w.Append("1", "INS_DEFAULT", "0", "1", "0", "0", "0", "0", "0", "0", "xxx")
	w.Append("63", "INS_GOD_TOGUI_35_50_LEVEL_1", "1", "50", "4", "0", "0", "0", "7200000", "600000", "G63")
	tabs[gameworld.TableWorld] = w
	cfg := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	for i, kv := range [][2]string{{"ENTER_LIMIT_CONDITION_LEVEL_MINIMUM_NUM", "35"}, {"ENTER_LIMIT_CONDITION_LEVEL_MAXIMUM_NUM", "50"},
		{"ENTER_LIMIT_CONDITION_JOB_CLOTHES_TAKE_OFF", "ON"}, {"ENTER_LIMIT_CONDITION_RIDE_COS_NOT_RIDING", "ON"},
		{"ENTER_LIMIT_CONDITION_TRADE_COS_NOT_RIDING", "ON"}, {"ENTER_LIMIT_CONDITION_FRPVP_VOUCHER_TAKE_OFF", "ON"},
		{"GAMEWORLD_DISAPPEARANCE_TIME", "3600000"}, {"GAMEWORLD_DISAPPEARANCE_TIME", "600000"}, {"GAMEWORLD_DISAPPEARANCE_TIME", "300000"}} {
		cfg.Append("1", fmt.Sprint(i+1), "G63", kv[0], kv[1], "INT32")
	}
	tabs[gameworld.TableWorldConfig] = cfg
	g := reftable.New("ID", "CodeName128", "ObjName128", "ConfigGroupCodeName128")
	g.Append("1", "GROUP_INS_GOD", "x", "GROUP_CONFIG_INS_GOD")
	tabs[gameworld.TableGroup] = g
	gc := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	gc.Append("1", "1", "GROUP_CONFIG_INS_GOD", "ENTER_WORLD_GROUP_COOL_TIME", "300", "INT32")
	tabs[gameworld.TableGroupConfig] = gc
	b := reftable.New("Service", "ID", "GameWorldID", "GameWorldGroupID")
	b.Append("1", "1", "63", "1")
	tabs[gameworld.TableGroupBind] = b
	r := reftable.New("WorldID", "RegionID")
	for _, rid := range []int{0x7EE4, 0x7EE3, 0x7DE4} {
		r.Append("63", fmt.Sprint(rid))
	}
	tabs[gameworld.TableRegion] = r
	sp := reftable.New("WorldID", "RegionID", "PosX", "PosY", "PosZ", "Param")
	sp.Append("63", fmt.Sprint(0x7EE4), "1063", "693", "1125", "0")
	tabs[gameworld.TableStartPos] = sp
	return tabs
}

type gwPlayer struct {
	conn   net.Conn
	r      *bufio.Reader
	charID int64
	sess   *gateway.Session
}

// gwRigExtra, when set, adds handlers to the next newGWRig's chain.
var gwRigExtra func(rig *gwRig) []gateway.Handler

type gwRig struct {
	t       *testing.T
	chars   *character.MemStore
	hub     *world.Hub
	mgr     *gameworld.Manager
	clock   *gameworld.FakeClock
	timed   timedjob.Store
	rows    *gameworld.MemCharStore
	parties *party.Hub
	players map[string]*gwPlayer
}

func newGWRig(t *testing.T, timed timedjob.Store, levels map[string]int) *gwRig {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	hub := world.NewHub()
	if timed == nil {
		timed = timedjob.NewMemStore()
	}
	rig := &gwRig{t: t, chars: chars, hub: hub, timed: timed, rows: gameworld.NewMemCharStore(), parties: party.NewHub(),
		clock: gameworld.NewFakeClock(time.Now()), players: map[string]*gwPlayer{}}
	rig.mgr = gameworld.NewManager(gameworld.ManagerConfig{Ref: gwRef(t), Clock: rig.clock, Hooks: SessionWorldHooks()})
	rig.mgr.AttachOpenWorld(hub, combat.NewHub(), grounditem.NewHub())
	SetGameWorlds(rig.mgr)
	SetGameWorldDeps(GameWorldDeps{Chars: chars, Equipment: eq, Timed: timed, Instances: rig.rows, Parties: rig.parties})
	t.Cleanup(func() {
		for _, w := range rig.mgr.List() {
			if !w.Open() {
				w.CloseAsync(gameworld.CloseManual)
			}
		}
		SetGameWorlds(nil)
		SetGameWorldDeps(GameWorldDeps{})
	})
	handlers := []gateway.Handler{LoginHandler(accounts), WorldHandler(chars, eq, hub),
		InstanceTeleportHandler(nil), InstanceExitHandler()}
	// Round 869 lane W3: a test's own handlers (fgw_hole_test.go).
	if gwRigExtra != nil {
		handlers = append(handlers, gwRigExtra(rig)...)
	}
	handle := gateway.Chain(handlers...)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, chars)}
	srvCtx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(srvCtx)
	for name, level := range levels {
		user := "u" + name
		if _, err := accounts.Register(ctx, user, "pw"); err != nil {
			t.Fatal(err)
		}
		acct, err := accounts.Authenticate(ctx, user, "pw")
		if err != nil {
			t.Fatal(err)
		}
		c, err := chars.Create(ctx, acct.ID, name)
		if err != nil {
			t.Fatal(err)
		}
		if err := chars.SetLeveling(ctx, c.ID, level, 0, 0, c.Str, c.Int); err != nil {
			t.Fatal(err)
		}
		var conn net.Conn
		for i := 0; i < 50; i++ {
			if conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err != nil {
			t.Fatal(err)
		}
		conn = &selfIDFilterConn{Conn: conn}
		t.Cleanup(func() { conn.Close() })
		p := &gwPlayer{conn: conn, r: bufio.NewReader(conn), charID: c.ID}
		rig.players[name] = p
		rig.send(name, OpLogin, (&LoginRequest{Username: user, Password: "pw"}).Encode())
		rig.until(name, OpLoginResult)
		rig.send(name, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		rig.until(name, OpEnterWorldResult)
		e, ok := hub.EntityByCharacterID(c.ID)
		if !ok {
			t.Fatalf("%s did not enter", name)
		}
		p.sess = e.Session
	}
	return rig
}

func (rig *gwRig) send(name string, op uint16, data []byte) {
	rig.t.Helper()
	if err := proto.Write(rig.players[name].conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		rig.t.Fatal(err)
	}
}

// until reads name's packets until one of op, failing after 3 s.
func (rig *gwRig) until(name string, op uint16) *proto.Packet {
	rig.t.Helper()
	p := rig.players[name]
	deadline := time.Now().Add(3 * time.Second)
	for {
		p.conn.SetReadDeadline(deadline)
		pkt, err := proto.Read(p.r, nil, nil)
		if err != nil {
			rig.t.Fatalf("%s: waiting for 0x%04x: %v", name, op, err)
		}
		if pkt.Opcode == op {
			return pkt
		}
	}
}

// collect reads name's packets of the given opcodes for wait.
func (rig *gwRig) collect(name string, wait time.Duration, ops ...uint16) []*proto.Packet {
	p := rig.players[name]
	var out []*proto.Packet
	deadline := time.Now().Add(wait)
	for {
		p.conn.SetReadDeadline(deadline)
		pkt, err := proto.Read(p.r, nil, nil)
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				return out
			}
			rig.t.Fatalf("%s: %v", name, err)
		}
		for _, op := range ops {
			if pkt.Opcode == op {
				out = append(out, pkt)
			}
		}
	}
}

func (rig *gwRig) open(t *testing.T) *gameworld.World {
	t.Helper()
	w, err := rig.mgr.Open(context.Background(), 63, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func portalUse(uid uint32, index byte) []byte {
	return append(binary.LittleEndian.AppendUint32(nil, uid), 3, index)
}

// portalReplies sends the portal teleport and answers the 0xB05A payloads it
// got.
func (rig *gwRig) portalReplies(name string, uid uint32, index byte, want int) []string {
	rig.send(name, proto.OpTeleportUse, portalUse(uid, index))
	var out []string
	for len(out) < want {
		out = append(out, fmt.Sprintf("% x", rig.until(name, proto.OpTeleportUseAck).Data))
	}
	return out
}

// TestPortalEntryRefusalsInOrder: each refusal of the warp handler's portal
// path and CanEnter, in the READ order, comes as the second reply after the
// {2, 1} accept (game_worlds.md 5).
func TestPortalEntryRefusalsInOrder(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 30, "Bram": 40})
	w := rig.open(t)
	aria, bram := rig.players["Aria"], rig.players["Bram"]
	RegisterPortal(&Portal{UID: 0x7d00f001, World: w, Access: 6, Owner: aria.charID, Destinations: 1})
	defer UnregisterPortal(0x7d00f001)
	accepted := "02 01 00"
	check := func(name string, index byte, code uint16) {
		t.Helper()
		got := rig.portalReplies(name, 0x7d00f001, index, 2)
		want := fmt.Sprintf("% x", teleportUseReply(false, code))
		if got[0] != accepted || got[1] != want {
			t.Errorf("%s: replies %v, want [%s %s]", name, got, accepted, want)
		}
	}
	// The portal's access rule (6: the owner only) before the destination
	// and the world's checks: Bram is not the owner.
	check("Bram", 0, gameworld.CodeAccess)
	// The destination: index 1 of a one-destination portal.
	check("Aria", 1, gameworld.CodeNoDestination)
	// The layer full (order 1) before the level (order 4): four others in.
	for i := int64(0); i < 4; i++ {
		w.Enter(900+i, 40)
	}
	check("Aria", 0, gameworld.CodeMaxUsers)
	for i := int64(0); i < 4; i++ {
		w.Leave(900 + i)
	}
	// The level band 35..50: Aria is 30.
	check("Aria", 0, gameworld.CodeLevel)
	// The group cool time for another instance: Bram as the owner, at 40,
	// with a running limit keyed to some other layer.
	RegisterPortal(&Portal{UID: 0x7d00f002, World: w, Access: 6, Owner: bram.charID, Destinations: 1})
	defer UnregisterPortal(0x7d00f002)
	rig.timed.Put(context.Background(), timedjob.Job{CharID: bram.charID, Type: TimedJobWorldGroup, Ref: 1, Key: int64(w.Key) + 1000,
		Start: time.Now(), End: time.Now().Add(time.Hour)})
	got := rig.portalReplies("Bram", 0x7d00f002, 0, 2)
	if got[1] != fmt.Sprintf("% x", teleportUseReply(false, gameworld.CodeCoolTime)) {
		t.Errorf("cool time: %v, want the 0x1c32 refusal", got)
	}
	// An unknown portal is the plain 3.
	if got := rig.portalReplies("Aria", 0x7d00ffff, 0, 2); got[1] != "02 03 00" {
		t.Errorf("unknown portal: %v", got)
	}
}

// TestPortalEntrySucceedsWithTwoReplies: {2, 1}, then {1}, then the zone
// change into the layer's start; the row, the group limit and its 0x320C.
func TestPortalEntrySucceedsWithTwoReplies(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	RegisterPortal(&Portal{UID: 0x7d00f010, World: w, Access: 6, Owner: aria.charID, Destinations: 1})
	defer UnregisterPortal(0x7d00f010)
	before, _ := rig.hub.EntityByCharacterID(aria.charID)
	got := rig.portalReplies("Aria", 0x7d00f010, 0, 2)
	if got[0] != "02 01 00" || got[1] != "01" {
		t.Fatalf("replies %v, want [02 01 00, 01]", got)
	}
	czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
	if err != nil || !czr.OK {
		t.Fatalf("zone change %+v %v", czr, err)
	}
	ct := rig.until("Aria", proto.OpTimedJobPush).Data
	if ct[0] != 0x0C || binary.LittleEndian.Uint32(ct[1:]) != 1 || binary.LittleEndian.Uint32(ct[5:]) != 18000 {
		t.Errorf("0x320C % x, want {0x0C, group 1, 18000 s}", ct)
	}
	e, ok := w.Hub.EntityByCharacterID(aria.charID)
	if !ok {
		t.Fatal("not in the layer's hub")
	}
	if _, still := rig.hub.EntityByCharacterID(aria.charID); still {
		t.Fatal("still in the open world's hub")
	}
	if fmt.Sprint(w.Members()) != fmt.Sprint([]int64{aria.charID}) {
		t.Errorf("members %v", w.Members())
	}
	if region, _, _ := regionLocalOf(e.Zone, e.Pos); region != 0x7EE4 {
		t.Errorf("arrived in region %#x, want the start 0x7EE4", region)
	}
	row, ok, _ := rig.rows.Get(context.Background(), aria.charID, 63)
	if !ok || row.Key != w.Key || row.Layer != w.ID.Layer || row.Region != 0x7EE4 || row.EnterCount != 1 {
		t.Errorf("instance row %+v", row)
	}
	if rp, ok := instanceReturns.Load(aria.charID); !ok || rp.(returnPoint).pos != before.Pos {
		t.Errorf("return point %+v, want %+v", rp, before.Pos)
	}
}

// TestExitNPCAndBack: inside, the exit NPC's 0x751D answers {1} and warps to
// the return point -- where the character stood, untouched by the stay --
// and the empty layer closes 600 s later; its refusals.
func TestExitNPCAndBack(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	before, _ := rig.hub.EntityByCharacterID(aria.charID)
	exitUID := NextInstanceNPCUID()
	SetInstanceNPCs(w, []npcspawn.NPC{{Record: npcspawn.Record{RefID: 36032, UID: exitUID, Region: 0x7EE4, X: 1070, Y: 693, Z: 1125}, Code: "NPC_INS_EXIT_TELEPORT"},
		{Record: npcspawn.Record{RefID: 36033, UID: exitUID + 1, Region: 0x7EE4, X: 1075, Y: 693, Z: 1125}, Code: "NPC_FWORLD_RECALL_PARTY"}}, nil)
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	// Not an exit NPC: 2.
	rig.send("Aria", proto.OpInstanceExit, binary.LittleEndian.AppendUint32(nil, exitUID+1))
	if got := fmt.Sprintf("% x", rig.until("Aria", proto.OpInstanceExitAck).Data); got != "02 02 00" {
		t.Errorf("recall NPC as exit: %s", got)
	}
	// Dead: 0x1c36.
	w.Hub.SetLifeState(aria.charID, world.LifeAlive, world.LifeDead, time.Now())
	rig.send("Aria", proto.OpInstanceExit, binary.LittleEndian.AppendUint32(nil, exitUID))
	if got := fmt.Sprintf("% x", rig.until("Aria", proto.OpInstanceExitAck).Data); got != "02 36 1c" {
		t.Errorf("dead: %s", got)
	}
	w.Hub.SetLifeState(aria.charID, world.LifeDead, world.LifeAlive, time.Now())
	rig.send("Aria", proto.OpInstanceExit, binary.LittleEndian.AppendUint32(nil, exitUID))
	if got := fmt.Sprintf("% x", rig.until("Aria", proto.OpInstanceExitAck).Data); got != "01" {
		t.Fatalf("exit: %s", got)
	}
	czr, _ := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
	back, ok := rig.hub.EntityByCharacterID(aria.charID)
	if !ok || back.Pos != before.Pos || back.Zone != before.Zone || czr.Zone != spawnZone {
		t.Fatalf("back at %+v (%q), want %+v in %s", back, czr.Zone, before, spawnZone)
	}
	if len(w.Members()) != 0 {
		t.Errorf("members %v", w.Members())
	}
	rig.clock.Advance(599 * time.Second)
	w.Sync()
	if w.Closed() {
		t.Fatal("closed before 600 s empty")
	}
	rig.clock.Advance(time.Second)
	<-w.Done()
}

// TestReEntryLimit: the limit starts at the entry; the same instance may be
// entered again, another is refused 0x1c32, and a restart (a new manager on
// the same timed-job store) keeps it, its 0x320C at the world entry.
func TestReEntryLimit(t *testing.T) {
	timed := timedjob.NewMemStore()
	rig := newGWRig(t, timed, map[string]int{"Aria": 40})
	w1 := rig.open(t)
	w2 := rig.open(t)
	aria := rig.players["Aria"]
	RegisterPortal(&Portal{UID: 0x7d00f021, World: w1, Access: 6, Owner: aria.charID, Destinations: 1})
	RegisterPortal(&Portal{UID: 0x7d00f022, World: w2, Access: 6, Owner: aria.charID, Destinations: 1})
	defer UnregisterPortal(0x7d00f021)
	defer UnregisterPortal(0x7d00f022)
	if got := rig.portalReplies("Aria", 0x7d00f021, 0, 2); got[1] != "01" {
		t.Fatalf("first entry %v", got)
	}
	rig.until("Aria", OpChangeZoneResult)
	if err := returnFromInstance(context.Background(), aria.sess, w1.Hub, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	if got := rig.portalReplies("Aria", 0x7d00f022, 0, 2); got[1] != fmt.Sprintf("% x", teleportUseReply(false, gameworld.CodeCoolTime)) {
		t.Errorf("another instance: %v, want 0x1c32", got)
	}
	if got := rig.portalReplies("Aria", 0x7d00f021, 0, 2); got[1] != "01" {
		t.Errorf("the same instance again: %v, want {1}", got)
	}
	jobs, _ := timed.List(context.Background(), aria.charID)
	if len(jobs) != 1 || jobs[0].Type != 0xC || uint32(jobs[0].Key) != w1.Key || jobs[0].End.Sub(jobs[0].Start) != 5*time.Hour {
		t.Errorf("timed jobs %+v, want one category-0xC row for the first instance, 5 h", jobs)
	}
	// A restart: a new process on the same store refuses a new layer.
	SetGameWorlds(nil)
	rig2 := newGWRig(t, timed, map[string]int{"Bram": 40})
	w3 := rig2.open(t)
	e := world.Entity{CharacterID: aria.charID, Level: 40}
	if c := gameworld.CanEnter(w3, entrantOf(context.Background(), e, false, time.Now()), time.Now()); c != gameworld.CodeCoolTime {
		t.Errorf("after the restart: CanEnter %#x, want 0x1c32", c)
	}
}

// TestCloseWarnsAndReturns: the three warnings 0x300C {0x0C1A, 60 / 10 / 5}
// reach the member, and the 2 h end takes it to its return point.
func TestCloseWarnsAndReturns(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	before, _ := rig.hub.EntityByCharacterID(aria.charID)
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	for i := 0; i < 24; i++ {
		rig.clock.Advance(5 * time.Minute)
		w.Sync()
	}
	<-w.Done()
	got := rig.collect("Aria", 500*time.Millisecond, OpUniqueNotice, OpChangeZoneResult)
	var seen []string
	for _, p := range got {
		seen = append(seen, fmt.Sprintf("%04x:% x", p.Opcode, p.Data[:min(3, len(p.Data))]))
	}
	want := []string{fmt.Sprintf("%04x:1a 0c 3c", OpUniqueNotice), fmt.Sprintf("%04x:1a 0c 0a", OpUniqueNotice), fmt.Sprintf("%04x:1a 0c 05", OpUniqueNotice)}
	if len(seen) != 4 || fmt.Sprint(seen[:3]) != fmt.Sprint(want) || got[3].Opcode != OpChangeZoneResult {
		t.Fatalf("packets %v, want the three warnings then the zone change", seen)
	}
	back, ok := rig.hub.EntityByCharacterID(aria.charID)
	if !ok || back.Pos != before.Pos {
		t.Errorf("after the close at %+v, want the return point %+v", back, before.Pos)
	}
}

// TestCarriedStateAcrossWorlds: a buff and a cooldown survive a warp into a
// layer and back (the per-character books travel with the character), and
// the snapshot W2 carries between processes names them.
func TestCarriedStateAcrossWorlds(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	now := time.Now()
	buffBooks.Start(aria.charID, buff.Spec{SkillID: 9001, GroupID: 9001, Level: 1, CasterID: aria.charID, DuraMs: 600000}, now)
	itemCooldowns.Arm(aria.charID, 0x71, time.Hour, now)
	defer buffBooks.EndAll(aria.charID)
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	if err := returnFromInstance(context.Background(), aria.sess, w.Hub, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	if len(buffBooks.Active(aria.charID)) != 1 {
		t.Errorf("buffs after the round trip: %v", buffBooks.Active(aria.charID))
	}
	if itemCooldowns.Ready(aria.charID, 0x71, time.Now()) {
		t.Error("the cool-time group 0x71 ran out across the warp")
	}
	s := SnapshotCarried(aria.charID)
	if len(s.Buffs) != 1 || s.GroupCooldowns[0x71].IsZero() {
		t.Errorf("snapshot %+v", s)
	}
	RestoreCarried(aria.charID+1, s)
	if itemCooldowns.Ready(aria.charID+1, 0x71, time.Now()) {
		t.Error("RestoreCarried did not carry the cooldown")
	}
}

// TestInstanceUnseenFromTheOpenWorld: under -single-frame, where the open
// world's labels share one bucket, a character in a layer at the same
// coordinates as one in the open world is in a hub of its own: neither sees
// the other (game_worlds.md 10's hazard, closed by the units).
func TestInstanceUnseenFromTheOpenWorld(t *testing.T) {
	SetSingleFrame(true)
	defer SetSingleFrame(false)
	rig := newGWRig(t, nil, map[string]int{"Aria": 40, "Bram": 40})
	w := rig.open(t)
	aria, bram := rig.players["Aria"], rig.players["Bram"]
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	in, _ := w.Hub.EntityByCharacterID(aria.charID)
	rig.hub.Relocate(bram.sess, in.Pos, world.MoveRelocate, 0)
	for _, e := range rig.hub.ViewOfCharacter(bram.charID) {
		if e.CharacterID == aria.charID {
			t.Fatal("the open world sees the instanced character")
		}
	}
	for _, e := range w.Hub.ViewOfCharacter(aria.charID) {
		if e.CharacterID == bram.charID {
			t.Fatal("the instance sees the open world's character")
		}
	}
}
