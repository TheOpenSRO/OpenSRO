package session

// Round 872 (fgwreset.go, OURS): the Forgotten World timer reset over a real
// socket -- the Test Items NPC's action line and the entrance ticket clear
// exactly the holes' cool time (row and tracker), the re-entry limit and the
// stored instance row, nothing else; a reset with nothing running says so;
// the refusals; and nothing comes back at a relog.

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"reflect"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/testnpc"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	ticketID   = 36781 // ITEM_MALL_DUNGEON_FREE_TICKET_FORGOTTEN_WORLD (MEASURED row)
	resetNPC   = 11    // the test NPC's uid offset (npcAt)
	resetLine  = 1     // its action id (test_items.json)
	otherGroup = 0xA7  // another item cool time group (a retail one, itemcooldown.go)
)

// resetRig is the FGW rig with the ticket's row, a Test Items NPC offering
// the reset beside Aria, and Aria in its reach.
func newResetRig(t *testing.T) *fgwRig {
	t.Helper()
	f := newFGWRig(t, map[string]int{"Aria": 40})
	ticket := refdata.Item{ID: ticketID, CodeName: "ITEM_MALL_DUNGEON_FREE_TICKET_FORGOTTEN_WORLD", TypeID1: 3, TypeID2: 3,
		TypeID3: 13, TypeID4: 23, MaxStack: 50, CanUse: true, Param1: 1, Desc1: "GROUP_INS_GOD"}
	if err := f.items.ImportItems(context.Background(), []refdata.Item{ticket}); err != nil {
		t.Fatal(err)
	}
	e, _ := f.hub.EntityByCharacterID(f.players["Aria"].charID)
	if e.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", e.Zone)
	}
	f.hub.Relocate(e.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
	npc := npcAt(resetNPC, 50, 0, npcspawn.FromDefinition)
	npc.Flags, npc.Interact, npc.Shop = npcspawn.FlagInteractions, []byte{1}, true
	installNPCsForTest(t, npc)
	shop := &testnpc.Shop{Actions: []testnpc.Action{{ID: resetLine, Label: "Reset Forgotten World Timers",
		Confirm: "UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN", Do: testnpc.ActionResetForgottenWorld}}}
	InstallNPCShopDefs(map[uint32]NPCShopDef{npc.UID: {Payload: (&testnpc.Shop{}).Encode(npc.UID),
		ActionsPayload: shop.EncodeActions(npc.UID), Actions: map[uint8]string{resetLine: testnpc.ActionResetForgottenWorld}}})
	t.Cleanup(func() { InstallNPCShopDefs(nil) })
	return f
}

// reset sends the NPC's action and answers the OpTimersReset.
func (f *fgwRig) reset(name string, uid uint32, id uint8) *TimersReset {
	f.t.Helper()
	f.send(name, testnpc.OpNpcAction, testnpc.EncodeAction(uid, id))
	r, err := DecodeTimersReset(f.until(name, OpTimersReset).Data)
	if err != nil {
		f.t.Fatal(err)
	}
	return r
}

// gateOfLatestUse waits for the gate a hole just made and answers it.
func (f *fgwRig) gateOfLatestUse(name string) *fgwGate {
	f.t.Helper()
	for {
		s := f.until(name, npcspawn.OpSingleSpawn)
		if binary.LittleEndian.Uint32(s.Data) == gameworld.GateRefObjID {
			return gateOf(binary.LittleEndian.Uint32(s.Data[4:]))
		}
	}
}

// enterAndLeave walks name through gate g and back out by the exit's warp.
func (f *fgwRig) enterAndLeave(name string, g *fgwGate) {
	f.t.Helper()
	if got := f.portalReplies(name, g.UID, 0, 2); got[0] != "02 01 00" || got[1] != "01" {
		f.t.Fatalf("%s through the gate: %v", name, got)
	}
	f.until(name, OpChangeZoneResult)
	if err := returnFromInstance(context.Background(), f.players[name].sess, g.World.Hub, "test"); err != nil {
		f.t.Fatal(err)
	}
	f.until(name, OpChangeZoneResult)
}

// relog drops name's connection and logs it in again.
func (f *fgwRig) relog(name string) {
	f.t.Helper()
	p := f.players[name]
	p.conn.Close()
	for deadline := time.Now().Add(3 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, ok := f.hub.EntityByCharacterID(p.charID); !ok {
			break
		}
		if time.Now().After(deadline) {
			f.t.Fatalf("%s did not leave", name)
		}
	}
	conn, err := net.DialTimeout("tcp", f.addr, time.Second)
	if err != nil {
		f.t.Fatal(err)
	}
	conn = &selfIDFilterConn{Conn: conn}
	f.t.Cleanup(func() { conn.Close() })
	p.conn, p.r = conn, bufio.NewReader(conn)
	f.send(name, OpLogin, (&LoginRequest{Username: "u" + name, Password: "pw"}).Encode())
	f.until(name, OpLoginResult)
	f.send(name, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
	f.until(name, OpEnterWorldResult)
	e, ok := f.hub.EntityByCharacterID(p.charID)
	if !ok {
		f.t.Fatalf("%s did not enter again", name)
	}
	p.sess = e.Session
	f.hub.Relocate(e.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
}

// jobKinds is characterID's timed jobs as {type, ref} pairs.
func jobKinds(t *testing.T, st timedjob.Store, characterID int64) [][2]int64 {
	t.Helper()
	jobs, err := st.List(context.Background(), characterID)
	if err != nil {
		t.Fatal(err)
	}
	var out [][2]int64
	for _, j := range jobs {
		out = append(out, [2]int64{int64(j.Type), j.Ref})
	}
	return out
}

// TestFGWResetClearsExactly: a hole used, its layer entered and left -- the
// cool time (row and tracker), the limit and the instance row stand, a
// second hole is refused; the NPC's reset clears those three and leaves
// another item's cool time, a per-item one, a premium job, another group's
// limit and another world's row; at once a new hole opens a new layer and
// its gate lets Aria in.
func TestFGWResetClearsExactly(t *testing.T) {
	f := newResetRig(t)
	ctx := context.Background()
	aria := f.players["Aria"].charID
	f.use("Aria", f.give("Aria", holeID))
	g1 := f.gateOfLatestUse("Aria")
	f.enterAndLeave("Aria", g1)
	// What stands, and the unrelated state that must stay.
	now := time.Now()
	_ = f.timed.Put(ctx, timedjob.Job{CharID: aria, Type: timedjob.TypePremium, Ref: 999, Start: now, End: now.Add(time.Hour)})
	_ = f.timed.Put(ctx, timedjob.Job{CharID: aria, Type: TimedJobWorldGroup, Ref: 2, Key: 5, Start: now, End: now.Add(time.Hour)})
	_ = f.rows.Put(ctx, gameworld.CharInstance{CharID: aria, World: 999, Key: 7})
	itemCooldowns.ArmItem(aria, 22936, otherGroup, time.Hour, now)
	itemCooldowns.ArmItem(aria, 22941, 0, time.Hour, now)
	want := [][2]int64{{int64(timedjob.TypePremium), 999}, {TimedJobItemCoolTime, holeID}, {TimedJobWorldGroup, 1}, {TimedJobWorldGroup, 2}}
	if got := jobKinds(t, f.timed, aria); !reflect.DeepEqual(got, want) {
		t.Fatalf("jobs before %v, want %v", got, want)
	}
	if _, ok, _ := f.rows.Get(ctx, aria, 63); !ok {
		t.Fatal("no instance row for world 63 after the entry")
	}
	if r := f.useResult("Aria", f.give("Aria", holeID)); r.Code != gameworld.CodeHoleCoolTime {
		t.Fatalf("a second hole before the reset: %+v", r)
	}

	r := f.reset("Aria", npcspawn.UIDBase+resetNPC, resetLine)
	if r.Status != TimersResetDone || r.Text != fgwResetDoneText || !reflect.DeepEqual(r.CoolGroups, []uint32{0x71}) ||
		!reflect.DeepEqual(r.WorldGroups, []uint32{1}) {
		t.Fatalf("reset %+v", r)
	}
	want = [][2]int64{{int64(timedjob.TypePremium), 999}, {TimedJobWorldGroup, 2}}
	if got := jobKinds(t, f.timed, aria); !reflect.DeepEqual(got, want) {
		t.Errorf("jobs after %v, want %v", got, want)
	}
	if _, ok, _ := f.rows.Get(ctx, aria, 63); ok {
		t.Error("world 63's instance row survived")
	}
	if _, ok, _ := f.rows.Get(ctx, aria, 999); !ok {
		t.Error("another world's row went")
	}
	now = time.Now()
	if !itemCooldowns.Ready(aria, 0x71, now) {
		t.Error("the holes' group 0x71 still runs in the tracker")
	}
	if itemCooldowns.ReadyItem(aria, 22936, otherGroup, now) || itemCooldowns.ReadyItem(aria, 22941, 0, now) {
		t.Error("another item's cool time went with it")
	}
	// At once: the hole kept from the refusal opens a NEW layer, and its gate
	// lets Aria in (no 0x1c32: the limit is gone).
	slots, _ := f.inv.List(ctx, aria)
	slot := -1
	for _, s := range slots {
		if s.ItemID == holeID {
			slot = s.Index
		}
	}
	if res := f.useResult("Aria", slot); res.Error != "" {
		t.Fatalf("a hole right after the reset: %+v", res)
	}
	g2 := f.gateOfLatestUse("Aria")
	if g2.World == g1.World || g2.World.ID == g1.World.ID {
		t.Fatalf("the new gate leads to the old layer %v", g1.World.ID)
	}
	f.enterAndLeave("Aria", g2)
	if row, ok, _ := f.rows.Get(ctx, aria, 63); !ok || row.Key != g2.World.Key || row.EnterCount != 1 {
		t.Errorf("the new layer's row %+v %v", row, ok)
	}
}

// TestFGWResetNothingAndRefusals: with nothing running the reset says so and
// keeps everything; an id the NPC lacks, a retail NPC and an NPC out of
// reach are refused and clear nothing.
func TestFGWResetNothingAndRefusals(t *testing.T) {
	f := newResetRig(t)
	ctx := context.Background()
	aria := f.players["Aria"].charID
	now := time.Now()
	_ = f.timed.Put(ctx, timedjob.Job{CharID: aria, Type: timedjob.TypePremium, Ref: 999, Start: now, End: now.Add(time.Hour)})
	if r := f.reset("Aria", npcspawn.UIDBase+resetNPC, resetLine); r.Status != TimersResetNothing || r.Text != fgwResetNothingText ||
		len(r.CoolGroups) != 0 || len(r.WorldGroups) != 0 {
		t.Errorf("nothing to reset: %+v", r)
	}
	// Something to clear now, for the refusals to leave alone.
	itemCooldowns.ArmItem(aria, holeID, 0x71, time.Hour, now)
	if r := f.reset("Aria", npcspawn.UIDBase+resetNPC, 9); r.Status != TimersResetRefused || r.Text != fgwResetOfferText {
		t.Errorf("an unknown action: %+v", r)
	}
	if r := f.reset("Aria", npcspawn.UIDBase+77, resetLine); r.Status != TimersResetRefused || r.Text != fgwResetOfferText {
		t.Errorf("an NPC with no definition: %+v", r)
	}
	e, _ := f.hub.EntityByCharacterID(aria)
	f.hub.Relocate(e.Session, world.Position{X: 50 + 2*npcInteractRange, Z: 0}, world.MoveRelocate, 0)
	if r := f.reset("Aria", npcspawn.UIDBase+resetNPC, resetLine); r.Status != TimersResetRefused || r.Text != fgwResetFarText {
		t.Errorf("out of reach: %+v", r)
	}
	if itemCooldowns.Ready(aria, 0x71, time.Now()) {
		t.Error("a refused reset cleared the cool time")
	}
	if got := jobKinds(t, f.timed, aria); len(got) != 1 {
		t.Errorf("jobs %v", got)
	}
}

// TestFGWResetHoldsAcrossRelog: reset, relog, a hole is allowed (nothing in
// memory or the rows brings the cool time back). And the case met on a live
// server: the rows taken away by hand while the character is out, the
// process's tracker still holding the timer -- the login now trusts the rows.
func TestFGWResetHoldsAcrossRelog(t *testing.T) {
	f := newResetRig(t)
	ctx := context.Background()
	aria := f.players["Aria"].charID
	f.use("Aria", f.give("Aria", holeID))
	f.gateOfLatestUse("Aria")
	if r := f.reset("Aria", npcspawn.UIDBase+resetNPC, resetLine); r.Status != TimersResetDone {
		t.Fatalf("reset %+v", r)
	}
	f.relog("Aria")
	if !itemCooldowns.Ready(aria, 0x71, time.Now()) {
		t.Fatal("the relog brought the cool time back")
	}
	if r := f.useResult("Aria", f.give("Aria", holeID)); r.Error != "" {
		t.Fatalf("a hole after reset + relog: %+v", r)
	}
	f.gateOfLatestUse("Aria")
	// The hand-deleted rows: the tracker runs, the rows are gone, relog.
	jobs, _ := f.timed.List(ctx, aria)
	for _, j := range jobs {
		_ = f.timed.Delete(ctx, aria, j.Type, j.Sub, j.Ref)
	}
	if itemCooldowns.Ready(aria, 0x71, time.Now()) {
		t.Fatal("the hole did not arm the tracker")
	}
	f.relog("Aria")
	if r := f.useResult("Aria", f.give("Aria", holeID)); r.Error != "" {
		t.Fatalf("a hole after the rows were deleted and a relog: %+v", r)
	}
	// And a kept row still holds across a relog (round 869's rule).
	f.gateOfLatestUse("Aria")
	f.relog("Aria")
	if r := f.useResult("Aria", f.give("Aria", holeID)); r.Code != gameworld.CodeHoleCoolTime {
		t.Errorf("a kept cool time after a relog: %+v", r)
	}
}

// TestFGWTicket: with nothing to reset the ticket is refused with the
// client's NOT_USED text and kept; after a hole it is spent, answered as a
// use, and the reset follows; the next hole is allowed.
func TestFGWTicket(t *testing.T) {
	f := newResetRig(t)
	aria := f.players["Aria"].charID
	slot := f.give("Aria", ticketID)
	if r := f.useResult("Aria", slot); r.Error != ticketNotUsedKey {
		t.Fatalf("a ticket with nothing to reset: %+v", r)
	}
	if !f.held("Aria", ticketID) {
		t.Fatal("the refused ticket was spent")
	}
	f.use("Aria", f.give("Aria", holeID))
	f.gateOfLatestUse("Aria")
	if r := f.useResult("Aria", slot); r.Error != "" || r.ItemID != ticketID || r.Remaining != 0 {
		t.Fatalf("the ticket's use: %+v", r)
	}
	tr, err := DecodeTimersReset(f.until("Aria", OpTimersReset).Data)
	if err != nil || tr.Status != TimersResetDone || !reflect.DeepEqual(tr.CoolGroups, []uint32{0x71}) {
		t.Fatalf("after the ticket: %+v %v", tr, err)
	}
	if f.held("Aria", ticketID) {
		t.Error("the ticket was not spent")
	}
	if !itemCooldowns.Ready(aria, 0x71, time.Now()) {
		t.Error("the ticket left the cool time")
	}
	if r := f.useResult("Aria", f.give("Aria", holeID)); r.Error != "" {
		t.Errorf("a hole after the ticket: %+v", r)
	}
}

// TestFGWResetLineAtSelect: the select sends the definition, then the action
// lines, then the 0xB045 reply.
func TestFGWResetLineAtSelect(t *testing.T) {
	f := newResetRig(t)
	uid := npcspawn.UIDBase + resetNPC
	f.send("Aria", npctalk.OpSelect, npctalk.EncodeEntity(uid))
	got := f.collect("Aria", 300*time.Millisecond, testnpc.OpNpcShopDef, testnpc.OpNpcActionDef, npctalk.OpSelectResult)
	if len(got) != 3 || got[0].Opcode != testnpc.OpNpcShopDef || got[1].Opcode != testnpc.OpNpcActionDef ||
		got[2].Opcode != npctalk.OpSelectResult {
		t.Fatalf("select sent %v", got)
	}
	u, acts, err := testnpc.DecodeActions(got[1].Data)
	if err != nil || u != uid || len(acts) != 1 || acts[0].ID != resetLine || acts[0].Confirm != "UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN" {
		t.Errorf("OpNpcActionDef %x %+v %v", u, acts, err)
	}
}

// TestTimersResetBytes pins OpTimersReset.
func TestTimersResetBytes(t *testing.T) {
	m := &TimersReset{Status: TimersResetDone, Text: "ok", CoolGroups: []uint32{0x71}, WorldGroups: []uint32{1}}
	b := m.Encode()
	want := []byte{1, 2, 0, 'o', 'k', 1, 0x71, 0, 0, 0, 1, 1, 0, 0, 0}
	if !reflect.DeepEqual(b, want) {
		t.Fatalf("% x, want % x", b, want)
	}
	got, err := DecodeTimersReset(b)
	if err != nil || !reflect.DeepEqual(got, m) {
		t.Fatalf("decode %+v %v", got, err)
	}
	if _, err := DecodeTimersReset(b[:len(b)-1]); err == nil {
		t.Fatal("a truncated message decoded")
	}
}
