package session

// Round 605's review: the handlers really consult the motion state. Each of
// these fails when its call is removed (see the round's record for the
// mutations).

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
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// seatedWorld is Aria, in the world over in-memory stores with the world,
// combat and skill handlers, a sturdy monster beside her, and a way to sit her
// down without waiting out the transition.
type seatedWorld struct {
	chars   *character.MemStore
	aria    int64
	monster int64
	send    func(opcode uint16, data []byte) *proto.Packet
}

func startSeatedWorld(t *testing.T) *seatedWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
	inv := inventory.NewMemStore(items)
	inv.AddItem(ctx, c.ID, 100, 1)
	eq := equipment.NewMemStore(inv)
	eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0)
	skills := skill.NewMemStore()
	for _, id := range []int64{990, 996} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	m := monsters.Spawn("jangan", "Mangyang", 1, 0, 0, 100000, 0, 0, 0)
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, skills, nil, nil, nil),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	w := &seatedWorld{chars: chars, aria: c.ID, monster: m.ID}
	w.send = func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		for i := 0; i < 8; i++ {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("Read: %v", err)
			}
			if p.Opcode != OpMonsterAttacked && p.Opcode != OpMonsterDamaged && p.Opcode != OpStateChange {
				return p
			}
		}
		t.Fatal("no reply")
		return nil
	}
	if lr, err := DecodeLoginResult(w.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(w.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	t.Cleanup(func() { motions.clear(c.ID) })
	return w
}

// sit seats Aria as if her N had gone through 10 s ago.
func (w *seatedWorld) sit(t *testing.T) {
	t.Helper()
	if _, ok := motions.request(w.aria, MotionSit, time.Now().Add(-10*time.Second)); !ok {
		t.Fatal("could not sit Aria")
	}
	if s := motions.state(w.aria, time.Now()); s != MotionSit {
		t.Fatalf("Aria's state is %#x, want SIT", s)
	}
}

// The skill handler refuses a seated cast of an 'ao'/'pw' skill and lets
// through a skill that carries neither.
func TestSeatedCastGateIsWired(t *testing.T) {
	w := startSeatedWorld(t)
	w.sit(t)
	ar, err := DecodeAttackResult(w.send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 990, TargetMonsterID: w.monster}).Encode()).Data)
	if err != nil || ar.Error != seatedRefusal {
		t.Errorf("a seated cast of an 'ao'/'pw' skill answered %+v (err %v), want %q", ar, err, seatedRefusal)
	}
	ar, err = DecodeAttackResult(w.send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 996, TargetMonsterID: w.monster}).Encode()).Data)
	if err != nil || ar.Error != "" {
		t.Errorf("a seated cast of a skill the gate does not name answered %+v (err %v), want no error", ar, err)
	}
}

// A seated plain swing is not refused: the retail plain attack is a *_BASE_*
// skill, and none of those carries 'ao', 'pw' or 'msch'.
func TestSeatedSwingIsNotRefused(t *testing.T) {
	w := startSeatedWorld(t)
	w.sit(t)
	ar, err := DecodeAttackResult(w.send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: w.monster}).Encode()).Data)
	if err != nil || ar.Error != "" {
		t.Errorf("a seated plain swing answered %+v (err %v), want no error", ar, err)
	}
}

// monsterStrike stands a sitter up when its blow lands (standOnHit).
func TestMonsterStrikeStandsASitter(t *testing.T) {
	f := startDeadWorldFixture(t)
	t.Cleanup(func() { motions.clear(f.aria) })
	if _, ok := motions.request(f.aria, MotionSit, time.Now().Add(-10*time.Second)); !ok {
		t.Fatal("could not sit Aria")
	}
	items := stubCombatItems{}
	deps := strikeDeps{chars: f.chars, eq: equipment.NewMemStore(inventory.NewMemStore(items)), items: items, hub: f.hub}
	m := combat.Monster{ID: 7, Name: "Mangyang", Level: 1, Attack: 20, AttackMin: 20, AttackMax: 20}
	landed := false
	for i := 0; i < 50 && !landed; i++ {
		out, err := monsterStrike(context.Background(), deps, m, combat.MonsterSkill{}, f.aria, 1)
		if err != nil {
			t.Fatal(err)
		}
		landed = out.damage > 0
	}
	if !landed {
		t.Fatal("fifty blows landed nothing; the fixture proves nothing")
	}
	if s := motions.state(f.aria, time.Now()); s != MotionChangeMotion {
		t.Errorf("after a landed blow the sitter's state is %#x, want CHANGEMOTION (getting up)", s)
	}
}

// revivePlayer stands the character, as GObjPC::Revive's SetMotionState(STAND).
func TestReviveStandsTheCharacter(t *testing.T) {
	f := startDeadWorldFixture(t)
	t.Cleanup(func() { motions.clear(f.aria) })
	if _, ok := motions.request(f.aria, MotionSit, time.Now().Add(-10*time.Second)); !ok {
		t.Fatal("could not sit Aria")
	}
	f.kill(t, f.aria, time.Now())
	if _, _, err := revivePlayer(context.Background(), f.chars, nil, f.hub, f.aria); err != nil {
		t.Fatal(err)
	}
	if s := motions.state(f.aria, time.Now()); s != MotionStand {
		t.Errorf("revived at state %#x, want STAND", s)
	}
}
