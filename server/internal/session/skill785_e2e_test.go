package session

// Round 785, end to end: a server over the real handlers, a logged-in
// client casting one representative row of each mechanic, and the
// broadcasts read back off the wire.

import (
	"bufio"
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/skillparam"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The synthetic rows (own ids; the Params words are each mechanic's real
// shape, the values chosen for the test).
const (
	r785AoE      = 950001 // att, mc 2, efr kind 2 (area around the target), radius 30, cap 3, 35 %
	r785Knock    = 950002 // att, kb [100 25]: a certain knockback
	r785Ghost    = 950003 // tele [500 100]
	r785Head     = 950004 // a chain head -> r785Link
	r785Link     = 950005
	r785Dot      = 950006 // a debuff: kind 3, TR 1, lnks + att + puls 50 + dura 1000
	r785Teleport = 950007 // tel2 [500 125]
	r785Passive  = 950008 // Activity 0: defp [50 0 0], setv E1SA 10
)

func r785Rows() map[int64]*refdata.Skill {
	att := run("att", 4|1, 100, 10, 10, 100)
	base := func(id int64, code string, words []int32) *refdata.Skill {
		return &refdata.Skill{ID: id, GroupID: id, BasicCode: code, BasicLevel: 1, ReqLearnSP: 1, ReqLearnRace: 3,
			Mastery1: 257, AttackPercent: 100, DamageMin: 10, DamageMax: 10, AttackType: 5, HitCount: 1,
			ReqCastWeapon1: 255, ReqCastWeapon2: 255, Range: 1000, TargetRequired: true, ParamWords: words}
	}
	rows := map[int64]*refdata.Skill{
		r785AoE:   base(r785AoE, "SKILL_TEST_AOE_01", words(0, att, run("mc", 2, 2), run("efr", 1, 2, 30, 3, 35, 24))),
		r785Knock: base(r785Knock, "SKILL_TEST_KB_01", words(0, att, run("kb", 100, 25))),
		r785Head:  base(r785Head, "SKILL_TEST_CHAIN_01", words(0, att)),
		r785Link:  base(r785Link, "SKILL_TEST_CHAIN_02", words(0, att)),
	}
	rows[r785AoE].HitCount = 2
	rows[r785Head].BasicChainCode = r785Link
	rows[r785Head].ActionDurationMs = 600 // 100 ms after the 500 ms budget
	ghost := base(r785Ghost, "SKILL_TEST_GHOST_01", words(0, run("tele", 500, 100)))
	ghost.TargetLand, ghost.Tele0, ghost.Tele1, ghost.ZeroDamage, ghost.NoCombatParam = true, 500, 100, true, true
	rows[r785Ghost] = ghost
	tp := base(r785Teleport, "SKILL_TEST_TELEPORT_01", words(0, run("tel2", 500, 125)))
	tp.TargetLand, tp.ZeroDamage, tp.NoCombatParam = true, true, true
	rows[r785Teleport] = tp
	dot := base(r785Dot, "SKILL_TEST_DOT_01", words(3, run("lnks", 9, 0, 2, 0), run("dura", 1000), run("puls", 50), att))
	dot.ActionKind, dot.DuraMs, dot.Lnks = 3, 1000, true
	rows[r785Dot] = dot
	pas := base(r785Passive, "SKILL_TEST_PASSIVE_01", words(4, run("defp", 50, 0, 0), run("setv", int(skillparamWord("E1SA")), 10, 0)))
	pas.ActionKind, pas.Activity, pas.TargetRequired = 4, 0, false
	rows[r785Passive] = pas
	return rows
}

type r785Ref struct{ rows map[int64]*refdata.Skill }

func (r r785Ref) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if s, ok := r.rows[id]; ok {
		return s, nil
	}
	return nil, errors.New("no such skill")
}

type r785World struct {
	healWorld
	hub      *world.Hub
	monsters *combat.Hub
	me       world.Entity
}

func startR785World(t *testing.T) *r785World {
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
	rows := r785Rows()
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
	w := &r785World{healWorld: healWorld{aria: c.ID, mp: mp, skills: skills, conn: conn, r: bufio.NewReader(conn)}, hub: hub, monsters: monsters}
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

func (w *r785World) spawn(dx, dz float64, hp int) int64 {
	m := w.monsters.Spawn(w.me.Zone, "Dummy", w.me.Pos.X+dx, w.me.Pos.Y, w.me.Pos.Z+dz, hp, 0, 0, 0)
	return m.ID
}

func (w *r785World) cast(t *testing.T, req *UseSkillRequest) *AttackResult {
	t.Helper()
	req.CharacterName = "Aria"
	w.send(t, OpUseSkill, req.Encode())
	ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	if ar.Error != "" {
		t.Fatalf("cast %d refused: %q", req.SkillID, ar.Error)
	}
	return ar
}

// TestR785AreaMultiHit: an 'efr' kind-2 row with 'mc' 2 strikes the primary
// and its neighbours, two hits each, with the falloff, and the answer
// carries the whole block.
func TestR785AreaMultiHit(t *testing.T) {
	w := startR785World(t)
	p := w.spawn(10, 0, 100000)
	n1 := w.spawn(15, 0, 100000)
	n2 := w.spawn(10, 8, 100000)
	far := w.spawn(200, 0, 100000)
	ar := w.cast(t, &UseSkillRequest{SkillID: r785AoE, TargetMonsterID: p})
	a := ar.Action
	if a == nil || a.HitCount != 2 || len(a.Targets) != 3 {
		t.Fatalf("action %+v", a)
	}
	ids := map[uint32]bool{}
	for _, tg := range a.Targets {
		ids[tg.UID] = true
		if len(tg.Hits) != 2 || tg.Kind != ActionTargetMonster {
			t.Fatalf("target %+v", tg)
		}
	}
	if !ids[uint32(p)] || !ids[uint32(n1)] || !ids[uint32(n2)] || ids[uint32(far)] {
		t.Fatalf("targets %v (p %d n1 %d n2 %d far %d)", ids, p, n1, n2, far)
	}
	if a.Targets[0].UID != uint32(p) || ar.MonsterID != p {
		t.Fatal("the primary is not first")
	}
	for _, id := range []int64{p, n1, n2} {
		if m, _ := w.monsters.Get(id); m.HP >= 100000 {
			t.Fatalf("monster %d took nothing", id)
		}
	}
	if m, _ := w.monsters.Get(far); m.HP != 100000 {
		t.Fatal("the far monster was struck")
	}
}

// TestR785Knockback: 'kb' [100 25] knocks the target back 25 units (hit
// kind 5 with its new position) and holds it.
func TestR785Knockback(t *testing.T) {
	w := startR785World(t)
	p := w.spawn(10, 0, 100000)
	before, _ := w.monsters.Get(p)
	ar := w.cast(t, &UseSkillRequest{SkillID: r785Knock, TargetMonsterID: p})
	h := ar.Action.Targets[0].Hits[0]
	if h.Kind&0x7f != HitKindKnockback {
		t.Fatalf("hit %+v", h)
	}
	after, _ := w.monsters.Get(p)
	if d := after.X - before.X; d < 24 || d > 26 {
		t.Fatalf("moved %v, want 25 away from the caster", d)
	}
	if monsterMayAct(p) {
		t.Fatal("a knocked-back monster acts")
	}
}

// TestR785GhostWalk: a 'tele' cast at a point beyond 100 units lands at
// the clamp, truncated, and the answer carries the move (flags 8).
func TestR785GhostWalk(t *testing.T) {
	w := startR785World(t)
	to := w.me.Pos
	to.X += 300.7
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: r785Ghost, TargetType: TargetGround, HasTargetType: true,
		X: float32(to.X), Y: float32(to.Y), Z: float32(to.Z)}).Encode())
	mv, err := DecodeSkillMove(w.next(t, OpSkillMove).Data)
	if err != nil {
		t.Fatal(err)
	}
	ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
	if err != nil || ar.Error != "" || ar.Action == nil || ar.Action.Flags&ActionFlagMove == 0 {
		t.Fatalf("result %+v %v", ar, err)
	}
	if d := float64(mv.X) - w.me.Pos.X; d < 99 || d > 101 {
		t.Fatalf("moved %v, want the 100-unit clamp", d)
	}
}

// TestR785Teleport: 'tel2' moves the caster too, with the snap flag (2).
func TestR785Teleport(t *testing.T) {
	w := startR785World(t)
	to := w.me.Pos
	to.Z += 50
	w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: r785Teleport, TargetType: TargetGround, HasTargetType: true,
		X: float32(to.X), Y: float32(to.Y), Z: float32(to.Z)}).Encode())
	ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
	if err != nil || ar.Error != "" || ar.Action == nil || ar.Action.Flags&ActionFlagSnap == 0 {
		t.Fatalf("result %+v %v", ar, err)
	}
	me, _ := w.hub.EntityByCharacterID(w.aria)
	if d := me.Pos.Z - w.me.Pos.Z; d < 49 || d > 51 {
		t.Fatalf("moved %v, want 50 (a nearer point is the landing)", d)
	}
}

// TestR785ChainLink: a chain head's link reaches the caster as an
// OpSkillCast start and act naming the link, with the block.
func TestR785ChainLink(t *testing.T) {
	w := startR785World(t)
	p := w.spawn(10, 0, 100000)
	w.cast(t, &UseSkillRequest{SkillID: r785Head, TargetMonsterID: p})
	var act *SkillCast
	for act == nil {
		sc, err := DecodeSkillCast(w.next(t, OpSkillCast).Data)
		if err != nil {
			t.Fatal(err)
		}
		if sc.SkillID != r785Link || sc.CasterID != w.aria {
			t.Fatalf("cast %+v", sc)
		}
		if sc.Phase == CastPhaseAct {
			act = sc
		}
	}
	if act.Action == nil || len(act.Action.Targets) != 1 || act.Action.Targets[0].UID != uint32(p) {
		t.Fatalf("act %+v", act)
	}
}

// TestR785Debuff: a hostile kind-3 row starts its record on the monster
// (OpBuffStart, ownerKind 1), and its linked blow strikes every 'puls'.
func TestR785Debuff(t *testing.T) {
	w := startR785World(t)
	p := w.spawn(10, 0, 100000)
	w.cast(t, &UseSkillRequest{SkillID: r785Dot, TargetMonsterID: p})
	if m, _ := w.monsters.Get(p); m.HP != 100000 {
		t.Fatal("the debuff struck at the cast")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if m, _ := w.monsters.Get(p); m.HP < 100000 {
			if len(monsterBooks.Active(p)) != 1 {
				t.Fatal("no record on the monster")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("no pulse struck")
}

// Ensure the proto import is used by a helper.
var _ = proto.Packet{}

func skillparamWord(c string) int32 { return skillparam.WordOf(skillparam.Code(c)) }

// TestR785Passive: a known passive's stat writes count in the character's
// stats and its 'setv' variable answers a 'getv' key (passives.go).
func TestR785Passive(t *testing.T) {
	w := startR785World(t)
	invalidatePassives(w.aria)
	if tot, ok := buffTotal(w.aria, buff.ParamPhysDefFlat); !ok || tot.Flat != 50 {
		t.Fatalf("defp: %+v %v", tot, ok)
	}
	if v := passiveVar(w.aria, "E1SA"); v != 10 {
		t.Fatalf("E1SA = %d", v)
	}
	row := &refdata.Skill{ParamWords: []int32{0, skillparamWord("getv"), skillparamWord("E1SA")}}
	if got := applyGetvDamage(w.aria, row, 100); got != 110 {
		t.Fatalf("getv E1SA: %d", got)
	}
}
