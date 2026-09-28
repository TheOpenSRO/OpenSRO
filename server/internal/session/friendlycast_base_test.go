package session

// Round 622: a friendly Target_Required 1 cast (Heal) with nothing selected,
// or at a monster, is refused before anything is spent. These two use only
// what the handler had before round 622 (the negative runs them against it).
// The Heal row is typed with the values MEASURED on the retail skilldata on
// the RE box (no game data in the repo).

import (
	"bufio"
	"context"
	"errors"
	"net"
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
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// SKILL_CH_WATER_HEAL_A_01: id 149, group 296, kind 0, Target_Required 1,
// TargetGroup Self/Ally/Party, Range 150, prep/cast 1000/1000, reuse 3000,
// MP 74, (heal 369, 0, 0, 0) -- MEASURED (/var/tmp/allskills.txt).
const skHealA1 = 149

type healSkillRef struct{}

func (healSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if id == skHealA1 {
		return &refdata.Skill{ID: id, GroupID: 296, BasicLevel: 1, ActionKind: 0, TargetRequired: true,
			TargetSelf: true, TargetAlly: true, TargetParty: true, Range: 150,
			PreparingTimeMs: 1000, CastingTimeMs: 1000, ReuseDelayMs: 3000, ConsumeMP: 74,
			NoCombatParam: true, ZeroDamage: true}, nil
	}
	return nil, errors.New("no such skill")
}

type healWorld struct {
	aria    int64
	monster int64
	mp      *mana.Tracker
	skills  *skill.MemStore
	conn    net.Conn
	r       *bufio.Reader
}

func startHealWorld(t *testing.T) *healWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	skills := skill.NewMemStore()
	if err := skills.Learn(ctx, c.ID, skHealA1); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	m := monsters.Spawn("jangan", "Mangyang", 1, 5000, 0, 5000, 100000, 0, 0)
	mp := mana.NewTracker()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, healSkillRef{}, nil, mp, nil),
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
	w := &healWorld{aria: c.ID, monster: m.ID, mp: mp, skills: skills, conn: conn, r: bufio.NewReader(conn)}
	w.send(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.next(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.next(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	return w
}

func (w *healWorld) send(t *testing.T, op uint16, data []byte) {
	t.Helper()
	if err := proto.Write(w.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

func (w *healWorld) next(t *testing.T, op uint16) *proto.Packet {
	t.Helper()
	for i := 0; i < 16; i++ {
		w.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(w.r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for 0x%04X: %v", op, err)
		}
		if p.Opcode == op {
			return p
		}
	}
	t.Fatalf("no 0x%04X", op)
	return nil
}

// healRefusedCostsNothing casts Heal with req and wants the refusal text,
// full MP and no cooldown recorded.
func healRefusedCostsNothing(t *testing.T, w *healWorld, req *UseSkillRequest, want string) {
	t.Helper()
	req.CharacterName, req.SkillID = "Aria", skHealA1
	full := w.mp.Current(w.aria, 1000)
	w.send(t, OpUseSkill, req.Encode())
	ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	if ar.Error != want {
		t.Errorf("Heal refused with %q, want %q (READ: the retail client and server refuse it)", ar.Error, want)
	}
	if got := w.mp.Current(w.aria, 1000); got != full {
		t.Errorf("MP %d after the refusal, want %d: a refused cast spends nothing", got, full)
	}
	if _, used, _ := w.skills.LastUsed(context.Background(), w.aria, skHealA1); used {
		t.Errorf("the refused Heal was recorded as used (its cooldown runs)")
	}
}

// READ, the retail client FUN_0081ba10 0x81be5e..0x81be99: Target_Required,
// TargetType_Animal, no Land, no Building, and the selected id 0 -> 0x3011
// UIIT_SKILL_USE_FAIL_NONESELECTETARGET, "The target is not selected."
// Before round 622 srrevamp healed nobody and charged the cast.
func TestHealWithNothingSelectedIsRefused(t *testing.T) {
	w := startHealWorld(t)
	healRefusedCostsNothing(t, w, &UseSkillRequest{TargetType: TargetNone, HasTargetType: true}, "The target is not selected.")
}

// READ, the server FUN_0058d7a0 step 4 (Ally or Party and a target that is
// not a PC fails), reached from PrepareAction case 4 in the skill tick's
// phase 0 -> 0x3006 UIIT_SKILL_USE_FAIL_WRONGTARGET, "Invalid target". The
// live run of rounds 616-620 cast Heal at a monster.
func TestHealAtAMonsterIsRefused(t *testing.T) {
	w := startHealWorld(t)
	healRefusedCostsNothing(t, w, &UseSkillRequest{TargetMonsterID: w.monster, TargetType: TargetEntity, HasTargetType: true}, "Invalid target")
	// A request from a client before round 617 (no targetType) is an entity
	// target too, and refused the same.
	healRefusedCostsNothing(t, w, &UseSkillRequest{TargetMonsterID: w.monster}, "Invalid target")
}
