package session

import (
	"bufio"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 737's review: the regressions its findings name, kept as tests.

// holds reports whether characterID's open view holds other.
func holds(characterID, other int64) bool {
	v := playerViewOf(characterID)
	if v == nil {
		return false
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	_, ok := v.known[other]
	return ok && v.open
}

// F3, the reviewer's probe (TestReview737EntryRace) kept as a regression: a
// player who walks into the arriver's window between hub.Enter and the
// arriver's OpEnterWorldResult. Before the fix Aria's client was sent Bram's
// move and his 0x3015 BEFORE her result -- which her client drops -- and her
// view never held him. Now nothing about him reaches her before the result,
// she is spawned him once after it, and both views hold the other.
func TestEntryRaceSpawnsWhoWalkedInDuringTheEntry(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	hub := world.NewHub()
	addr, cleanup := startTestServer(t, gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub)))
	t.Cleanup(cleanup)
	f := &deadWorldFixture{chars: chars, hub: hub, aria: aria.ID, bram: bram.ID}
	f.connB = dialTestServer(t, addr)
	t.Cleanup(func() { f.connB.Close() })
	f.rB = bufio.NewReader(f.connB)
	f.login(t, f.connB, f.rB, "bob", "hunter3", "Bram")
	eb, _ := hub.FindByName("Bram")
	home := eb.Pos
	// Bram goes far away, out of the spawn's window.
	f.send(t, f.connB, OpMove, (&MoveRequest{X: float32(home.X + 5000), Y: float32(home.Y), Z: float32(home.Z), Relocated: true}).Encode())
	deadline := time.Now().Add(2 * time.Second)
	for {
		if e, _ := hub.FindByName("Bram"); e.Pos.X > home.X+4000 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("setup: Bram's move was not taken")
		}
		time.Sleep(5 * time.Millisecond)
	}

	// Aria arrives at the spawn; in the gap, Bram comes back into her window,
	// as handleMove would bring him.
	enterWorldBeforeResultHook = func(*gateway.Session) {
		moved, ok := hub.Relocate(eb.Session, home, world.MoveRelocate, 0)
		if !ok || !moved.Crossed || len(moved.Gained) != 1 {
			t.Errorf("setup: crossed=%v gained=%d", moved.Crossed, len(moved.Gained))
		}
		afterRelocate(eb.Session, moved, false, gateway.MustFrame(&proto.Packet{Opcode: OpEntityMoved, Data: (&EntityMoved{CharacterID: bram.ID}).Encode()}))
	}
	t.Cleanup(func() { enterWorldBeforeResultHook = nil })
	f.connA = dialTestServer(t, addr)
	t.Cleanup(func() { f.connA.Close() })
	f.rA = bufio.NewReader(f.connA)
	f.send(t, f.connA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	f.read(t, f.connA, f.rA)
	f.send(t, f.connA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEnterWorldResult {
		t.Fatalf("Aria's first frame after her request is %#04x, want OpEnterWorldResult: nothing about Bram may come before it", p.Opcode)
	}
	// After it, Bram's spawn, once.
	expectPlayerSpawn(t, f.connA, f.rA, bram.ID)
	// Bram's side: spawned Aria once -- by his own crossing, which found her
	// in the hub; her arrival does not send her again (the same arrival).
	expectPlayerSpawn(t, f.connB, f.rB, aria.ID)
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a second spawn followed")
	}
	if !f.sees(aria.ID, bram.ID) || !holds(aria.ID, bram.ID) || !holds(bram.ID, aria.ID) {
		t.Fatalf("hub in view %v; Aria holds Bram %v; Bram holds Aria %v -- want all true",
			f.sees(aria.ID, bram.ID), holds(aria.ID, bram.ID), holds(bram.ID, aria.ID))
	}
	// And his moves reach her now.
	f.send(t, f.connB, OpMove, (&MoveRequest{X: float32(home.X + 10), Y: float32(home.Y), Z: float32(home.Z)}).Encode())
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpMovementStop {
		t.Fatalf("Bram's move reached Aria as %#04x, want 0xB023", p.Opcode)
	}
}

// F3 at a zone change: Bram warps to the landing of the one bucket
// (-single-frame) while Aria, far off in it, walks onto that landing in the
// gap between the hub's change and his result. His old view is dropped at the
// change, so no spawn lands in a view about to be thrown away, and his
// arrival spawns her from the window as it is after the result.
func TestZoneChangeRaceSpawnsWhoWalkedInDuringTheChange(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	f := startDeadWorldFixture(t)
	ea, _ := f.hub.EntityByCharacterID(f.aria)
	home := ea.Pos
	// Aria goes far off: Bram, beside her, drops her.
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(home.X + 5000), Y: float32(home.Y), Z: float32(home.Z), Relocated: true}).Encode())
	expectPlayerDespawn(t, f.connB, f.rB, f.aria)
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)

	warpBeforeResultHook = func(sess *gateway.Session) {
		if sess != ea.Session {
			moved, ok := f.hub.Relocate(ea.Session, home, world.MoveRelocate, 0)
			if !ok || !moved.Crossed {
				t.Errorf("setup: Aria's move back crossed=%v", moved.Crossed)
			}
			afterRelocate(ea.Session, moved, false, gateway.MustFrame(&proto.Packet{Opcode: OpEntityMoved, Data: (&EntityMoved{CharacterID: f.aria}).Encode()}))
		}
	}
	t.Cleanup(func() { warpBeforeResultHook = nil })
	czr := changeZone(t, f, f.connB, f.rB, "jangan")
	if !czr.OK {
		t.Fatalf("Bram's warp to jangan: %+v", czr)
	}
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
	expectPlayerSpawn(t, f.connA, f.rA, f.bram)
	if !f.nothing(t, f.connA, f.rA) || !f.nothing(t, f.connB, f.rB) {
		t.Fatal("a second spawn followed")
	}
	if !holds(f.aria, f.bram) || !holds(f.bram, f.aria) {
		t.Fatalf("Aria holds Bram %v; Bram holds Aria %v -- want both", holds(f.aria, f.bram), holds(f.bram, f.aria))
	}
}

// F3's third part: a session in the hub with no view (one put there
// directly) is sent no player spawn or despawn.
func TestASessionWithNoViewIsSentNoSpawn(t *testing.T) {
	f := startDeadWorldFixture(t)
	ea, _ := f.hub.EntityByCharacterID(f.aria)
	// A third character put in the hub directly, beside Aria: its session
	// has no view, and Aria's arrival-style spawn to others skips it.
	recorder := gateway.NewTestSession(99)
	f.hub.Enter(recorder, 300, "Cyra", 1, ea.Zone, ea.Pos)
	defer f.hub.Leave(recorder)
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("a spawn or despawn was sent to the session with no view (%v)", r)
		}
	}()
	d := viewDeps{hub: f.hub}
	spawnPlayerToOthers(d, ea, []world.Entity{{Session: recorder, CharacterID: 300, Name: "Cyra", Zone: ea.Zone, Pos: ea.Pos}})
	departPlayer(f.hub, ea, []world.Entity{{Session: recorder, CharacterID: 300}})
	despawnPlayerFromOthers(d, ea, []world.Entity{{Session: recorder, CharacterID: 300}})
}

// F10: a reconnect whose old session leaves after the new one entered. The
// old session's leave must not despawn the character that is live on the
// new one.
func TestALateLeaveOfAStaleSessionKeepsTheLiveBody(t *testing.T) {
	f := startDeadWorldFixture(t)
	addr := f.connA.RemoteAddr().String()
	// Aria logs in again on a second connection, before the first one is
	// gone: Bram is spawned her again where she now is.
	conn2 := dialTestServer(t, addr)
	t.Cleanup(func() { conn2.Close() })
	r2 := bufio.NewReader(conn2)
	f.login(t, conn2, r2, "alice", "hunter2", "Aria")
	expectPlayerSpawn(t, conn2, r2, f.bram)
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
	// The old connection goes.
	f.connA.Close()
	if !f.nothing(t, f.connB, f.rB) {
		t.Fatal("Bram was told something when Aria's stale session left")
	}
	if !holds(f.bram, f.aria) {
		t.Fatal("Bram no longer holds Aria, live on her new session")
	}
}

// F7: a player's abnormal states follow its spawn, as its buffs do.
func TestASpawnCarriesTheAbnormalStates(t *testing.T) {
	f := startDeadWorldFixture(t)
	statusFX.mu.Lock()
	h := &statuseffect.Holder{}
	h.Put(statuseffect.Record{Code: "test", Slot: 2, Bit: 3, DurationMs: 60000})
	statusFX.pcs[f.aria] = h
	statusFX.mu.Unlock()
	t.Cleanup(func() {
		statusFX.mu.Lock()
		delete(statusFX.pcs, f.aria)
		statusFX.mu.Unlock()
	})
	// Bram goes to donwhang and back: Aria's spawn, then her state.
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram to donwhang: %+v", czr)
	}
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)
	if czr := changeZone(t, f, f.connB, f.rB, "jangan"); !czr.OK {
		t.Fatalf("Bram back: %+v", czr)
	}
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
	p := f.read(t, f.connB, f.rB)
	st, err := DecodeObjectStatus(p.Data)
	if p.Opcode != OpObjectStatus || err != nil || st.OwnerID != f.aria || st.Mask != 0x8 {
		t.Fatalf("after Aria's spawn Bram got %#04x %+v (%v), want her status mask 0x8", p.Opcode, st, err)
	}
	expectPlayerSpawn(t, f.connA, f.rA, f.bram)
}

// ammoItems answers an arrow as TypeID 3/3/4 and anything else as armour.
type ammoItems struct{}

func (ammoItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	if id == 62 {
		return &refdata.Item{ID: 62, TypeID1: 3, TypeID2: 3, TypeID3: 4, TypeID4: 1}, nil
	}
	if id == 0 {
		return nil, errors.New("no item")
	}
	return &refdata.Item{ID: id, TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 3}, nil
}

// F1: arrows worn in equip slot 7 carry no plus byte in the spawn record,
// as the engine writes and its client reads them (TypeID 3/1 only), so the
// record reads to its end and a group of records after it still reads.
func TestArrowsInTheRecordCarryNoPlus(t *testing.T) {
	ctx := context.Background()
	SetSpawnItemRefs(ammoItems{})
	t.Cleanup(func() { SetSpawnItemRefs(nil) })
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Archer")
	for _, w := range []struct {
		item int64
		slot equipment.Slot
		plus uint8
	}{{3643, equipment.SlotMail, 5}, {62, equipment.SlotShield, 0}} {
		if err := inv.AddItemInstance(ctx, c.ID, w.item, 1, inventory.Instance{OptLevel: w.plus}); err != nil {
			t.Fatal(err)
		}
		slots, _ := inv.List(ctx, c.ID)
		idx := -1
		for _, s := range slots {
			if s.ItemID == w.item {
				idx = s.Index
			}
		}
		if err := eq.Equip(ctx, c.ID, w.slot, idx); err != nil {
			t.Fatalf("equip %d: %v", w.item, err)
		}
	}
	invalidateLook(c.ID)
	hub := world.NewHub()
	sess := gateway.NewTestSession(1)
	hub.Enter(sess, c.ID, c.Name, 1, spawnZone, world.Position{})
	e, _ := hub.EntityBySession(1)
	rec := playerRecord(viewDeps{ctx: ctx, hub: hub, eq: eq, chars: chars}, e, time.Now())
	twice := append(append([]byte(nil), rec...), rec...)
	d, rest, err := pcspawn.Decode(twice, clientTypes{})
	if err != nil || len(d.Items) != 2 || d.Items[0].Plus != 5 || !d.Items[0].HasPlus || d.Items[1].HasPlus {
		t.Fatalf("the archer's record read as %+v (err %v)", d.Items, err)
	}
	if _, rest, err = pcspawn.Decode(rest, clientTypes{}); err != nil || len(rest) != 0 {
		t.Fatalf("the record after it: %v, %d byte(s) left", err, len(rest))
	}
	invalidateLook(c.ID)
}

// clientTypes is the client's reading rule: a plus byte for 3/1 only.
type clientTypes struct{}

func (clientTypes) HasPlus(id uint32) bool             { return id != 62 }
func (clientTypes) JobState(items []pcspawn.Item) byte { return pcspawn.JobStateNone }

var _ = npcspawn.OpSingleSpawn
