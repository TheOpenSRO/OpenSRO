package session

// Round 838 (ammo.go): the arrows and bolts in slot 7 -- the worn stack, the
// gate, the spend per cast (cnsm[2] x hits), the 0x3201 count, the reload
// from the bag's lowest matching stack (cash bit ignored), the removal at
// zero.

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	ammo838Arrow  = 970001 // ITEM_ETC_AMMO_ARROW_01's shape, 3/3/4/1
	ammo838Quiver = 970002 // ITEM_MALL_QUIVER's, 3/3/4/1 and a cash item
	ammo838Bolt   = 970003 // 3/3/4/2
	ammo838Double = 951001 // cnsm (4, 1, 1), mc 2: two arrows a cast
	ammo838Single = 951002 // cnsm (4, 1, 1): one arrow a cast
	ammo838Plain  = 951003 // no cnsm
)

func ammo838Items() stubCombatItems {
	return stubCombatItems{
		ammo838Arrow:  {ID: ammo838Arrow, CodeName: "ITEM_ETC_AMMO_ARROW_01", TypeID1: 3, TypeID2: 3, TypeID3: 4, TypeID4: 1, MaxStack: 100},
		ammo838Quiver: {ID: ammo838Quiver, CodeName: "ITEM_MALL_QUIVER", TypeID1: 3, TypeID2: 3, TypeID3: 4, TypeID4: 1, MaxStack: 100, CashItem: true},
		ammo838Bolt:   {ID: ammo838Bolt, CodeName: "ITEM_ETC_AMMO_BOLT_01", TypeID1: 3, TypeID2: 3, TypeID3: 4, TypeID4: 2, MaxStack: 100},
	}
}

func ammo838Rows() map[int64]*refdata.Skill {
	att := run("att", 4|1, 100, 10, 10, 100)
	base := func(id int64, code string, words []int32) *refdata.Skill {
		return &refdata.Skill{ID: id, GroupID: id, BasicCode: code, BasicLevel: 1, ReqLearnSP: 1, ReqLearnRace: 3,
			Mastery1: 257, AttackPercent: 100, DamageMin: 10, DamageMax: 10, AttackType: 5, HitCount: 1,
			ReqCastWeapon1: 255, ReqCastWeapon2: 255, Range: 1000, TargetRequired: true, ActionKind: 1, ParamWords: words}
	}
	rows := map[int64]*refdata.Skill{
		ammo838Double: base(ammo838Double, "SKILL_CH_BOW_TEST_DOUBLE", words(1, att, run("mc", 2, 2), run("cnsm", 4, 1, 1))),
		ammo838Single: base(ammo838Single, "SKILL_CH_BOW_TEST_SINGLE", words(1, att, run("cnsm", 4, 1, 1))),
		ammo838Plain:  base(ammo838Plain, "SKILL_CH_SWORD_TEST", words(1, att)),
	}
	rows[ammo838Double].HitCount = 2
	return rows
}

type ammo838World struct {
	healWorld
	inv      *inventory.MemStore
	eq       *equipment.MemStore
	monsters *combat.Hub
	me       world.Entity
}

func startAmmo838World(t *testing.T) *ammo838World {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := ammo838Items()
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	skills := skill.NewMemStore()
	rows := ammo838Rows()
	for id := range rows {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	mp := mana.NewTracker()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, r785Ref{rows}, nil, mp, nil),
	)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	sctx, cancel := context.WithCancel(context.Background())
	go srv.ListenAndServe(sctx)
	t.Cleanup(cancel)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	w := &ammo838World{healWorld: healWorld{aria: c.ID, mp: mp, skills: skills, conn: conn, r: bufio.NewReader(conn)},
		inv: inv, eq: eq, monsters: monsters}
	w.send(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.next(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.next(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	me, ok := hub.EntityByCharacterID(c.ID)
	if !ok {
		t.Fatal("not in the world")
	}
	w.me = me
	return w
}

// wear puts n of item into slot 7 through the bag, as the equip does.
func (w *ammo838World) wear(t *testing.T, item int64, n int) {
	t.Helper()
	ctx := context.Background()
	if err := w.inv.AddItem(ctx, w.aria, item, n); err != nil {
		t.Fatal(err)
	}
	slots, _ := w.inv.List(ctx, w.aria)
	for _, sl := range slots {
		if sl.ItemID == item {
			if err := w.eq.Equip(ctx, w.aria, equipment.SlotShield, sl.Index); err != nil {
				t.Fatal(err)
			}
			return
		}
	}
	t.Fatal("the ammunition did not reach the bag")
}

func (w *ammo838World) slot7(t *testing.T) (equipment.Equipped, bool) {
	t.Helper()
	worn, err := w.eq.Get(context.Background(), w.aria)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range worn {
		if e.Slot == equipment.SlotShield {
			return e, true
		}
	}
	return equipment.Equipped{}, false
}

// castCounted casts row at a fresh dummy and returns the 0x3201 count and the
// result.
func (w *ammo838World) castCounted(t *testing.T, row int64) (int, *AttackResult) {
	t.Helper()
	m := w.monsters.Spawn(w.me.Zone, "Dummy", w.me.Pos.X+10, w.me.Pos.Y, w.me.Pos.Z, 100000, 0, 0, 0)
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: row, TargetMonsterID: m.ID}).Encode())
	p := w.next(t, OpAmmoCount)
	if len(p.Data) != 2 {
		t.Fatalf("0x3201 body %x, want a u16", p.Data)
	}
	ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	return int(binary.LittleEndian.Uint16(p.Data)), ar
}

func TestAmmoWornStackMovesWhole(t *testing.T) {
	ctx := context.Background()
	inv := inventory.NewMemStore(ammo838Items())
	eq := equipment.NewMemStore(inv)
	if err := inv.AddItem(ctx, 1, ammo838Quiver, 70); err != nil {
		t.Fatal(err)
	}
	if err := eq.Equip(ctx, 1, equipment.SlotShield, 0); err != nil {
		t.Fatal(err)
	}
	worn, _ := eq.Get(ctx, 1)
	if len(worn) != 1 || worn[0].Count() != 70 {
		t.Fatalf("worn %+v, want the whole stack of 70", worn)
	}
	if bag, _ := inv.List(ctx, 1); len(bag) != 0 {
		t.Fatalf("the bag kept %+v", bag)
	}
	if err := eq.Unequip(ctx, 1, equipment.SlotShield); err != nil {
		t.Fatal(err)
	}
	bag, _ := inv.List(ctx, 1)
	if len(bag) != 1 || bag[0].Quantity != 70 {
		t.Fatalf("unequipped back %+v, want 70", bag)
	}
}

// The gate: a cnsm row with nothing in slot 7 is refused 0x300e's line for
// the caster's race, before anything is spent; a row without cnsm is not.
func TestAmmoGateRefusesEmptySlot(t *testing.T) {
	w := startAmmo838World(t)
	m := w.monsters.Spawn(w.me.Zone, "Dummy", w.me.Pos.X+10, w.me.Pos.Y, w.me.Pos.Z, 100000, 0, 0, 0)
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: ammo838Single, TargetMonsterID: m.ID}).Encode())
	ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
	if err != nil || ar.Error != ammoRefusalArrows {
		t.Fatalf("result %+v %v, want %q", ar, err, ammoRefusalArrows)
	}
	if got, _ := w.monsters.Get(m.ID); got.HP != 100000 {
		t.Fatal("a refused cast struck")
	}
	// Bolts do not feed a bow's cnsm (4, 1).
	w.wear(t, ammo838Bolt, 5)
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: ammo838Single, TargetMonsterID: m.ID}).Encode())
	if ar, _ := DecodeAttackResult(w.next(t, OpAttackResult).Data); ar.Error != ammoRefusalArrows {
		t.Fatalf("bolts for a bow: %+v", ar)
	}
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: ammo838Plain, TargetMonsterID: m.ID}).Encode())
	if ar, _ := DecodeAttackResult(w.next(t, OpAttackResult).Data); ar.Error != "" {
		t.Fatalf("a row without cnsm was refused: %q", ar.Error)
	}
	if e, _ := w.slot7(t); e.Count() != 5 {
		t.Fatalf("a row without cnsm spent: %d", e.Count())
	}
}

// The spend, the cut at the last arrow, the reload from the LOWEST matching
// bag stack (a cash quiver refills an ordinary arrow; a bolt is skipped), and
// the removal when nothing is left to reload.
func TestAmmoSpendReloadAndRemove(t *testing.T) {
	ctx := context.Background()
	w := startAmmo838World(t)
	w.wear(t, ammo838Arrow, 5)
	if err := w.inv.AddItem(ctx, w.aria, ammo838Bolt, 9); err != nil { // bag slot 0
		t.Fatal(err)
	}
	if err := w.inv.AddItem(ctx, w.aria, ammo838Quiver, 3); err != nil { // bag slot 1
		t.Fatal(err)
	}
	for _, want := range []int{3, 1} {
		n, ar := w.castCounted(t, ammo838Double)
		if ar.Error != "" || n != want {
			t.Fatalf("a two-hit cast: count %d (%q), want %d", n, ar.Error, want)
		}
	}
	// One left, two wanted: the cast still flies and takes the last.
	n, ar := w.castCounted(t, ammo838Double)
	if ar.Error != "" || n != 0 {
		t.Fatalf("the last arrow: count %d (%q), want 0", n, ar.Error)
	}
	e, ok := w.slot7(t)
	if !ok || e.ItemID != ammo838Quiver || e.Count() != 3 {
		t.Fatalf("after the reload slot 7 holds %+v, want the quiver's 3", e)
	}
	bag, _ := w.inv.List(ctx, w.aria)
	if len(bag) != 1 || bag[0].ItemID != ammo838Bolt || bag[0].Quantity != 9 {
		t.Fatalf("the bag after the reload %+v, want only the 9 bolts", bag)
	}
	for _, want := range []int{2, 1, 0} {
		if n, ar := w.castCounted(t, ammo838Single); ar.Error != "" || n != want {
			t.Fatalf("a one-arrow cast: count %d (%q), want %d", n, ar.Error, want)
		}
	}
	if e, ok := w.slot7(t); ok {
		t.Fatalf("an empty slot 7 with nothing to reload still holds %+v", e)
	}
	m := w.monsters.Spawn(w.me.Zone, "Dummy", w.me.Pos.X+10, w.me.Pos.Y, w.me.Pos.Z, 100000, 0, 0, 0)
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: ammo838Single, TargetMonsterID: m.ID}).Encode())
	if ar, _ := DecodeAttackResult(w.next(t, OpAttackResult).Data); ar.Error != ammoRefusalArrows {
		t.Fatalf("after the last arrow: %+v", ar)
	}
}

// Arrows put on under a bow do not take the bow off: ammunition holds no
// hand (twoHandedDisplaced), unlike a shield.
func TestAmmoBesideTwoHandedBow(t *testing.T) {
	ctx := context.Background()
	items := ammo838Items()
	items[970010] = &refdata.Item{ID: 970010, CodeName: "ITEM_CH_BOW_01_A", TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 6, TwoHanded: true, MaxStack: 1}
	items[970011] = &refdata.Item{ID: 970011, CodeName: "ITEM_CH_SHIELD_01_A", TypeID1: 3, TypeID2: 1, TypeID3: 4, TypeID4: 1, MaxStack: 1}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	_ = inv.AddItem(ctx, 1, 970010, 1)
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, 0); err != nil {
		t.Fatal(err)
	}
	_ = inv.AddItem(ctx, 1, ammo838Arrow, 50)
	if _, ok := twoHandedDisplaced(ctx, eq, inv, items, 1, equipment.SlotShield, 0); ok {
		t.Fatal("arrows for slot 7 would take the bow off")
	}
	if err := eq.Equip(ctx, 1, equipment.SlotShield, 0); err != nil {
		t.Fatal(err)
	}
	// A shield still would, and a bow put on over worn arrows does not count
	// them as a shield.
	_ = inv.AddItem(ctx, 1, 970011, 1)
	slots, _ := inv.List(ctx, 1)
	if other, ok := twoHandedDisplaced(ctx, eq, inv, items, 1, equipment.SlotShield, slots[0].Index); !ok || other != equipment.SlotWeapon {
		t.Fatalf("a shield under the bow: %v %v, want the weapon displaced", other, ok)
	}
	_ = inv.AddItem(ctx, 1, 970010, 1)
	slots, _ = inv.List(ctx, 1)
	for _, sl := range slots {
		if sl.ItemID == 970010 {
			if _, ok := twoHandedDisplaced(ctx, eq, inv, items, 1, equipment.SlotWeapon, sl.Index); ok {
				t.Fatal("a bow over worn arrows took the arrows off")
			}
		}
	}
}

// A worn stack's count is in the worn list's record (an expendable's u16).
func TestAmmoWornInfoCarriesCount(t *testing.T) {
	infos := wornItemInfos(context.Background(), []equipment.Equipped{{Slot: equipment.SlotShield, ItemID: ammo838Quiver, Quantity: 9876}}, ammo838Items())
	if len(infos) != 1 || infos[0].Slot != int(equipment.SlotShield) || len(infos[0].Tail) != 2 || binary.LittleEndian.Uint16(infos[0].Tail) != 9876 {
		t.Fatalf("infos %+v", infos)
	}
}
