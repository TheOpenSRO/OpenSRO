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
	want := &AttackResult{Damage: 15, RemainingHP: 85, Died: false}
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
	monster := monsters.Spawn("jangan", "Stone Golem", 40, 10, 500)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, hub),
		CombatHandler(chars, eq, items, hub, monsters),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r)
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

	// First hit: 40 -> 20 HP, not dead.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" || ar.Damage != 20 || ar.RemainingHP != 20 || ar.Died {
		t.Fatalf("first hit: got %+v, want damage=20 remaining=20 died=false", ar)
	}

	// Second hit: 20 -> 0 HP, dead. Gold reward granted.
	resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" || ar.RemainingHP != 0 || !ar.Died {
		t.Fatalf("second hit: got %+v, want remaining=0 died=true", ar)
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
