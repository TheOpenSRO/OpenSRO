package session

import (
	"bufio"
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// TestHwanIsEarnedOnTheKillingBlow pins the two deterministic ends of the
// recovered berserk earn rule at the wire: a blow that does not kill adds no
// orb (there is no per-hit fill in the engine -- AddHwanCount is reached only
// from the killing-blow condition Combat_ResolveDamage writes), and a unique
// (rarity 3) kill adds all five orbs with certainty (FUN_00410880's jump
// table: amount 5, chance 10,000,000). An ordinary kill's 8% roll is the
// berserk package's own test; the dice are not forced through the session.
func TestHwanIsEarnedOnTheKillingBlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}} // a weapon: 30 - 0 defence a blow
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
	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// A tough ordinary monster (5000 HP: one blow cannot kill it) and a
	// one-HP unique, at the character's level so no level-gap rule applies.
	tough := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 5000, 0, 0, 0)
	unique := monsters.SpawnSpecies("jangan", combat.Species{Name: "Mangyang", Level: 1, Rarity: berserk.RarityUnique},
		0, 0, 0, 1, 0, 0, 0)

	zerk := berserk.NewTracker()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), zerk, nil, nil),
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
		// Through readReply (round 544): with -monster-strike-push on, the
		// tough monster's counter is followed by its OpMonsterAttacked, and a
		// reader that took the next packet as the next reply decoded that push
		// as the unique kill's result (TestCounterTestsHoldWithTheStrikePushOn).
		return readReply(t, conn, r)
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	// A hit that does not kill: no orb, whatever the dice.
	ar, err := DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: tough.ID}).Encode()).Data)
	if err != nil || ar.Error != "" || ar.MonsterDied {
		t.Fatalf("hit: err=%v result=%+v", err, ar)
	}
	if ar.BerserkGauge != 0 || zerk.Charges(c.ID) != 0 {
		t.Fatalf("a non-killing blow must earn no hwan: gauge %d, charges %d", ar.BerserkGauge, zerk.Charges(c.ID))
	}

	// The unique's killing blow: all five, on the attack result itself.
	ar, err = DecodeAttackResult(send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: unique.ID}).Encode()).Data)
	if err != nil || ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("unique kill: err=%v result=%+v", err, ar)
	}
	if zerk.Charges(c.ID) != berserk.Orbs {
		t.Fatalf("a unique kill pays all five orbs: charges %d", zerk.Charges(c.ID))
	}
	if ar.BerserkGauge != int32(berserk.Max) {
		t.Fatalf("the attack result must carry the earned orbs: gauge %d, want %d", ar.BerserkGauge, berserk.Max)
	}
}
