package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"sort"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// npcAt is an NPC standing at world (x, z) of the jangan zone's frame (centre
// region 97/168, whose local (960, 960) is the world's origin).
func npcAt(uid uint32, x, z float64, src npcspawn.Source) npcspawn.NPC {
	return npcspawn.NPC{Record: npcspawn.Record{RefID: 2000 + uid, UID: npcspawn.UIDBase + uid, Region: 25000,
		X: float32(960 + x), Z: float32(960 - z), Angle: uint16(uid * 100)}, Source: src}
}

func installNPCsForTest(t *testing.T, npcs ...npcspawn.NPC) {
	t.Helper()
	if n := InstallNPCs(npcs, nil); n != len(npcs) {
		t.Fatalf("filed %d of %d NPCs", n, len(npcs))
	}
	t.Cleanup(func() { InstallNPCs(nil, nil) })
}

// npcFrames reads a delivery: the uids spawned and despawned (each group
// reassembled as the client does) and those named unfaced.
func npcFrames(t *testing.T, frames []*proto.Packet) (spawned, despawned, unfaced []uint32, records []npcspawn.Decoded) {
	t.Helper()
	var group []npcspawn.GroupFrame
	for _, p := range frames {
		switch p.Opcode {
		case npcspawn.OpNpcFacingUnknown:
			n := int(binary.LittleEndian.Uint16(p.Data))
			for i := 0; i < n; i++ {
				unfaced = append(unfaced, binary.LittleEndian.Uint32(p.Data[2+4*i:]))
			}
		case npcspawn.OpGroupBegin, npcspawn.OpGroupData:
			group = append(group, npcspawn.GroupFrame{Opcode: p.Opcode, Data: p.Data})
		case npcspawn.OpGroupEnd:
			group = append(group, npcspawn.GroupFrame{Opcode: p.Opcode, Data: p.Data})
			kind, recs, uids, err := npcspawn.DecodeGroup(group)
			if err != nil {
				t.Fatalf("group: %v", err)
			}
			group = nil
			if kind == npcspawn.GroupSpawn {
				for _, r := range recs {
					spawned = append(spawned, r.UID)
				}
				records = append(records, recs...)
			} else {
				despawned = append(despawned, uids...)
			}
		default:
			t.Errorf("unexpected opcode %#04x", p.Opcode)
		}
	}
	if len(group) != 0 {
		t.Fatalf("a group with no 0x3018")
	}
	return spawned, despawned, unfaced, records
}

func sameUIDs(a []uint32, b ...uint32) bool {
	if len(a) != len(b) {
		return false
	}
	a = append([]uint32(nil), a...)
	b = append([]uint32(nil), b...)
	sort.Slice(a, func(i, j int) bool { return a[i] < a[j] })
	sort.Slice(b, func(i, j int) bool { return b[i] < b[j] })
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// A player entering the world is sent the NPCs of its 3 x 3 blocks as group
// spawns (one per block), the stand-in ones named in OpNpcFacingUnknown first;
// walking over a block line despawns the column it lost and spawns the one it
// gained; standing still sends nothing; and the record carries the NPC's
// position and angle.
func TestNPCWindowSpawnsAndDespawns(t *testing.T) {
	a := npcAt(1, 100, 100, npcspawn.FromNest)             // cell (0, 0)
	b := npcAt(2, cellX(2), 0, npcspawn.FromNest)          // cell (2, 0): out at 0, in at 1
	c := npcAt(3, cellX(-1), 50, npcspawn.FromNpcpos)      // cell (-1, 0): in at 0, out at 1
	far := npcAt(4, cellX(5), cellX(5), npcspawn.FromNest) // never
	installNPCsForTest(t, a, b, c, far)
	monsters := combat.NewHub()
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	cl := r.join(t, 1, 0, 0)

	v.reconcile()
	spawned, despawned, unfaced, recs := npcFrames(t, cl.quiet(t, 200*time.Millisecond))
	if !sameUIDs(spawned, a.UID, c.UID) || len(despawned) != 0 || !sameUIDs(unfaced, c.UID) {
		t.Fatalf("entering: spawned %v despawned %v unfaced %v; want spawned [%d %d], unfaced [%d]",
			spawned, despawned, unfaced, a.UID, c.UID, c.UID)
	}
	for _, rec := range recs {
		want := a
		if rec.UID == c.UID {
			want = c
		}
		if rec.X != want.X || rec.Z != want.Z || rec.Angle != want.Angle || rec.RefID != want.RefID {
			t.Errorf("record %+v, want %+v", rec.Record, want.Record)
		}
	}

	v.reconcile()
	if extra := cl.quiet(t, 150*time.Millisecond); len(extra) != 0 {
		t.Fatalf("%d frame(s) with nobody moved", len(extra))
	}

	sess := r.session(1)
	r.hub.Relocate(sess, world.Position{X: cellX(1) - 150, Z: 0}, world.MoveRelocate, 0)
	v.reconcile()
	spawned, despawned, unfaced, _ = npcFrames(t, cl.quiet(t, 200*time.Millisecond))
	if !sameUIDs(spawned, b.UID) || !sameUIDs(despawned, c.UID) || len(unfaced) != 0 {
		t.Fatalf("crossing east: spawned %v despawned %v unfaced %v", spawned, despawned, unfaced)
	}

	r.hub.Relocate(sess, world.Position{X: 0, Z: 0}, world.MoveRelocate, 0)
	v.reconcile()
	spawned, despawned, unfaced, _ = npcFrames(t, cl.quiet(t, 200*time.Millisecond))
	if !sameUIDs(spawned, c.UID) || !sameUIDs(despawned, b.UID) || !sameUIDs(unfaced, c.UID) {
		t.Fatalf("crossing back: spawned %v despawned %v unfaced %v", spawned, despawned, unfaced)
	}
}

// Without InstallNPCs nothing NPC-shaped reaches a player (every monster AOI
// test runs this way).
func TestNoNPCsWithoutTheRuntime(t *testing.T) {
	monsters := combat.NewHub()
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	cl := r.join(t, 1, 0, 0)
	v.reconcile()
	if extra := cl.quiet(t, 150*time.Millisecond); len(extra) != 0 {
		t.Fatalf("%d frame(s) with no NPC runtime", len(extra))
	}
}

// Under -single-frame the NPCs stand in the one world bucket, converted
// against worldmap.WorldOrigin.
func TestNPCsInTheSingleFrame(t *testing.T) {
	SetSingleFrame(true)
	defer SetSingleFrame(false)
	installNPCsForTest(t, npcAt(1, 100, 100, npcspawn.FromNest))
	if n := NPCsInWindow(combat.CellOf("world", 0, 0)); n != 1 {
		t.Fatalf("%d NPC(s) in the world bucket's window at the origin, want 1", n)
	}
	if n := NPCsInWindow(combat.CellOf("jangan", 0, 0)); n != 0 {
		t.Fatalf("%d NPC(s) filed under the zone name in the single frame", n)
	}
}

// Round 708's review, HIGH 1: an area-of-interest tick between hub.Enter and
// the OpEnterWorldResult send spawns the window BEFORE the result, which the
// client answers by clearing its roster. The entry forgets the window again
// after the result, so the next tick spawns it after the result. The hook
// puts a tick exactly in that gap.
func TestNPCWindowSurvivesATickBeforeTheEntryResult(t *testing.T) {
	ctx := context.Background()
	npc := npcAt(1, 100, 100, npcspawn.FromNest) // beside jangan's landing (0, 0)
	installNPCsForTest(t, npc)
	accounts := account.NewMemStore()
	accounts.Add("alice", "pw1")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	hub := world.NewHub()
	v := installAOIForTest(t, hub, combat.NewHub())
	ticked := false
	enterWorldBeforeResultHook = func(*gateway.Session) {
		v.reconcile() // the tick lands in the gap
		ticked = true
	}
	t.Cleanup(func() { enterWorldBeforeResultHook = nil })
	addr, cleanup := startTestServer(t, gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub)))
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	c.send(OpLogin, (&LoginRequest{Username: "alice", Password: "pw1"}).Encode())
	c.next(OpLoginResult)
	c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())

	// Everything up to the result: the early groups the gap's tick sent.
	var before []*proto.Packet
	for {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for the entry result: %v", err)
		}
		if p.Opcode == OpEnterWorldResult {
			break
		}
		if p.Opcode >= npcspawn.OpSingleSpawn && p.Opcode <= npcspawn.OpGroupData {
			before = append(before, p)
		}
	}
	if !ticked {
		t.Fatal("precondition: the hook did not run")
	}
	early, _, _, _ := npcFrames(t, before)
	if !sameUIDs(early, npc.UID) {
		t.Fatalf("precondition: the gap's tick spawned %v before the result, want [%d]", early, npc.UID)
	}
	// The client cleared its roster on the result; the next tick must spawn
	// the window again.
	v.reconcile()
	var after []*proto.Packet
	for _, p := range c.quietFrames(300 * time.Millisecond) {
		if p.Opcode >= npcspawn.OpSingleSpawn && p.Opcode <= npcspawn.OpGroupData || p.Opcode == npcspawn.OpNpcFacingUnknown {
			after = append(after, p)
		}
	}
	late, _, _, _ := npcFrames(t, after)
	if !sameUIDs(late, npc.UID) {
		t.Fatalf("after the result the window spawned %v, want [%d] again", late, npc.UID)
	}
}

// quietFrames reads frames until none arrives for d.
func (c *chatClient) quietFrames(d time.Duration) []*proto.Packet {
	var out []*proto.Packet
	for {
		c.conn.SetReadDeadline(time.Now().Add(d))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			return out
		}
		out = append(out, p)
	}
}
