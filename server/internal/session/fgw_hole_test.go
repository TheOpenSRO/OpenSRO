package session

// Round 869 lane W3 (forgotten_world.md 11 SERVER items 2, 3, 5, 7): the
// Dimension hole's use with each refusal and the success's replies in the
// MEASURED order, the gate's record and select, the entry by the gate (a
// non-creator refused 0x1c2f), the entry notices with the arrival, the gate
// removed with its layer's 10-minute empty close, the hole's cool time kept,
// and the party recall.

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"math/rand"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	holeID      = 35883 // ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_1 (MEASURED row)
	partyHoleID = 35999 // a Param6 = 7 hole (OURS test row: no measured row has 7)
)

type fgwRig struct {
	*gwRig
	inv   *inventory.MemStore
	items *refdata.MemStore
}

func newFGWRig(t *testing.T, levels map[string]int) *fgwRig {
	t.Helper()
	items := refdata.NewMemStore()
	row := refdata.Item{ID: holeID, CodeName: "ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_1", TypeID1: 3, TypeID2: 3, TypeID3: 12,
		TypeID4: 7, MaxStack: 1, CanUse: true, RestoreHP: 1, RestoreMP: 35, RestoreMPPct: 50, Param1: 1, Param5: 4, Param6: 6,
		Desc2: "INS_GOD_TOGUI_35_50_LEVEL_1", CooltimeGroup: 0x71, CooltimeMs: 18000000}
	party7 := row
	party7.ID, party7.CodeName, party7.Param6 = partyHoleID, "ITEM_TEST_PARTY_HOLE", 7
	if err := items.ImportItems(context.Background(), []refdata.Item{row, party7}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	f := &fgwRig{inv: inv, items: items}
	gwRigExtra = func(rig *gwRig) []gateway.Handler {
		return []gateway.Handler{UseItemHandler(rig.chars, inv, items, nil, nil, nil, rig.hub, nil, nil, nil, nil),
			NPCTalkHandler(rig.hub, nil), FGWRecallHandler()}
	}
	defer func() { gwRigExtra = nil }()
	f.gwRig = newGWRig(t, nil, levels)
	fgwTown = func(world.Entity) bool { return true }
	gateRand = rand.New(rand.NewSource(1))
	t.Cleanup(func() {
		fgwTown = nil
		for _, p := range f.players {
			itemCooldowns.clearCharacter(p.charID)
		}
	})
	return f
}

// give puts one item into name's bag and answers its slot.
func (f *fgwRig) give(name string, item int64) int {
	f.t.Helper()
	id := f.players[name].charID
	if err := f.inv.AddItem(context.Background(), id, item, 1); err != nil {
		f.t.Fatal(err)
	}
	slots, _ := f.inv.List(context.Background(), id)
	for _, s := range slots {
		if s.ItemID == item {
			return s.Index
		}
	}
	f.t.Fatal("not given")
	return -1
}

func (f *fgwRig) use(name string, slot int) {
	f.send(name, OpUseItem, (&UseItemRequest{CharacterName: name, InventorySlot: int32(slot)}).Encode())
}

func (f *fgwRig) useResult(name string, slot int) *UseItemResult {
	f.t.Helper()
	f.use(name, slot)
	r, err := DecodeUseItemResult(f.until(name, OpUseItemResult).Data)
	if err != nil {
		f.t.Fatal(err)
	}
	return r
}

// gateOnly drops the single spawns that are not a gate's (the players').
func gateOnly(ps []*proto.Packet) []*proto.Packet {
	var out []*proto.Packet
	for _, p := range ps {
		if p.Opcode == npcspawn.OpSingleSpawn && (len(p.Data) < 4 || binary.LittleEndian.Uint32(p.Data) != gameworld.GateRefObjID) {
			continue
		}
		out = append(out, p)
	}
	return out
}

func (f *fgwRig) held(name string, item int64) bool {
	slots, _ := f.inv.List(context.Background(), f.players[name].charID)
	for _, s := range slots {
		if s.ItemID == item {
			return true
		}
	}
	return false
}

// TestHoleUseRefusals: each refusal in the READ order, the item kept.
func TestHoleUseRefusals(t *testing.T) {
	f := newFGWRig(t, map[string]int{"Aria": 40, "Low": 30, "Bram": 40})
	refused := func(name string, slot int, code uint16) {
		t.Helper()
		r := f.useResult(name, slot)
		if r.Error == "" || r.Code != code {
			t.Errorf("%s: %+v, want the refusal %#04x", name, r, code)
		}
	}
	slot := f.give("Aria", holeID)
	// 1. The field: 0x184b (MEASURED B04C {02, 0x184b}), before the level.
	fgwTown = func(world.Entity) bool { return false }
	refused("Low", f.give("Low", holeID), gameworld.CodeHoleNotTown)
	fgwTown = func(world.Entity) bool { return true }
	// 2. The band 35..50: level 30.
	refused("Low", f.give("Low", holeID), gameworld.CodeHoleLevel)
	// 3. A Param6 = 7 hole: no party, then a party whose master is someone
	// else.
	refused("Aria", f.give("Aria", partyHoleID), gameworld.CodeHolePartyMaster)
	ea, _ := f.hub.EntityByCharacterID(f.players["Aria"].charID)
	eb, _ := f.hub.EntityByCharacterID(f.players["Bram"].charID)
	if _, err := f.parties.Form(party.Member{Session: eb.Session, CharacterID: eb.CharacterID, Name: "Bram", Level: 40},
		party.Member{Session: ea.Session, CharacterID: ea.CharacterID, Name: "Aria", Level: 40}, party.FlagExpShare); err != nil {
		t.Fatal(err)
	}
	refused("Aria", f.give("Aria", partyHoleID), gameworld.CodeHolePartyMaster)
	// 4. Every layer of world 63 in use: 0x1852.
	var open []*gameworld.World
	for i := 0; i < 50; i++ {
		open = append(open, f.open(t))
	}
	refused("Aria", slot, gameworld.CodeHoleNoLayer)
	for _, w := range open {
		w.CloseAsync(gameworld.CloseManual)
		<-w.Done()
	}
	if !f.held("Aria", holeID) || !f.held("Low", holeID) {
		t.Fatal("a refused hole was spent")
	}
	// With Param6 = 6 a party member who is not its master makes a gate
	// (MEASURED); then the cool time refuses the next hole.
	if r := f.useResult("Aria", slot); r.Error != "" {
		t.Fatalf("the party member's hole: %+v", r)
	}
	if r := f.useResult("Aria", f.give("Aria", holeID)); r.Error != reuseDelayRefusal || r.Code != gameworld.CodeHoleCoolTime {
		t.Errorf("a second hole in the cool time: %+v", r)
	}
}

// TestHoleUseSuccess: the replies in the MEASURED order -- the use's
// success, 0x305C {user, item}, 0xB034 {01, 0F, slot, 02}, the gate's 0x3015
// -- the record's fields, the watcher's copies, the spend and the kept cool
// time.
func TestHoleUseSuccess(t *testing.T) {
	f := newFGWRig(t, map[string]int{"Aria": 39, "Bram": 40})
	aria := f.players["Aria"]
	slot := f.give("Aria", holeID)
	f.use("Aria", slot)
	got := gateOnly(f.collect("Aria", 400*time.Millisecond, OpUseItemResult, OpItemUseEffect, OpItemMoveResult, npcspawn.OpSingleSpawn))
	var ops []string
	for _, p := range got {
		ops = append(ops, fmt.Sprintf("%04x", p.Opcode))
	}
	want := fmt.Sprintf("[%04x %04x %04x %04x]", OpUseItemResult, OpItemUseEffect, OpItemMoveResult, npcspawn.OpSingleSpawn)
	if fmt.Sprint(ops) != want {
		t.Fatalf("replies %v, want %s", ops, want)
	}
	if r, _ := DecodeUseItemResult(got[0].Data); r.Error != "" || r.Remaining != 0 || r.ItemID != holeID {
		t.Errorf("use result %+v", r)
	}
	if e, _ := DecodeItemUseEffect(got[1].Data); e.UID != uint32(aria.charID) || e.RefItemID != holeID {
		t.Errorf("0x305C %+v", e)
	}
	if m := fmt.Sprintf("% x", got[2].Data); m != fmt.Sprintf("01 0f %02x 02", slot+ItemWireBagOffset) {
		t.Errorf("0xB034 %s", m)
	}
	rec := got[3].Data
	ea, _ := f.hub.EntityByCharacterID(aria.charID)
	region, lx, lz := regionLocalOf(ea.Zone, ea.Pos)
	u32 := func(at int) uint32 { return binary.LittleEndian.Uint32(rec[at:]) }
	f32 := func(at int) float32 { return math.Float32frombits(u32(at)) }
	uid := u32(4)
	if u32(0) != gameworld.GateRefObjID || binary.LittleEndian.Uint16(rec[8:]) != region ||
		f32(10) != float32(lx) || f32(14) != float32(ea.Pos.Y) || f32(18) != float32(lz) {
		t.Errorf("record head % x", rec[:22])
	}
	// angle u16, then 01 00 01 06, u16 4 "Aria", u32 35883, 01.
	tail := fmt.Sprintf("% x", rec[24:])
	if tail != "01 00 01 06 04 00 41 72 69 61 2b 8c 00 00 01" {
		t.Errorf("record tail %s", tail)
	}
	// Bram, in view: the 0x305C and the gate's spawn too.
	bg := gateOnly(f.collect("Bram", 300*time.Millisecond, OpItemUseEffect, npcspawn.OpSingleSpawn))
	if len(bg) != 2 || bg[0].Opcode != OpItemUseEffect || binary.LittleEndian.Uint32(bg[1].Data[4:]) != uid {
		t.Errorf("the watcher got %v", bg)
	}
	if f.held("Aria", holeID) {
		t.Error("the hole was not spent")
	}
	if itemCooldowns.ReadyItem(aria.charID, holeID, 0x71, time.Now()) {
		t.Error("the cool-time group 0x71 is not armed")
	}
	jobs, _ := f.timed.List(context.Background(), aria.charID)
	if len(jobs) != 1 || jobs[0].Type != TimedJobItemCoolTime || jobs[0].Ref != holeID || jobs[0].End.Sub(jobs[0].Start) != 5*time.Hour {
		t.Errorf("timed jobs %+v, want the category-6 row for 35883, 5 h", jobs)
	}
	// Kept across a relog: the world entry re-arms it.
	itemCooldowns.clearCharacter(aria.charID)
	restoreItemCoolTimes(context.Background(), aria.charID, time.Now())
	if itemCooldowns.ReadyItem(aria.charID, holeID, 0x71, time.Now()) {
		t.Error("the kept cool time was not restored")
	}
	g := gateOf(uid)
	if g == nil || g.World.Ref.ID != 63 || g.Owner != aria.charID {
		t.Fatalf("gate %+v", g)
	}
}

// TestGateSelectEntryAndClose: the gate's select (MEASURED bytes) and its
// end (0x1c0d: no interaction), a non-creator refused 0x1c2f, the creator's
// entry with the entry notices held to its arrival, and the gate gone with
// its layer's empty close (0x3016).
func TestGateSelectEntryAndClose(t *testing.T) {
	f := newFGWRig(t, map[string]int{"Aria": 40, "Bram": 40})
	f.use("Aria", f.give("Aria", holeID))
	spawn := f.until("Aria", npcspawn.OpSingleSpawn)
	for binary.LittleEndian.Uint32(spawn.Data) != gameworld.GateRefObjID {
		spawn = f.until("Aria", npcspawn.OpSingleSpawn)
	}
	uid := binary.LittleEndian.Uint32(spawn.Data[4:])
	g := gateOf(uid)
	f.send("Aria", npctalk.OpSelect, npctalk.EncodeEntity(uid))
	sel := fmt.Sprintf("% x", f.until("Aria", npctalk.OpSelectResult).Data)
	want := fmt.Sprintf("01 % x 01 1c 01 02 e4 7e 27 04 00 00 b5 02 00 00 65 04 00 00", binary.LittleEndian.AppendUint32(nil, uid))
	if sel != want {
		t.Errorf("0xB045 %s, want %s", sel, want)
	}
	f.send("Aria", npctalk.OpEnd, npctalk.EncodeEntity(uid))
	if got := fmt.Sprintf("% x", f.until("Aria", npctalk.OpEndResult).Data); got != "02 0d 1c" {
		t.Errorf("0xB04B after the gate's select: %s, want 02 0d 1c", got)
	}
	// Bram, not the creator: the access rule (type 6).
	if got := f.portalReplies("Bram", uid, 0, 2); got[0] != "02 01 00" || got[1] != "02 2f 1c" {
		t.Errorf("Bram through Aria's gate: %v", got)
	}
	// Aria enters; with the arrival guard on, a notice waits for her 0x3012.
	arrivalGuardOn.Store(true)
	defer arrivalGuardOn.Store(false)
	if got := f.portalReplies("Aria", uid, 0, 2); got[0] != "02 01 00" || got[1] != "01" {
		t.Fatalf("Aria through her gate: %v", got)
	}
	f.until("Aria", OpChangeZoneResult)
	worldMessage(g.World, 1, "UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_MONSTER_KILL", []int64{f.players["Aria"].charID})
	worldMessage(g.World, 2, "UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_MONSTER_KILL", []int64{f.players["Aria"].charID})
	if early := f.collect("Aria", 200*time.Millisecond, OpUniqueNotice, proto.OpTimedJobPush); len(early) != 0 {
		t.Fatalf("sent before the arrival: %d packets", len(early))
	}
	f.send("Aria", OpReadyToPlay, nil)
	after := f.collect("Aria", 400*time.Millisecond, OpUniqueNotice, proto.OpTimedJobPush)
	var kinds []string
	for _, p := range after {
		if p.Opcode == OpUniqueNotice {
			kinds = append(kinds, fmt.Sprintf("notice %d", p.Data[2]))
		} else {
			kinds = append(kinds, "0x320C")
		}
	}
	if fmt.Sprint(kinds) != "[notice 1 notice 2 0x320C 0x320C]" {
		t.Errorf("after the 0x3012: %v, want the banner, the system line, then the 0x320C twice", kinds)
	}
	// Out by the layer's own return (the exit NPC's warp), then the empty
	// close 600 s later takes the gate down.
	if err := returnFromInstance(context.Background(), f.players["Aria"].sess, g.World.Hub, "test"); err != nil {
		t.Fatal(err)
	}
	f.until("Aria", OpChangeZoneResult)
	f.send("Aria", OpReadyToPlay, nil)
	f.clock.Advance(600 * time.Second)
	<-g.World.Done()
	gone := f.until("Bram", npcspawn.OpSingleDespawn)
	for binary.LittleEndian.Uint32(gone.Data) != uid {
		gone = f.until("Bram", npcspawn.OpSingleDespawn)
	}
	if binary.LittleEndian.Uint32(gone.Data) != uid || gateOf(uid) != nil || portalOf(uid) != nil {
		t.Errorf("after the close: despawn % x, gate %v, portal %v", gone.Data, gateOf(uid), portalOf(uid))
	}
}

// TestPartyRecall: the master inside at the recall NPC lists the member,
// summons it (no reply to the master, the push to the member), a second
// summon waits, the member's Yes answers {01} and 5 s later (a test's 50
// ms) it arrives in the master's layer; the refusals.
func TestPartyRecall(t *testing.T) {
	f := newFGWRig(t, map[string]int{"Aria": 40, "Bram": 45, "Cato": 40})
	summonDelay = func() time.Duration { return 50 * time.Millisecond }
	defer func() { summonDelay = func() time.Duration { return gameworld.SummonDelay } }()
	w := f.open(t)
	recall := NextInstanceNPCUID()
	SetInstanceNPCs(w, []npcspawn.NPC{{Record: npcspawn.Record{RefID: 36033, UID: recall, Region: 0x7EE4, X: 1075, Y: 693, Z: 1125,
		Interact: []byte{0x27}}, Code: "NPC_FWORLD_RECALL_PARTY"}}, nil)
	aria, bram, cato := f.players["Aria"], f.players["Bram"], f.players["Cato"]
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	f.until("Aria", OpChangeZoneResult)
	list := func() string {
		f.send("Aria", proto.OpPartyRecallList, binary.LittleEndian.AppendUint32(nil, recall))
		return fmt.Sprintf("% x", f.until("Aria", proto.OpPartyRecallListAck).Data)
	}
	if got := list(); got != "02 33 1c" {
		t.Errorf("no party: %s", got)
	}
	member := func(name string) party.Member {
		e, _ := world.HubOf(f.hub, f.players[name].charID).EntityByCharacterID(f.players[name].charID)
		return party.Member{Session: e.Session, CharacterID: e.CharacterID, Name: name, Level: e.Level}
	}
	p, err := f.parties.Form(member("Aria"), member("Bram"), party.FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.parties.Add(p.ID, member("Cato")); err != nil {
		t.Fatal(err)
	}
	// A wrong NPC: 3.
	f.send("Aria", proto.OpPartyRecallList, binary.LittleEndian.AppendUint32(nil, recall+99))
	if got := fmt.Sprintf("% x", f.until("Aria", proto.OpPartyRecallListAck).Data); got != "02 03 00" {
		t.Errorf("a wrong NPC: %s", got)
	}
	// Cato stands outside a town: impossible (3).
	fgwTown = func(e world.Entity) bool { return e.CharacterID != cato.charID }
	row := func(id int64, state, level byte) string {
		return fmt.Sprintf("% x %02x %02x 00 00", binary.LittleEndian.AppendUint32(nil, uint32(id)), state, level)
	}
	if got, want := list(), "01 02 "+row(bram.charID, 2, 45)+" "+row(cato.charID, 3, 40); got != want {
		t.Errorf("list %s, want %s", got, want)
	}
	f.send("Aria", proto.OpPartyRecallSummon, binary.LittleEndian.AppendUint32(nil, uint32(cato.charID)))
	if got := fmt.Sprintf("% x", f.until("Aria", proto.OpPartyRecallSummonAck).Data); got != "02 37 1c" {
		t.Errorf("Cato outside a town: %s", got)
	}
	// Bram: the push, nothing to Aria; a second summon waits.
	f.send("Aria", proto.OpPartyRecallSummon, binary.LittleEndian.AppendUint32(nil, uint32(bram.charID)))
	push := f.until("Bram", proto.OpPartyRecallSummon).Data
	wantPush := binary.LittleEndian.AppendUint32(nil, uint32(aria.charID))
	wantPush = binary.LittleEndian.AppendUint32(wantPush, uint32(aria.charID))
	wantPush = append(binary.LittleEndian.AppendUint32(wantPush, 5), 4, 0, 'A', 'r', 'i', 'a')
	if fmt.Sprintf("% x", push) != fmt.Sprintf("% x", wantPush) {
		t.Errorf("push % x, want % x", push, wantPush)
	}
	f.send("Aria", proto.OpPartyRecallSummon, binary.LittleEndian.AppendUint32(nil, uint32(bram.charID)))
	if got := fmt.Sprintf("% x", f.until("Aria", proto.OpPartyRecallSummonAck).Data); got != "02 3a 1c" {
		t.Errorf("a second summon: %s", got)
	}
	// Bram's Yes.
	answer := binary.LittleEndian.AppendUint32(nil, uint32(aria.charID))
	answer = append(binary.LittleEndian.AppendUint32(answer, uint32(bram.charID)), 1)
	f.send("Bram", proto.OpPartyRecallAnswer, answer)
	if got := fmt.Sprintf("% x", f.until("Bram", proto.OpPartyRecallAnswerAck).Data); got != "01" {
		t.Errorf("the answer's reply %s", got)
	}
	f.until("Bram", OpChangeZoneResult)
	for i := 0; i < 100 && len(w.Members()) < 2; i++ {
		time.Sleep(5 * time.Millisecond) // the count follows the zone change's result
	}
	if fmt.Sprint(w.Members()) != fmt.Sprint([]int64{aria.charID, bram.charID}) {
		t.Errorf("members %v", w.Members())
	}
	e, _ := w.Hub.EntityByCharacterID(bram.charID)
	if region, _, _ := regionLocalOf(e.Zone, e.Pos); region != 0x7EE4 {
		t.Errorf("Bram arrived in %#x, want the start", region)
	}
	// Now inside: state 1, and its own re-entry limit's 300 minutes.
	inside := fmt.Sprintf("% x 01 2d 2c 01", binary.LittleEndian.AppendUint32(nil, uint32(bram.charID)))
	if got, want := list(), "01 02 "+inside+" "+row(cato.charID, 3, 40); got != want {
		t.Errorf("list after %s, want %s", got, want)
	}
	// Not the master: 0x1c34 (Bram asks).
	f.send("Bram", proto.OpPartyRecallList, binary.LittleEndian.AppendUint32(nil, recall))
	if got := fmt.Sprintf("% x", f.until("Bram", proto.OpPartyRecallListAck).Data); got != "02 34 1c" {
		t.Errorf("Bram's list: %s", got)
	}
}

// clearCharacter forgets every cool time of characterID.
func (t *itemCooldownTracker) clearCharacter(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.until, characterID)
	delete(t.perItem, characterID)
}
