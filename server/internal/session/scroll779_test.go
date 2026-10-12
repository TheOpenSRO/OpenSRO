package session

import (
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 779: the return scrolls' cast -- its length per row, the stop and the
// 0x30bf state it starts with, the cancel (0x705B), a death's cancel, and
// what the state refuses. docs/protocol/return_scroll_cast.md has the reads.

// The delay per real row (Param1, itemdata column 118, MEASURED on the RE
// box's itemdata): Param1 / 1000 whole seconds (RefObjItem::ExtractData's
// integer division, the job manager's seconds), with FUN_004e0b50's 0.1 s
// floor for anything under one second.
func TestRound779ScrollDelayPerRow(t *testing.T) {
	cases := []struct {
		row    string
		param1 int
		want   time.Duration
	}{
		{"ITEM_ETC_SCROLL_RETURN_01", 30000, 30 * time.Second},
		{"ITEM_ETC_SCROLL_RETURN_NEWBIE_01", 30000, 30 * time.Second},
		{"ITEM_ETC_SCROLL_RETURN_02", 15000, 15 * time.Second},
		{"ITEM_ETC_SCROLL_RETURN_03", 5000, 5 * time.Second},
		{"ITEM_ETC_E041225_SANTA_WINGS", 5000, 5 * time.Second},
		{"ITEM_MALL_RETURN_SCROLL_HIGH_SPEED", 1000, time.Second},
		{"ITEM_EVENT_RETURN_SCROLL_HIGH_SPEED", 1000, time.Second},
		{"ITEM_MALL_REVERSE_RETURN_SCROLL", 1000, time.Second},
		{"ITEM_ETC_SCROLL_RETURN_THIEFDEN_01", 300000, 300 * time.Second},
		{"ITEM_ETC_SCROLL_RETURN_THIEFDEN_02", 165000, 165 * time.Second},
		{"a Param1 of 1500 (integer division)", 1500, time.Second},
		{"a Param1 under a second (the floor)", 999, 100 * time.Millisecond},
		{"no Param1 (the floor)", 0, 100 * time.Millisecond},
	}
	for _, c := range cases {
		if got := scrollDelay(&refdata.Item{RestoreHP: c.param1}); got != c.want {
			t.Errorf("%s: Param1 %d -> %v, want %v", c.row, c.param1, got, c.want)
		}
	}
}

// The state's value is (Param2 == 0) + 1: 1 for the RESURRECT rows (Param2
// 1), 2 for the thief-den rows (Param2 0).
func TestRound779StateValue(t *testing.T) {
	if v := scrollStateValue(&refdata.Item{ReinforceRate1: 1}); v != 1 {
		t.Errorf("Param2 1 -> %d, want 1", v)
	}
	if v := scrollStateValue(&refdata.Item{}); v != 2 {
		t.Errorf("Param2 0 -> %d, want 2", v)
	}
}

// stateChanges are the 0x30bf kind 0xb messages among ps.
func scrollStates(ps []*proto.Packet) []StateChange {
	var out []StateChange
	for _, p := range ps {
		if p.Opcode != OpStateChange {
			continue
		}
		if s, ok := DecodeStateChange(p.Data); ok && s.Kind == StateKindTeleport {
			out = append(out, *s)
		}
	}
	return out
}

// readUntil reads until a frame of op (returning it and what came before),
// or nil after a quiet wait.
func (rig *scrollRig) readUntil(op uint16, wait time.Duration) (*proto.Packet, []*proto.Packet) {
	rig.t.Helper()
	var before []*proto.Packet
	for {
		p := rig.read(wait)
		if p == nil || p.Opcode == op {
			return p, before
		}
		before = append(before, p)
	}
}

// A use starts the state with its 0x30bf {id, 0xb, 1} before the reply (the
// reply names the item and the cast); the spawn record carries the value
// meanwhile; the move ends it with value 0, sent after the zone change.
func TestRound779CastBroadcastsTheState(t *testing.T) {
	rig := newScrollRig(t, 60)
	res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24)
	if res.Error != "" || res.CastMs != 1000 || res.ItemID != fixtureReverseScroll {
		t.Fatalf("use = %+v; want accepted, a 1000 ms cast of item %d", res, fixtureReverseScroll)
	}
	st := scrollStates(rig.seen)
	if len(st) != 1 || st[0].ObjectID != uint32(rig.charID) || st[0].Value != 1 {
		t.Fatalf("states before the reply %+v; want one {Aria, 0xb, 1}", st)
	}
	if v := scrollStateOf(rig.charID); v != 1 {
		t.Fatalf("spawn record's teleport state %d, want 1", v)
	}
	rig.fire()
	czr, _ := rig.readUntil(OpChangeZoneResult, 2*time.Second)
	if czr == nil {
		t.Fatal("no move")
	}
	_, after := rig.readUntil(0xffff, 300*time.Millisecond)
	if st := scrollStates(after); len(st) != 1 || st[0].Value != 0 {
		t.Fatalf("states after the move %+v; want one value 0", st)
	}
	if v := scrollStateOf(rig.charID); v != 0 {
		t.Fatalf("teleport state %d after the move, want 0", v)
	}
}

// The ordinary return scroll's 30 s and the reply's item.
func TestRound779ReturnScrollCast(t *testing.T) {
	rig := newScrollRig(t, 60)
	res := rig.use(fixtureReturnScroll, 0, 0)
	if res.Error != "" || res.CastMs != 30000 || res.ItemID != fixtureReturnScroll {
		t.Fatalf("use = %+v; want a 30000 ms cast of item %d", res, fixtureReturnScroll)
	}
	if st := scrollStates(rig.seen); len(st) != 1 || st[0].Value != 1 {
		t.Fatalf("states %+v; want one value 1", st)
	}
}

// The cancel button's 0x705B: the cast ends, the 0x30bf value 0 is the only
// answer, nothing moves when the delay would have run out, and the scroll
// stays spent.
func TestRound779CancelEndsTheCast(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: OpScrollCancel}, nil, nil); err != nil {
		t.Fatal(err)
	}
	_, got := rig.readUntil(0xffff, 300*time.Millisecond)
	for _, p := range got {
		if p.Opcode == OpScrollCancelResult {
			t.Fatalf("a cancel that worked was answered 0xB05B % x", p.Data)
		}
	}
	if st := scrollStates(got); len(st) != 1 || st[0].Value != 0 || st[0].ObjectID != uint32(rig.charID) {
		t.Fatalf("states after the cancel %+v; want one {Aria, 0xb, 0}", st)
	}
	if rig.caster.Casting(rig.charID) {
		t.Fatal("still casting after the cancel")
	}
	rig.fire()
	rig.noArrival()
	if _, n := rig.slot(fixtureReverseScroll); n != 4 {
		t.Fatalf("%d scrolls after the cancel, want 4 (spent at the use)", n)
	}
	// And a new cast may start.
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("a use after the cancel refused: %+v", res)
	}
}

// A cancel with no scroll working is refused 0xB05B {2, u16 6}.
func TestRound779CancelWithNothingWorking(t *testing.T) {
	rig := newScrollRig(t, 60)
	p := rig.roundTrip(OpScrollCancel, nil)
	if p == nil || p.Opcode != OpScrollCancelResult || string(p.Data) != string([]byte{2, 6, 0}) {
		t.Fatalf("reply %+v; want 0xB05B 02 06 00", p)
	}
}

// A death cancels the cast (vslot_306 / vslot_307 run the 0x705B handler).
func TestRound779DeathCancels(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	cancelScrollForDeath(rig.hub, rig.charID)
	_, got := rig.readUntil(0xffff, 300*time.Millisecond)
	if st := scrollStates(got); len(st) != 1 || st[0].Value != 0 {
		t.Fatalf("states after the death %+v; want one value 0", st)
	}
	rig.fire()
	rig.noArrival()
}

// A use stops a walking character: its leg ends and 0xB023 reaches its own
// client before the state and the reply.
func TestRound779UseStopsAWalker(t *testing.T) {
	rig := newScrollRig(t, 60)
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	dest := world.Position{X: e.Pos.X + 300, Y: e.Pos.Y, Z: e.Pos.Z}
	region, lx, lz := regionLocalOf(e.Zone, dest)
	click := (&proto.Movement{Kind: 1, Region: region, LocalX: int16(lx), LocalY: int16(e.Pos.Y), LocalZ: int16(lz)}).Encode()
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: proto.OpMovementRequest, Data: click}, nil, nil); err != nil {
		t.Fatal(err)
	}
	if echo, _ := rig.readUntil(proto.OpMovementResponse, 2*time.Second); echo == nil {
		t.Fatal("the click was not accepted")
	}
	if e, _ := rig.hub.EntityByCharacterID(rig.charID); e.Move == nil {
		t.Fatal("no leg after the click")
	}
	if res := rig.use(fixtureReverseScroll, ReverseOptionMap, 24); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	stop, state := -1, -1
	for i, p := range rig.seen {
		switch p.Opcode {
		case OpMovementStop:
			stop = i
		case OpStateChange:
			state = i
		}
	}
	if stop < 0 || state < 0 || stop > state {
		t.Fatalf("frames before the reply: stop at %d, state at %d; want the stop first", stop, state)
	}
	if e, _ := rig.hub.EntityByCharacterID(rig.charID); e.Move != nil {
		t.Fatal("the leg still runs after the use")
	}
}

// The NPC teleport is refused 0x1c14 while a scroll works, before the range
// (Aria stands at Jangan's spawn, far from GATE_CH's building).
func TestRound779NPCTeleportRefusedWhileCasting(t *testing.T) {
	rig := newScrollRig(t, 60)
	if res := rig.use(fixtureReturnScroll, 0, 0); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: OpTeleportUse, Data: clientTeleportUse(1, 2)}, nil, nil); err != nil {
		t.Fatal(err)
	}
	resp, _ := rig.readUntil(OpTeleportResult, 2*time.Second)
	if resp == nil {
		t.Fatal("no teleport reply")
	}
	tr, err := DecodeTeleportResult(resp.Data)
	if err != nil || tr.OK || tr.Code != teleportScrollWorking {
		t.Fatalf("teleport while casting %+v %v; want refused 0x1c14", tr, err)
	}
}

// The thief-den scroll: no character of OpenSRO's is a thief (job state 2),
// so FUN_004a0380's THIEFDEN branch refuses it 0x186a, spending nothing.
func TestRound779ThiefDenRefused(t *testing.T) {
	rig := newScrollRig(t, 60)
	res := rig.use(fixtureThiefDenScroll, 0, 0)
	if res.Code != ScrollErrOnlyRobber || res.Error == "" {
		t.Fatalf("thief-den use %+v; want code 0x186a", res)
	}
	if _, n := rig.slot(fixtureThiefDenScroll); n != 5 {
		t.Fatalf("%d left, want 5", n)
	}
	if rig.caster.Casting(rig.charID) {
		t.Fatal("a refused use started a cast")
	}
}

// The reply's item id round trips, and a reply without it still decodes.
func TestRound779UseResultItemID(t *testing.T) {
	res := &UseItemResult{CastMs: 30000, ItemID: 61, Remaining: 2}
	back, err := DecodeUseItemResult(res.Encode())
	if err != nil || back.ItemID != 61 || back.CastMs != 30000 {
		t.Fatalf("round trip %+v %v", back, err)
	}
	short := res.Encode()
	short = short[:len(short)-4] // a round-778 server
	if back, err := DecodeUseItemResult(short); err != nil || back.ItemID != 0 || back.CastMs != 30000 {
		t.Fatalf("a round-778 reply %+v %v", back, err)
	}
}
