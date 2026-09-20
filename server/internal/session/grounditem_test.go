package session

import (
	"bufio"
	"context"
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/grounditem"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestGroundItemWireRoundTrips(t *testing.T) {
	snap := GroundItemSnapshot{ID: 7, ItemID: 4, Quantity: 2, Gold: false, X: 1.5, Y: -2, Z: 3.25, OwnerID: 9}
	gold := GroundItemSnapshot{ID: 8, ItemID: grounditem.GoldItemID, Quantity: 57, Gold: true, X: 0, Y: 0, Z: 0}
	list := &GroundItemListResult{Items: []GroundItemSnapshot{snap, gold}}
	got, err := DecodeGroundItemListResult(list.Encode())
	if err != nil || len(got.Items) != 2 || got.Items[0] != snap || got.Items[1] != gold {
		t.Fatalf("list round trip: %+v (err %v), want %+v", got, err, list)
	}
	if _, err := DecodeGroundItemListResult(list.Encode()[:10]); err == nil {
		t.Fatal("a truncated list decoded without error")
	}

	rm := &GroundItemRemoved{ID: 7, Reason: GroundItemRemovedPicked, PickerID: 9}
	if got, err := DecodeGroundItemRemoved(rm.Encode()); err != nil || *got != *rm {
		t.Fatalf("removed round trip: %+v (err %v)", got, err)
	}
	rel := &GroundItemOwnerReleased{ID: 7}
	if got, err := DecodeGroundItemOwnerReleased(rel.Encode()); err != nil || *got != *rel {
		t.Fatalf("owner-released round trip: %+v (err %v)", got, err)
	}
	req := &PickUpRequest{CharacterName: "Aria", GroundItemID: 7}
	if got, err := DecodePickUpRequest(req.Encode()); err != nil || *got != *req {
		t.Fatalf("pick-up request round trip: %+v (err %v)", got, err)
	}
	res := &PickUpResult{Code: grounditem.ErrNotOwner, GroundItemID: 7, ItemID: 4, Quantity: 2, Gold: false}
	if got, err := DecodePickUpResult(res.Encode()); err != nil || *got != *res {
		t.Fatalf("pick-up result round trip: %+v (err %v)", got, err)
	}
}

// A kill leaves its gold and loot on the ground near the corpse, announced
// to the zone; a pick from too far is refused with the engine's code 4;
// walking up (inside 10 units) and picking moves the stack into the bag,
// or the gold into the purse, and the zone hears the item is gone.
func TestGroundDropAndPickUpFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	startGold := c.Gold

	// combat.ItemHPPotion is combat.LootTables["Mangyang"]'s guaranteed drop.
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}, combat.ItemHPPotion: {ID: combat.ItemHPPotion}}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}
	eq := equipment.NewMemStore(inv)
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	ground := grounditem.NewHub()
	// 1 HP, no defence: dies in one hit. 50 units from the spawn (0,0,0), so
	// the corpse's drops are well outside the 10-unit pick range at first.
	const monsterX = 50.0
	monster := monsters.Spawn("jangan", "Mangyang", monsterX, 0, 0, 1, 0, 0, 10)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandlerWithGround(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, skill.NewMemStore(), nil, nil, nil, ground),
		GroundItemHandler(chars, hub, ground, inv, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	write := func(opcode uint16, data []byte) {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
	}
	read := func() *proto.Packet {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	send := func(opcode uint16, data []byte) *proto.Packet { write(opcode, data); return read() }
	// Reads packets until one with the wanted opcode arrives, discarding
	// broadcasts (a monster's death, a damage tick) that are not the point.
	readUntil := func(opcode uint16) *proto.Packet {
		for i := 0; i < 8; i++ {
			if p := read(); p.Opcode == opcode {
				return p
			}
		}
		t.Fatalf("no packet with opcode 0x%04x arrived", opcode)
		return nil
	}

	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	// Walk into reach for the kill. The first swing is gated by the same
	// reach test the keep-up repeats use (playtest 2026-09-20, item 2), so a
	// character standing 50 units off can no longer hit anything -- which is
	// the point of the walk back below, where the pickup is refused for the
	// same distance.
	write(OpMove, (&MoveRequest{X: monsterX - 2, Y: 0, Z: 0}).Encode())
	time.Sleep(50 * time.Millisecond)

	// The kill.
	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode()).Data)
	if err != nil || ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("kill: err=%v result=%+v", err, ar)
	}

	// ...and back to the spawn point, 50 units from the corpse.
	write(OpMove, (&MoveRequest{X: 0, Y: 0, Z: 0}).Encode())
	time.Sleep(50 * time.Millisecond)
	// Gold is not credited on the kill any more: it lies on the ground.
	if after, _ := chars.GetByID(ctx, c.ID); after.Gold != startGold {
		t.Fatalf("gold credited on the kill: %d -> %d, want it on the ground", startGold, after.Gold)
	}

	// Two ground items appear: the gold pile, then the potion.
	var goldItem, potion *GroundItemSnapshot
	for i := 0; i < 2; i++ {
		s, _, err := decodeGroundItemSnapshot(readUntil(OpGroundItemSpawned).Data)
		if err != nil {
			t.Fatalf("decoding spawned item: %v", err)
		}
		switch {
		case s.Gold:
			goldItem = s
		case s.ItemID == combat.ItemHPPotion:
			potion = s
		default:
			t.Fatalf("unexpected ground item %+v", s)
		}
	}
	if goldItem == nil || potion == nil {
		t.Fatalf("expected a gold pile and a potion, got gold=%+v potion=%+v", goldItem, potion)
	}
	if goldItem.Quantity != 10 || goldItem.ItemID != grounditem.GoldItemID || goldItem.OwnerID != c.ID {
		t.Fatalf("gold pile = %+v, want 10 of item %d owned by %d", goldItem, grounditem.GoldItemID, c.ID)
	}
	for _, s := range []*GroundItemSnapshot{goldItem, potion} {
		d := math.Hypot(float64(s.X)-monsterX, float64(s.Z))
		if d > DropScatter+1e-3 || s.Y != 0 {
			t.Fatalf("item %+v landed %.2f from the corpse, want within %.1f on the corpse's plane", s, d, DropScatter)
		}
	}

	// The list agrees.
	lst, err := DecodeGroundItemListResult(send(OpGroundItemList, nil).Data)
	if err != nil || len(lst.Items) != 2 {
		t.Fatalf("ground item list: %+v (err %v), want 2 items", lst, err)
	}

	// Too far from the spawn: the engine's error 4.
	pr, err := DecodePickUpResult(send(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: potion.ID}).Encode()).Data)
	if err != nil || pr.Code != grounditem.ErrTooFar {
		t.Fatalf("pick from 50 units: %+v (err %v), want code 4 (too far)", pr, err)
	}

	// Walk up to it (inside 10 units) and pick: the stack lands in the bag,
	// and the zone (us included) hears the item is gone.
	write(OpMove, (&MoveRequest{X: potion.X, Y: potion.Y, Z: potion.Z - 3}).Encode())
	time.Sleep(50 * time.Millisecond)
	pr, err = DecodePickUpResult(send(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: potion.ID}).Encode()).Data)
	if err != nil || pr.Code != 0 || pr.ItemID != combat.ItemHPPotion || pr.Quantity != potion.Quantity || pr.Gold {
		t.Fatalf("pick in range: %+v (err %v), want the potion", pr, err)
	}
	rm, err := DecodeGroundItemRemoved(readUntil(OpGroundItemRemoved).Data)
	if err != nil || rm.ID != potion.ID || rm.Reason != GroundItemRemovedPicked || rm.PickerID != c.ID {
		t.Fatalf("removed broadcast: %+v (err %v)", rm, err)
	}
	slots, _ := inv.List(ctx, c.ID)
	var inBag bool
	for _, s := range slots {
		if s.ItemID == combat.ItemHPPotion && int32(s.Quantity) == potion.Quantity {
			inBag = true
		}
	}
	if !inBag {
		t.Fatalf("potion not in the bag after the pick: %+v", slots)
	}
	if _, code := ground.PickCheck(potion.ID, c.ID, potion.X, potion.Y, potion.Z, nil); code != grounditem.ErrCannotPick {
		t.Fatalf("picked item still on the ground (code %#x)", code)
	}

	// The gold pile picks up as gold.
	write(OpMove, (&MoveRequest{X: goldItem.X, Y: goldItem.Y, Z: goldItem.Z}).Encode())
	time.Sleep(50 * time.Millisecond)
	pr, err = DecodePickUpResult(send(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: goldItem.ID}).Encode()).Data)
	if err != nil || pr.Code != 0 || !pr.Gold || pr.Quantity != 10 {
		t.Fatalf("pick gold: %+v (err %v)", pr, err)
	}
	readUntil(OpGroundItemRemoved)
	if after, _ := chars.GetByID(ctx, c.ID); after.Gold != startGold+10 {
		t.Fatalf("gold after picking the pile: %d, want %d", after.Gold, startGold+10)
	}
	if lst, err := DecodeGroundItemListResult(send(OpGroundItemList, nil).Data); err != nil || len(lst.Items) != 0 {
		t.Fatalf("ground not empty after both picks: %+v", lst)
	}
}
