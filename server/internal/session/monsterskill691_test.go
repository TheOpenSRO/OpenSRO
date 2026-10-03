package session

import (
	"bufio"
	"context"
	"errors"
	"net"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The round 691 review's HIGH: any character could learn a monster's skill for
// free (no mastery, ReqLearn_Race 3, ReqLearn_SP 0 passed every gate) and then
// cast it, since the cast path checked only that the skill was known.
// FUN_0059e450 returns 0x3409 for a ReqLearn_SP of 0 (READ); the cast path now
// applies playerHoldRefusal and drops what fails.

// TestLearnRefusesRowsWithNoLearnCost: the 31825-shaped monster row and a class
// chain link are both refused 0x3409 however many points the character holds,
// and nothing is spent or learned.
func TestLearnRefusesRowsWithNoLearnCost(t *testing.T) {
	h := newRaceHarness(t, 20)
	h.seed(h.china, smashA1Mastery, 20)
	for _, id := range []int64{monsterRowID, chainLinkID} {
		before, _ := h.skills.SkillPoints(h.ctx, h.china)
		if lr := h.learn("Chen", id); lr.OK || lr.Reason != "this skill cannot be learned" {
			t.Fatalf("learn %d: got %+v, want refused 'this skill cannot be learned' (0x3409)", id, lr)
		}
		if known, _ := h.skills.Knows(h.ctx, h.china, id); known {
			t.Fatalf("skill %d recorded as known after a refused learn", id)
		}
		if after, _ := h.skills.SkillPoints(h.ctx, h.china); after != before {
			t.Fatalf("learn %d spent %d points on a refusal", id, before-after)
		}
	}
}

// TestPlayerHoldRefusal pins the rule the cast path and the skill state apply.
func TestPlayerHoldRefusal(t *testing.T) {
	china, europe := equipment.CountryChina, equipment.CountryEurope
	cases := []struct {
		name    string
		ref     *refdata.Skill
		country int
		want    string
	}{
		{"a monster row", monsterRow(), china, "not a player skill"},
		{"a monster row, Europe", monsterRow(), europe, "not a player skill"},
		{"the punch (base attack 1)", &refdata.Skill{ID: 1, ReqLearnRace: 3}, china, ""},
		{"the CH sword swing (2)", &refdata.Skill{ID: 2, ReqLearnRace: 3, Mastery1: 257}, china, ""},
		{"the CH spear swing (40)", &refdata.Skill{ID: 40, ReqLearnRace: 3, Mastery1: 258}, china, ""},
		{"the CH bow swing (70)", &refdata.Skill{ID: 70, ReqLearnRace: 3, Mastery1: 259}, china, ""},
		{"the EU sword swing (8419)", &refdata.Skill{ID: 8419, ReqLearnRace: 1, Mastery1: 513}, europe, ""},
		{"the EU harp swing (11162)", &refdata.Skill{ID: 11162, ReqLearnRace: 1, Mastery1: 517}, europe, ""},
		{"the EU cleric rod swing (11526)", &refdata.Skill{ID: 11526, ReqLearnRace: 1, Mastery1: 518}, europe, ""},
		{"Power Strike for China", &refdata.Skill{ID: 3, ReqLearnRace: 0, Mastery1: 257, ReqLearnSP: 2}, china, ""},
		{"Power Strike for Europe", &refdata.Skill{ID: 3, ReqLearnRace: 0, Mastery1: 257, ReqLearnSP: 2}, europe, "not your race's skill"},
		{"Cross for China", &refdata.Skill{ID: 11557, ReqLearnRace: 1, Mastery1: 518, ReqLearnSP: 2}, china, "not your race's skill"},
		{"a China row on a Europe mastery", &refdata.Skill{ID: 9, ReqLearnRace: 3, Mastery1: 513, ReqLearnSP: 2}, china, "not your race's mastery"},
	}
	for _, c := range cases {
		if got := playerHoldRefusal(c.ref, c.country); got != c.want {
			t.Errorf("%s: playerHoldRefusal = %q, want %q", c.name, got, c.want)
		}
	}
}

// monsterSkillRef serves the monster row, the CH sword swing (2), Power Strike
// (3) and Cross (11557), all castable at range with no weapon requirement.
type monsterSkillRef struct{}

func (monsterSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	switch id {
	case monsterRowID:
		return monsterRow(), nil
	case 2:
		return &refdata.Skill{ID: 2, GroupID: 173, BasicCode: "SKILL_CH_SWORD_BASE_01", BasicLevel: 1, ReqLearnRace: 3,
			Mastery1: 257, AttackPercent: 60, AttackType: 5, Range: 1000}, nil
	case smashA1ID:
		return &refdata.Skill{ID: smashA1ID, GroupID: 174, BasicCode: "SKILL_CH_SWORD_SMASH_A_01", BasicLevel: 1,
			Mastery1: smashA1Mastery, MasteryLevel1: 5, ReqLearnSP: 2, AttackPercent: 143, AttackType: 5, Range: 1000}, nil
	case crossA1ID:
		return &refdata.Skill{ID: crossA1ID, GroupID: 764, BasicCode: "SKILL_EU_CLERIC_BATTLEA_CROSS_A_01", BasicLevel: 1,
			Mastery1: crossA1Mastery, MasteryLevel1: 4, ReqLearnSP: 2, ReqLearnRace: 1, AttackPercent: 199, AttackType: 9, Range: 1000}, nil
	}
	return nil, errors.New("no such skill")
}

// TestCastOfAnUnholdableSkillIsRefusedAndDropped: a China character that
// learned the monster row and Cross before the gates refused them (stored
// directly here) is refused both casts and loses both skills, while its base
// attack and its own Power Strike still cast; and the skill state, which the
// client asks for on entering the world, drops what is left of the same.
func TestCastOfAnUnholdableSkillIsRefusedAndDropped(t *testing.T) {
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
	for _, id := range []int64{monsterRowID, crossA1ID, 2, smashA1ID} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	m := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000000, 10, 5, 500)
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, monsterSkillRef{}, nil, mana.NewTracker(), nil),
		SkillStateHandlerWithRefs(chars, skills, monsterSkillRef{}),
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
	w := &healWorld{aria: c.ID, conn: conn, r: bufio.NewReader(conn)}
	w.send(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.next(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.next(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	cast := func(id int64) *AttackResult {
		t.Helper()
		w.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: id, TargetMonsterID: m.ID}).Encode())
		ar, err := DecodeAttackResult(w.next(t, OpAttackResult).Data)
		if err != nil {
			t.Fatalf("DecodeAttackResult: %v", err)
		}
		return ar
	}

	for _, id := range []int64{monsterRowID, crossA1ID} {
		if ar := cast(id); ar.Error != "you cannot use this skill" || ar.MonsterDamage != 0 {
			t.Fatalf("cast %d: got %+v, want refused 'you cannot use this skill' with no damage", id, ar)
		}
		if known, _ := skills.Knows(ctx, c.ID, id); known {
			t.Fatalf("skill %d still known after its cast was refused; want it dropped", id)
		}
		// Once dropped, a second try is simply not known.
		if ar := cast(id); ar.Error != "skill not known" {
			t.Fatalf("cast %d again: got %q, want 'skill not known'", id, ar.Error)
		}
	}
	// The base attack and the race's own skill still cast. (Each has its own
	// timer; no group.)
	if ar := cast(2); ar.Error != "" || ar.MonsterDamage <= 0 {
		t.Fatalf("cast the CH sword swing (2): got %+v, want a blow", ar)
	}
	if ar := cast(smashA1ID); ar.Error != "" || ar.MonsterDamage <= 0 {
		t.Fatalf("cast Power Strike: got %+v, want a blow", ar)
	}

	// The skill state drops a monster row learned since (the login purge).
	if err := skills.Learn(ctx, c.ID, monsterRowID); err != nil {
		t.Fatal(err)
	}
	w.send(t, OpSkillState, (&SkillStateRequest{CharacterName: "Aria"}).Encode())
	st, err := DecodeSkillStateResult(w.next(t, OpSkillStateResult).Data)
	if err != nil || st.Error != "" {
		t.Fatalf("skill state: %v %+v", err, st)
	}
	for _, id := range st.KnownSkills {
		if id == monsterRowID {
			t.Fatalf("skill state lists the monster row %d: %v", id, st.KnownSkills)
		}
	}
	if known, _ := skills.Knows(ctx, c.ID, monsterRowID); known {
		t.Fatal("the skill state left the monster row in the store")
	}
	if len(st.KnownSkills) != 2 {
		t.Fatalf("skill state knows %v, want the sword swing and Power Strike", st.KnownSkills)
	}
}
