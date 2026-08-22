package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
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
	monster := monsters.Spawn("jangan", "Stone Golem", 40, 10, 15, 500)

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
		CombatHandler(chars, eq, items, hub, monsters, quests, inv),
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
	if ar.PlayerDamageTaken != 15 || ar.PlayerHP != int32(character.MaxHP)-15 || ar.PlayerDied {
		t.Fatalf("first hit (player side): got %+v, want damageTaken=15 hp=%d died=false", ar, character.MaxHP-15)
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
	if ar.PlayerDamageTaken != 0 || ar.PlayerHP != int32(character.MaxHP)-15 {
		t.Fatalf("second hit (player side): got %+v, want no further damage, hp still %d", ar, character.MaxHP-15)
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
	monster := monsters.Spawn("jangan", "Stone Golem", 200, 10, 15, 500)

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
		CombatHandler(chars, eq, items, hub, monsters, quests, inv),
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
	if ar.PlayerDamageTaken != 5 || ar.PlayerHP != int32(character.MaxHP)-5 || ar.PlayerDied {
		t.Fatalf("armored hit: got %+v, want damageTaken=5 hp=%d died=false", ar, character.MaxHP-5)
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
	if ar.PlayerDamageTaken != 1 || ar.PlayerHP != int32(character.MaxHP)-5-1 {
		t.Fatalf("overarmored hit: got %+v, want damageTaken=1 (floor) hp=%d", ar, character.MaxHP-5-1)
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

// TestCombatLootFlow kills a one-hit monster whose species ("Stone Golem")
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

	// Item 500 matches combat.LootTables["Stone Golem"]'s guaranteed drop.
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}, 500: {ID: 500}}
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
	monster := monsters.Spawn("jangan", "Stone Golem", 1, 0, 0, 10)

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
		CombatHandler(chars, eq, items, hub, monsters, quests, inv),
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
	if err != nil || len(ld.Drops) != 1 || ld.Drops[0].ItemID != 500 || ld.Drops[0].Quantity != 1 {
		t.Fatalf("unexpected LootDropped: %+v (err=%v)", ld, err)
	}

	slots, err := inv.List(ctx, c.ID)
	if err != nil {
		t.Fatalf("inv.List: %v", err)
	}
	var foundLoot bool
	for _, s := range slots {
		if s.ItemID == 500 && s.Quantity == 1 {
			foundLoot = true
		}
	}
	if !foundLoot {
		t.Fatalf("expected item 500 in inventory after loot, got %+v", slots)
	}
}

func TestMonsterListResultRoundTrip(t *testing.T) {
	want := &MonsterListResult{
		Monsters: []MonsterSnapshot{
			{ID: 1, Name: "Stone Golem", MaxHP: 200, HP: 150},
			{ID: 2, Name: "Wild Boar", MaxHP: 80, HP: 80},
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
	spawned := monsters.Spawn("jangan", "Stone Golem", 1, 0, 0, 10)
	elsewhere := monsters.Spawn("donwhang", "Sand Scorpion", 100, 10, 10, 100) // different zone -- shouldn't show up

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
		CombatHandler(chars, eq, items, hub, monsters, quests, inv),
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
	if len(lr.Monsters) != 1 || lr.Monsters[0].ID != spawned.ID || lr.Monsters[0].Name != "Stone Golem" {
		t.Fatalf("got %+v, want only the jangan Stone Golem (id %d)", lr.Monsters, spawned.ID)
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
