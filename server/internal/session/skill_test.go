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
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestLearnSkillRequestRoundTrip(t *testing.T) {
	want := &LearnSkillRequest{CharacterName: "Aria", SkillID: 1}
	got, err := DecodeLearnSkillRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeLearnSkillRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestUseSkillRequestRoundTrip(t *testing.T) {
	want := &UseSkillRequest{CharacterName: "Aria", SkillID: 1, TargetMonsterID: 7}
	got, err := DecodeUseSkillRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeUseSkillRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestSkillFullFlow logs in, enters the world, equips a weapon, learns a
// skill, uses it on a monster (confirming the damage bonus applied), then
// confirms using it again immediately fails with a cooldown error -- all
// through the real server stack over TCP.
func TestSkillFullFlow(t *testing.T) {
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
	inv.TruncateForTest(ctx)
	inv.AddItem(ctx, c.ID, 100, 1)

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)
	eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0)

	skills, err := skill.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("skill.OpenSQLStore: %v", err)
	}
	defer skills.Close()
	skills.TruncateForTest(ctx)

	hub := world.NewHub()
	monsters := combat.NewHub()
	// Skill 1 ("Power Strike") is +15 damage. 30 (weapon) + 15 (skill) - 10
	// (defense) = 35 net damage.
	monster := monsters.Spawn("jangan", "Stone Golem", 100, 10, 5, 500)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, hub),
		LearnSkillHandler(chars, skills),
		UseSkillHandler(chars, eq, items, skills, hub, monsters),
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

	// Using an unlearned skill should fail.
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 1, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "skill not known" {
		t.Fatalf("got %+v, want error 'skill not known'", ar)
	}

	// Learn it.
	resp = send(OpLearnSkill, (&LearnSkillRequest{CharacterName: "Aria", SkillID: 1}).Encode())
	lr, err := DecodeLearnSkillResult(resp.Data)
	if err != nil || !lr.OK {
		t.Fatalf("learn skill failed: err=%v result=%+v", err, lr)
	}

	// Learning it again should fail.
	resp = send(OpLearnSkill, (&LearnSkillRequest{CharacterName: "Aria", SkillID: 1}).Encode())
	lr, err = DecodeLearnSkillResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeLearnSkillResult: %v", err)
	}
	if lr.OK || lr.Reason != "already known" {
		t.Fatalf("got %+v, want OK=false reason='already known'", lr)
	}

	// Use the skill: 30 (weapon) + 15 (skill bonus) - 10 (defense) = 35 damage.
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 1, TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" || ar.MonsterDamage != 35 {
		t.Fatalf("got %+v, want damage=35 (30 weapon + 15 skill - 10 defense)", ar)
	}

	// Using it again immediately should hit the cooldown.
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 1, TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "skill on cooldown" {
		t.Fatalf("got %+v, want error 'skill on cooldown'", ar)
	}
}
