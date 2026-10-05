package session

import (
	"bufio"
	"bytes"
	"context"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The retail NPC interaction over a real socket (round 727): select, open,
// end, and their refusals, against an NPC offering ids {1, 2} -- the
// herbalist's set.
func TestNPCTalkSelectOpenEnd(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	accounts.Add("Aria", "pw")
	if _, err := chars.Create(ctx, 1, "Aria"); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	npc := npcAt(5, 100, 0, npcspawn.FromNest)
	npc.Code = "NPC_CH_POTION"
	npc.Shop = true
	npc.Flags, npc.Interact = npcspawn.FlagInteractions, []byte{1, 2}
	// A keeper beside it: ids 1 and 0xc offered, no store run.
	keeper := npcAt(6, 120, 0, npcspawn.FromNest)
	keeper.Code = "NPC_WC_WAREHOUSE_M"
	keeper.Flags, keeper.Interact = npcspawn.FlagInteractions, []byte{1, 3, 0x0c}
	installNPCsForTest(t, npc, keeper)
	t.Cleanup(func() { ForgetNPCInteraction(1) })

	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), NPCTalkHandler(hub, trade.NewHub()))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	c.send(OpLogin, (&LoginRequest{Username: "Aria", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
		t.Fatalf("enter: %v %+v", err, er)
	}
	e, ok := hub.FindByName("Aria")
	if !ok {
		t.Fatal("Aria not in the world")
	}
	if e.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", e.Zone)
	}
	uid := npc.UID
	expect := func(op uint16, want []byte, what string) {
		t.Helper()
		if got := c.next(op).Data; !bytes.Equal(got, want) {
			t.Fatalf("%s: % x, want % x", what, got, want)
		}
	}

	// Out of reach: 400 from the NPC.
	hub.Move(e.Session, world.Position{X: 500, Z: 0})
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(uid))
	expect(npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeTooFar), "select beyond 300")
	// An id nobody has.
	hub.Move(e.Session, world.Position{X: 50, Z: 0})
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(uid+999))
	expect(npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeNoTarget), "select an unknown id")
	// In reach: the reply carries the NPC's set.
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(uid))
	got, err := npctalk.DecodeSelectNPC(c.next(npctalk.OpSelectResult).Data)
	if err != nil || got.Entity != uid || !bytes.Equal(got.IDs, []byte{1, 2}) {
		t.Fatalf("select: %+v %v", got, err)
	}
	// The warehouse is not offered.
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, 3))
	expect(npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeNotOffered), "open an id not offered")
	// The store opens: {1, 1}, INTERACTMODE 6.
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, 1))
	expect(npctalk.OpOpenResult, []byte{1, 1}, "open the store")
	if _, mode := NPCInteractionMode(e.Session.ID()); mode != 6 {
		t.Fatalf("mode after the store %d, want 6", mode)
	}
	// Busy: a second open and a select are refused.
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, 2))
	expect(npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeBusy), "open while open")
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(uid))
	expect(npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeNoTarget), "select while open")
	// The store window closes: 0x704B ends it. A mode-6 end keeps the
	// select's flag (EndInteraction clears it only for mode 5), so a second
	// end still gets {1}, and a third is refused.
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(uid))
	expect(npctalk.OpEndResult, npctalk.EncodeEndOK(), "end")
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(uid))
	expect(npctalk.OpEndResult, npctalk.EncodeEndOK(), "a second end after mode 6")
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(uid))
	expect(npctalk.OpEndResult, npctalk.EncodeFail(npctalk.CodeNoInteraction), "end with nothing open")
	// Withdrawing Skill (10) is not offered below level 20.
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, 10))
	expect(npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeNotOffered), "open 10 at level 1")
	// "Talk to this person.": {1, 2}, INTERACTMODE 5.
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, 2))
	expect(npctalk.OpOpenResult, []byte{1, 2}, "talk")
	if _, mode := NPCInteractionMode(e.Session.ID()); mode != 5 {
		t.Fatalf("mode after talk %d, want 5", mode)
	}
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(uid))
	expect(npctalk.OpEndResult, npctalk.EncodeEndOK(), "end the talk")

	// Id 10 per player (CQSP_ALL_POTION_1/2's event 0xb, level 20): level 19
	// selects {1, 2}, level 20 {1, 2, 10}.
	for _, c19 := range []struct {
		level int
		want  []byte
	}{{19, []byte{1, 2}}, {20, []byte{1, 2, 10}}} {
		hub.SetLevel(e.CharacterID, c19.level)
		c.send(npctalk.OpSelect, npctalk.EncodeEntity(uid))
		sel := c.next(npctalk.OpSelectResult).Data
		if !bytes.Equal(sel, npctalk.EncodeSelectNPC(npctalk.SelectNPC{Entity: uid, IDs: c19.want})) {
			t.Fatalf("level %d select: % x, want ids % x", c19.level, sel, c19.want)
		}
	}
	// At 20 the open of 10 is answered {1, 2} (0x5104a8) with mode 5.
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, 10))
	expect(npctalk.OpOpenResult, []byte{1, 2}, "open withdraw skill at level 20")
	if _, mode := NPCInteractionMode(e.Session.ID()); mode != 5 {
		t.Fatalf("mode after withdraw %d, want 5", mode)
	}
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(uid))
	expect(npctalk.OpEndResult, npctalk.EncodeEndOK(), "end the withdraw")

	// Id 1 at an NPC with no store (a keeper NPC_WC_WAREHOUSE_M): code 3
	// (FUN_00619c10 == 0, 0x5103ba). 0xc sets no mode (+0x1cf0 taken as 0);
	// its answer carries the extra byte.
	kuid := keeper.UID
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(kuid))
	c.next(npctalk.OpSelectResult)
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(kuid, 1))
	expect(npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeNoTarget), "open a store the NPC does not run")
	c.send(npctalk.OpOpen, npctalk.EncodeOpen(kuid, 0x0c))
	expect(npctalk.OpOpenResult, []byte{1, 0x0c, 0}, "open 0xc")
	if _, mode := NPCInteractionMode(e.Session.ID()); mode != 0 {
		t.Fatalf("mode after 0xc %d, want 0", mode)
	}
}

// The select's set per player: id 10 at the herbalists from level 20 only,
// never written into the NPC's own set.
func TestNPCTalkSelectIDs(t *testing.T) {
	herb := &npcspawn.NPC{Code: "NPC_CH_POTION"}
	herb.Interact = []byte{1, 2}
	if got := selectIDs(herb, 19); !bytes.Equal(got, []byte{1, 2}) {
		t.Fatalf("level 19: % x", got)
	}
	if got := selectIDs(herb, 20); !bytes.Equal(got, []byte{1, 2, 10}) {
		t.Fatalf("level 20: % x", got)
	}
	if !bytes.Equal(herb.Interact, []byte{1, 2}) {
		t.Fatalf("the NPC's own set changed: % x", herb.Interact)
	}
	other := &npcspawn.NPC{Code: "NPC_CH_POTION2"}
	other.Interact = []byte{1}
	if got := selectIDs(other, 99); !bytes.Equal(got, []byte{1}) {
		t.Fatalf("a non-herbalist at 99: % x", got)
	}
}
