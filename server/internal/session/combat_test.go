package session

import (
	"bufio"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestAttackRequestRoundTrip(t *testing.T) {
	want := &AttackRequest{CharacterName: "Aria", TargetMonsterID: 7}
	got, err := DecodeAttackRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeAttackRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestAttackResultRoundTrip(t *testing.T) {
	want := &AttackResult{
		MonsterDamage: 15, MonsterRemainingHP: 85, MonsterDied: false,
		PlayerDamageTaken: 8, PlayerHP: 92, PlayerDied: false,
	}
	got, err := DecodeAttackResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestMonsterDamagedRoundTrip(t *testing.T) {
	want := &MonsterDamaged{MonsterID: 1, Damage: 10, RemainingHP: 90}
	got, err := DecodeMonsterDamaged(want.Encode())
	if err != nil {
		t.Fatalf("DecodeMonsterDamaged: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestMonsterDiedRoundTrip(t *testing.T) {
	want := &MonsterDied{MonsterID: 1}
	got, err := DecodeMonsterDied(want.Encode())
	if err != nil {
		t.Fatalf("DecodeMonsterDied: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

type stubCombatItems map[int64]*refdata.Item

func (s stubCombatItems) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	item, ok := s[id]
	if !ok {
		return nil, errNoSuchItem
	}
	return item, nil
}

func (s stubCombatItems) GetMaxStack(_ context.Context, id int64) (int, error) {
	if _, ok := s[id]; !ok {
		return 0, errNoSuchItem
	}
	return 100, nil
}

// TestCombatFullFlow logs in, enters the world, equips a weapon, then
// attacks a monster until it dies, confirming damage/HP/gold-reward
// behavior -- all through the real server stack over TCP.
func TestCombatFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}} // a weapon
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// 30 attack - 10 defense = 20 net damage/hit; 40 HP dies in 2 hits.
	// Monster hits back for 15 whenever it survives a hit.
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 40, 10, 15, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	// First hit: monster 40 -> 20 HP, survives, so it counterattacks for 15
	// (player 100 -> 85 HP).
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" || ar.MonsterDamage != 20 || ar.MonsterRemainingHP != 20 || ar.MonsterDied {
		t.Fatalf("first hit (monster side): got %+v, want damage=20 remaining=20 died=false", ar)
	}
	if ar.PlayerDamageTaken != 15 || ar.PlayerHP != int32(character.StartingMaxHP)-15 || ar.PlayerDied {
		t.Fatalf("first hit (player side): got %+v, want damageTaken=15 hp=%d died=false", ar, character.StartingMaxHP-15)
	}

	// Second hit: monster 20 -> 0 HP, dies -- no counterattack, gold reward
	// granted, player HP unchanged from before.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" || ar.MonsterRemainingHP != 0 || !ar.MonsterDied {
		t.Fatalf("second hit (monster side): got %+v, want remaining=0 died=true", ar)
	}
	if ar.PlayerDamageTaken != 0 || ar.PlayerHP != int32(character.StartingMaxHP)-15 {
		t.Fatalf("second hit (player side): got %+v, want no further damage, hp still %d", ar, character.StartingMaxHP-15)
	}

	list, err := chars.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	wantGold := int64(character.StartingGold) + 500
	if list[0].Gold != wantGold {
		t.Fatalf("got Gold %d, want %d (starting + monster's GoldReward)", list[0].Gold, wantGold)
	}

	// Monster should be gone.
	if _, ok := monsters.Get(monster.ID); ok {
		t.Fatal("expected the monster to be removed after dying")
	}

	// A third attack on the now-dead monster should fail cleanly.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "target not found" {
		t.Fatalf("got %+v, want error 'target not found'", ar)
	}
}

// TestCombatArmorMitigation confirms a monster's counterattack damage is
// reduced by the real defender's equipped armor pieces (equipment.ArmorSlots)
// summed via PhysDefenseMax, with a floor of 1 damage.
func TestCombatArmorMitigation(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{
		100: {ID: 100, PhysAttackMax: 30},  // weapon
		200: {ID: 200, PhysDefenseMax: 4},  // helm
		201: {ID: 201, PhysDefenseMax: 6},  // mail
		202: {ID: 202, PhysDefenseMax: 50}, // shoulderguard, deliberately huge to exercise the floor
	}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	for _, id := range []int64{100, 200, 201, 202} {
		if err := inv.AddItem(ctx, c.ID, id, 1); err != nil {
			t.Fatalf("seeding inventory item %d: %v", id, err)
		}
	}

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotHelm, 1); err != nil {
		t.Fatalf("equipping helm: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotMail, 2); err != nil {
		t.Fatalf("equipping mail: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// Monster hits for 15; helm(4)+mail(6) = 10 defense -> 5 net damage taken.
	// High HP so it survives both hits and keeps counterattacking.
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 200, 10, 15, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	// 15 attack - 10 armor = 5 net damage taken, not the raw 15.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.PlayerDamageTaken != 5 || ar.PlayerHP != int32(character.StartingMaxHP)-5 || ar.PlayerDied {
		t.Fatalf("armored hit: got %+v, want damageTaken=5 hp=%d died=false", ar, character.StartingMaxHP-5)
	}

	// Re-equip the huge-defense shoulderguard and confirm the 1-damage floor
	// -- armor can't reduce a hit below 1, even when it outweighs the attack.
	if err := eq.Equip(ctx, c.ID, equipment.SlotShoulderGuard, 3); err != nil {
		t.Fatalf("equipping shoulderguard: %v", err)
	}
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.PlayerDamageTaken != 1 || ar.PlayerHP != int32(character.StartingMaxHP)-5-1 {
		t.Fatalf("overarmored hit: got %+v, want damageTaken=1 (floor) hp=%d", ar, character.StartingMaxHP-5-1)
	}
}

func TestLootDroppedRoundTrip(t *testing.T) {
	want := &LootDropped{
		MonsterID: 1,
		Drops:     []LootDrop{{ItemID: 500, Quantity: 1}, {ItemID: 600, Quantity: 3}},
	}
	got, err := DecodeLootDropped(want.Encode())
	if err != nil {
		t.Fatalf("DecodeLootDropped: %v", err)
	}
	if got.MonsterID != want.MonsterID || len(got.Drops) != 2 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got.Drops[0] != want.Drops[0] || got.Drops[1] != want.Drops[1] {
		t.Fatalf("drop mismatch: got %+v", got.Drops)
	}
}

// TestCombatLootFlow kills a one-hit monster whose species ("Mangyang")
// has a 100% guaranteed loot entry in combat.LootTables, confirming both
// the OpLootDropped message and the actual inventory.Store state -- not
// just the wire message.
func TestCombatLootFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	// combat.ItemHPPotion is combat.LootTables["Mangyang"]'s guaranteed drop.
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}, combat.ItemHPPotion: {ID: combat.ItemHPPotion}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// 30 attack - 0 defense, 1 HP: dies in one hit.
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1, 0, 0, 10)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil || ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("kill: err=%v result=%+v", err, ar)
	}

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	lootPkt, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("reading OpLootDropped: %v", err)
	}
	if lootPkt.Opcode != OpLootDropped {
		t.Fatalf("got opcode 0x%04x, want OpLootDropped", lootPkt.Opcode)
	}
	ld, err := DecodeLootDropped(lootPkt.Data)
	if err != nil || len(ld.Drops) != 1 || ld.Drops[0].ItemID != combat.ItemHPPotion ||
		ld.Drops[0].Quantity < 1 || ld.Drops[0].Quantity > 2 {
		t.Fatalf("unexpected LootDropped: %+v (err=%v)", ld, err)
	}
	gotQty := ld.Drops[0].Quantity

	slots, err := inv.List(ctx, c.ID)
	if err != nil {
		t.Fatalf("inv.List: %v", err)
	}
	var foundLoot bool
	for _, s := range slots {
		if s.ItemID == combat.ItemHPPotion && s.Quantity == int(gotQty) {
			foundLoot = true
		}
	}
	if !foundLoot {
		t.Fatalf("expected item %d in inventory after loot, got %+v", combat.ItemHPPotion, slots)
	}
}

func TestMonsterListResultRoundTrip(t *testing.T) {
	want := &MonsterListResult{
		Monsters: []MonsterSnapshot{
			{ID: 1, Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", MaxHP: 200, HP: 150},
			{ID: 2, Name: "Weasel", MaxHP: 80, HP: 80}, // no code name: an empty string rides along
		},
	}
	got, err := DecodeMonsterListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeMonsterListResult: %v", err)
	}
	if len(got.Monsters) != 2 || got.Monsters[0] != want.Monsters[0] || got.Monsters[1] != want.Monsters[1] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestMonsterListResultErrorRoundTrip(t *testing.T) {
	want := &MonsterListResult{Error: "not in the world"}
	got, err := DecodeMonsterListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeMonsterListResult: %v", err)
	}
	if got.Error != want.Error || len(got.Monsters) != 0 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestMonsterListFlow confirms a client can discover monster IDs in its
// zone purely from OpMonsterList -- without ever being told an ID any
// other way -- and that the discovered ID actually works against OpAttack.
func TestMonsterListFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	if _, err := chars.Create(ctx, 1, "Aria"); err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	spawned := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1, 0, 0, 10)
	elsewhere := monsters.Spawn("donwhang", "Earth Ghost", 0, 0, 0, 100, 10, 10, 100) // different zone -- shouldn't show up

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	resp = send(OpMonsterList, nil)
	lr, err := DecodeMonsterListResult(resp.Data)
	if err != nil || lr.Error != "" {
		t.Fatalf("monster list failed: err=%v result=%+v", err, lr)
	}
	if len(lr.Monsters) != 1 || lr.Monsters[0].ID != spawned.ID || lr.Monsters[0].Name != "Mangyang" {
		t.Fatalf("got %+v, want only the jangan Mangyang (id %d)", lr.Monsters, spawned.ID)
	}

	// A monster ID from a different zone (never listed, but a real, live ID)
	// should be rejected the same as an unknown one -- a monster is only
	// reachable from its own zone.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: elsewhere.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil || ar.Error != "target not found" {
		t.Fatalf("attack on cross-zone target: got %+v (err=%v), want error 'target not found'", ar, err)
	}
	if updated, ok := monsters.Get(elsewhere.ID); !ok || updated.HP != 100 {
		t.Fatalf("cross-zone target should be untouched, got %+v (ok=%v)", updated, ok)
	}

	// The discovered ID should actually work against OpAttack -- proving
	// this isn't just a decorative list disconnected from the real IDs.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: lr.Monsters[0].ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil || ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("attack using discovered id: err=%v result=%+v", err, ar)
	}
}

// TestLevelAdvantageAppliedInCombat proves the recovered level-difference term
// actually reaches a real fight, in both directions, through the whole stack.
//
// The unit tests in internal/combat pin the formula; this pins the WIRING,
// which is the part that silently does nothing if a level never reaches the
// call. It matters here because the term is guarded on both levels being
// known, and every other integration fixture spawns a level-less monster.
//
// Level 11 monster against the level-1 starting character:
//
//	player's blow  30 attack, mitigated by the monster's own level as the
//	               percentage (11) and its flat 10: round(30/1.11) - 10 = 17,
//	               and NO level bonus, because the player is out-levelled.
//	counterattack  15 flat, no armour, and the monster DOES out-level the
//	               player -- by 10, which is exactly the cap: 15 * 1.30 = 19.5,
//	               rounded to 20.
func TestLevelAdvantageAppliedInCombat(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// AttackMin/Max left zero so the counterattack is the flat 15 and the
	// assertion does not depend on a dice roll.
	monster := monsters.SpawnSpecies("jangan",
		combat.Species{Name: "Stone Ghost", CodeName: "MOB_CH_STONEGHOST", Level: 11},
		0, 0, 0, 500, 10, 15, 0)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode()).Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("attack refused: %s", ar.Error)
	}
	if ar.MonsterDamage != 17 {
		t.Errorf("player's blow = %d, want 17 (out-levelled, so no bonus)", ar.MonsterDamage)
	}
	if ar.PlayerDamageTaken != 20 {
		t.Errorf("counterattack = %d, want 20 (15 * the capped 1.30)", ar.PlayerDamageTaken)
	}
}

// TestDeathPenaltyAppliedInCombat proves the recovered death penalty reaches a
// real death through the whole stack, and that the level-10 grace period holds.
//
// The unit tests in internal/leveldata pin the multipliers; this pins the
// WIRING, which is the half that silently does nothing if the level table or
// the character read is missing. A level-11 character killed by a monster
// loses exp_unit(11) * 100 = 259 * 100 = 25,900 experience and keeps its level.
func TestDeathPenaltyAppliedInCombat(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	// Level 11 with exp banked, so the penalty has something to take and the
	// character is past the grace period.
	const startExp = int64(30000)
	if err := chars.SetLeveling(ctx, c.ID, 11, startExp, 0); err != nil {
		t.Fatalf("setting level: %v", err)
	}

	tbl, err := leveldata.ParseCSV(strings.NewReader(
		"level,exp,mastery_sp,exp_unit\n10,23500,9,235\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	SetLevelTable(tbl)
	defer SetLevelTable(nil)

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 1}} // a feeble weapon
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// Enormous HP so it survives and counterattacks, and enough attack to
	// kill the starting character in one blow.
	monster := monsters.SpawnSpecies("jangan",
		combat.Species{Name: "Stone Ghost", CodeName: "MOB_CH_STONEGHOST", Level: 11},
		0, 0, 0, 100000, 0, 100000, 0)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode()).Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("attack refused: %s", ar.Error)
	}
	if !ar.PlayerDied {
		t.Fatalf("the counterattack should have killed the character, got %+v", ar)
	}
	const wantLoss = int64(259 * leveldata.DeathPenaltyKilledByMonster)
	if ar.DeathExpLost != wantLoss {
		t.Errorf("reported exp loss = %d, want %d", ar.DeathExpLost, wantLoss)
	}
	after, err := chars.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatalf("re-reading character: %v", err)
	}
	if after.Exp != startExp-wantLoss {
		t.Errorf("exp after death = %d, want %d", after.Exp, startExp-wantLoss)
	}
	if after.Level != 11 {
		t.Errorf("level after death = %d, want 11 -- a death never costs a level", after.Level)
	}
}

// The player's mitigation percentage is zero, and that zero is RECOVERED.
//
// A player's ParamKeeper param 7 has three writers and none can set it:
// Char_PublishCombatStats publishes it from the _RefObjItem defence block,
// where a census of all 21,560 item rows finds no percentage-reduction column
// populated; the skill-effect applier reaches it only via the skill param code
// 'ar', which appears on zero of 29,342 real skill rows; and
// GObjMob_PublishStats is mobs only. Monsters DO carry one (characterdata col
// 73 = their level), so the asymmetry is the game's.
//
// Pinned so a later "players should have percentage armour too" edit has to
// delete a citation rather than quietly introduce a value the game never had.
func TestPlayerMitigationPercentIsRecoveredZero(t *testing.T) {
	if playerMitigationPercent != 0 {
		t.Fatalf("player mitigation percent = %d, want 0 -- see the constant's citation",
			playerMitigationPercent)
	}
	// With a zero percentage the engine's shape collapses to the flat
	// subtraction this code used to do by hand, which is why routing it
	// through the shared function changes no number.
	for _, tc := range []struct{ raw, armor, want int }{
		{100, 30, 70},
		{50, 0, 50},
		{10, 9, 1},
		{5, 100, 1}, // never below 1
	} {
		if got := combat.MitigateDamage(tc.raw, playerMitigationPercent, tc.armor); got != tc.want {
			t.Errorf("MitigateDamage(%d, 0, %d) = %d, want %d", tc.raw, tc.armor, got, tc.want)
		}
	}
}

// The monster's critical reaches a real fight and doubles the blow.
//
// Critical 100 is a certainty under the recovered roll (chance >= 100 skips
// the dice entirely), which makes the end-to-end assertion deterministic
// without reaching into the shared generator: the counterattack is 15 flat
// against no armour, doubled to 30, and the monster and player are the same
// level so no level term applies.
func TestMonsterCriticalAppliedInCombat(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.SpawnSpecies("jangan",
		combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", Level: 1, Critical: 100},
		0, 0, 0, 500, 0, 15, 0)
	if got, _ := monsters.Get(monster.ID); got.Critical != 100 {
		t.Fatalf("spawned monster Critical = %d, want 100", got.Critical)
	}

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode()).Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("attack refused: %s", ar.Error)
	}
	if !ar.MonsterCritical {
		t.Fatalf("a critical chance of 100 must always crit, got %+v", ar)
	}
	if ar.PlayerDamageTaken != 15*combat.CriticalMultiplier {
		t.Errorf("counterattack = %d, want %d (15 doubled by the critical)",
			ar.PlayerDamageTaken, 15*combat.CriticalMultiplier)
	}
}

// The player's critical reaches a real fight, from the weapon's own column.
//
// The weapon here carries Critical 100, which the recovered roll treats as a
// certainty without touching the dice -- so the assertion is deterministic.
// 30 attack against a level-1 monster with 0 defence is 30, doubled to 60.
func TestPlayerCriticalAppliedInCombat(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	// A weapon that always crits: Critical is itemdata column 116, which this
	// project already loads as CriticalMin.
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30, CriticalMin: 100}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 5000, 0, 15, 0)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode()).Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("attack refused: %s", ar.Error)
	}
	if !ar.PlayerCritical {
		t.Fatalf("a weapon Critical of 100 must always crit, got %+v", ar)
	}
	if ar.MonsterDamage != 30*combat.CriticalMultiplier {
		t.Errorf("blow = %d, want %d (30 doubled by the critical)",
			ar.MonsterDamage, 30*combat.CriticalMultiplier)
	}
}

// A shield blocks the monster's counterattack outright, and a blocked hit
// deals nothing.
//
// Block ratio 100 is a certainty under the recovered roll, so this is
// deterministic. The monster would otherwise hit for 15.
func TestShieldBlocksInCombat(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{
		100: {ID: 100, PhysAttackMax: 30},
		101: {ID: 101, BlockRatioMin: 100}, // a shield that always blocks
	}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding weapon: %v", err)
	}
	if err := inv.AddItem(ctx, c.ID, 101, 1); err != nil {
		t.Fatalf("seeding shield: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}
	if err := eq.Equip(ctx, c.ID, equipment.SlotShield, 1); err != nil {
		t.Fatalf("equipping shield: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 5000, 0, 15, 0)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode()).Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("attack refused: %s", ar.Error)
	}
	if !ar.PlayerBlocked {
		t.Fatalf("a block ratio of 100 must always block, got %+v", ar)
	}
	if ar.PlayerDamageTaken != 0 {
		t.Errorf("a blocked hit took %d damage, want 0", ar.PlayerDamageTaken)
	}
	if ar.PlayerHP != int32(character.StartingMaxHP) {
		t.Errorf("HP after a blocked hit = %d, want the full %d", ar.PlayerHP, character.StartingMaxHP)
	}
}

// TestWeaponRangePicksTheRightColumnsAndStat exercises combat.WeaponRange
// directly. It used to define its own copy of the selection and assert against
// that, which tests nothing: the production rule changed underneath it and the
// copy went on passing.
//
// Row counts are measured over a real client's itemdata -- 1,582 items carry
// any attack value, 574 physical-only, 448 magical-only, 560 both.
func TestWeaponRangePicksTheRightColumnsAndStat(t *testing.T) {
	staff := &refdata.Item{MagAttackMin: 25, MagAttackMax: 28}
	sword := &refdata.Item{PhysAttackMin: 15, PhysAttackMax: 16, MagAttackMin: 25, MagAttackMax: 28}
	club := &refdata.Item{PhysAttackMin: 7, PhysAttackMax: 9}

	// A magical-only weapon uses the magical columns: 448 real items would
	// otherwise read 0 and land every swing on MitigateDamage's floor of 1.
	if min, max := combat.WeaponRange(staff, 0, 0, combat.AttackPhysical); min != 25 || max != 28 {
		t.Errorf("magical-only weapon: got %d-%d, want 25-28 (not 0-0)", min, max)
	}
	// A physical blow with a weapon carrying both stays physical.
	if min, max := combat.WeaponRange(sword, 0, 0, combat.AttackPhysical); min != 15 || max != 16 {
		t.Errorf("both-carrying weapon, physical blow: got %d-%d, want 15-16", min, max)
	}
	// A MAGICAL blow with that same weapon takes the magical columns. This is
	// the behaviour the damage-type mask unlocked.
	if min, max := combat.WeaponRange(sword, 0, 0, combat.AttackMagical); min != 25 || max != 28 {
		t.Errorf("both-carrying weapon, magical blow: got %d-%d, want 25-28", min, max)
	}
	// A magical blow with a weapon that has no magical damage contributes
	// NOTHING from the weapon. The engine's magical half draws params 15/16,
	// and a physical-only weapon writes param 35 = 0, so the derived term is
	// zero. The blow is not zero overall -- the skill's own flat att damage is
	// added separately as damageBonus -- but the weapon's share is.
	//
	// This is the case the previous tick deliberately did not ship, on two
	// reasons that were both measured wrong afterwards. See combat.WeaponRange.
	if min, max := combat.WeaponRange(club, 0, 0, combat.AttackMagical); min != 0 || max != 0 {
		t.Errorf("physical-only weapon, magical blow: got %d-%d, want 0-0 (the weapon contributes nothing)", min, max)
	}
	if min, max := combat.WeaponRange(nil, 0, 0, combat.AttackPhysical); min != 0 || max != 0 {
		t.Errorf("no item: got %d-%d, want 0-0", min, max)
	}
}

// TestWeaponRangeScalesMagicalDamageWithIntellect pins the stat split recovered
// from GObjPC_InitStats's parameter graph: 1 (str) -> 17 -> 13/14 on the
// physical side, 2 (int) -> 19 -> 15/16 on the magical one. This code passed
// Strength into both halves until 2026-09-16.
func TestWeaponRangeScalesMagicalDamageWithIntellect(t *testing.T) {
	// Reinforce columns are in tenths of a percent; the same figure on both
	// sides isolates which stat is read.
	w := &refdata.Item{
		PhysAttackMin: 10, PhysAttackMax: 10, ReinforcePhysMin: 1000, ReinforcePhysMax: 1000,
		MagAttackMin: 10, MagAttackMax: 10, ReinforceMagMin: 1000, ReinforceMagMax: 1000,
	}
	const str, intel = 100, 40

	pMin, pMax := combat.WeaponRange(w, str, intel, combat.AttackPhysical)
	mMin, mMax := combat.WeaponRange(w, str, intel, combat.AttackMagical)

	wantPhys := 10 + combat.ReinforceDamage(str, 1000)
	wantMag := 10 + combat.ReinforceDamage(intel, 1000)
	if wantPhys == wantMag {
		t.Fatal("test is not discriminating: pick str and intel that differ")
	}
	if pMin != wantPhys || pMax != wantPhys {
		t.Errorf("physical blow: got %d-%d, want %d (Strength)", pMin, pMax, wantPhys)
	}
	if mMin != wantMag || mMax != wantMag {
		t.Errorf("magical blow: got %d-%d, want %d (INTELLECT, not Strength)", mMin, mMax, wantMag)
	}
}
