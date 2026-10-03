package session

// Round 640's negative: this file runs against feat/buffstack ff30b8b (round
// 636, before the walls) and after it. It uses only what both sides have --
// the cast handler, the buff book and monsterStrike -- so it compiles on both,
// and only the rules differ. Its rows are the export's own CSV lines for the
// four skills it uses (MEASURED on the RE box's export, 2026-09-29, typed
// here as test data; no archive in the repo): Crystal Wall lv1 (99), Fire
// Wall - Tower lv1 (136), Mangyang's physical attack (160, 'att' 5) and the
// Tomb Stone Ghost slave's magical attack (171, 'att' 10). An export made
// before round 640 stops at column 82 and the loader ignores what it does not
// know.

import (
	"bufio"
	"context"
	"net"
	"strings"
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

const walls640CSV = `99,246,SKILL_CH_COLD_BINGBYEOK_A_01,0,1,0,0,1000,1000,1000,10000,0,0,0,0,0,0,0,165,35,0,SN_SKILL_CH_COLD_BINGBYEOK_A,273,17,0,0,0,0,0,255,255,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,1,3,0,0,0,0,0,0,0,0,0,0,0,0,"onff:5000,41",0,0,0,11,0,0,0,0,0,0,0,0,0,SKILL_CH_COLD_BINGBYEOK_A,2,0,0,0,0,0,0,0,7,824,0,11
136,283,SKILL_CH_FIRE_HWABYEOK_A_01,0,1,0,0,1000,1000,1000,5000,0,0,0,0,0,0,0,232,80,0,SN_SKILL_CH_FIRE_HWABYEOK_A,275,23,0,0,0,0,0,255,255,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,1,3,0,0,0,0,0,0,0,0,0,0,0,0,"onff:5000,58",0,0,0,11,0,0,0,0,0,0,0,0,0,SKILL_CH_FIRE_HWABYEOK_A,2,0,0,0,0,0,0,0,11,1159,0,17
160,0,MSKILL_CH_MANGNYANG_ATTACK01,0,1,0,0,0,0,2400,3000,3000,0,0,0,1,10,0,0,0,3,xxx,0,0,200,17,19,1,5,255,255,0,,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,1,0,0,0,xxx,2,0,0,0,0,0
171,0,MSKILL_CH_TOMBSTONE_CLON_ATTACK01,0,8,0,0,0,1265,735,2500,2500,0,0,0,1,100,0,0,0,3,xxx,0,0,167,74,83,1,10,255,255,0,,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,1,0,0,0,xxx,2,0,0,0,0,0
`

// wallWorld is a logged-in Aria who knows both walls, with the stores a
// monster's blow on her needs.
type wallWorld struct {
	stackWorld
	ref    csvSkillRef
	chars  *character.MemStore
	eq     equipment.Store
	items  stubCombatItems
	mp     *mana.Tracker
	hub    *world.Hub
	skills *skill.MemStore
}

func startWallWorld(t *testing.T) *wallWorld {
	t.Helper()
	ctx := context.Background()
	rows, err := refdata.LoadSkillsCSV(strings.NewReader(walls640CSV))
	if err != nil || len(rows) != 4 {
		t.Fatalf("the rows: %d, %v", len(rows), err)
	}
	ref := csvSkillRef{}
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
	for i := range rows {
		// The MP costs are zeroed (SYNTHETIC): a level-1 character cannot
		// pay 165 or 232. The re-use delays stay -- a recast inside one is
		// what proves the toggle-off never reaches the gate.
		rows[i].ConsumeMP, rows[i].ConsumeHP = 0, 0
		ref[rows[i].ID] = &rows[i]
		if rows[i].ID == 99 || rows[i].ID == 136 {
			if err := skills.Learn(ctx, c.ID, rows[i].ID); err != nil {
				t.Fatal(err)
			}
		}
	}
	mp := mana.NewTracker()
	hub := world.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, combat.NewHub(), quest.NewMemStore(), inv, ref, nil, mp, nil),
		BuffHandler(chars, hub),
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
	w := &wallWorld{stackWorld: stackWorld{aria: c.ID, conn: conn, r: bufio.NewReader(conn)},
		ref: ref, chars: chars, eq: eq, items: items, mp: mp, hub: hub, skills: skills}
	t.Cleanup(func() {
		buffBooks.EndAll(c.ID)
		motions.clear(c.ID)
	})
	w.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.expect(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.expect(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	return w
}

// strike is one blow of skill id (160 or 171) from a monster whose primary
// range is that skill's, at Aria.
func (w *wallWorld) strike(t *testing.T, id int64) monsterStrikeOutcome {
	t.Helper()
	sk := w.ref[id]
	m := combat.Monster{ID: 9001, Level: 8, Critical: 0, AttackMin: sk.DamageMin, AttackMax: sk.DamageMax,
		Skills: []combat.MonsterSkill{{ID: id, AttMin: sk.DamageMin, AttMax: sk.DamageMax, Chance: 100}}}
	out, err := monsterStrike(context.Background(), strikeDeps{chars: w.chars, eq: w.eq, items: w.items, mp: w.mp, hub: w.hub},
		m, combat.MonsterSkill{ID: id, AttMin: sk.DamageMin, AttMax: sk.DamageMax, Chance: 100}, w.aria, 1)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func (w *wallWorld) hp(t *testing.T) int {
	t.Helper()
	c, err := w.chars.GetByID(context.Background(), w.aria)
	if err != nil {
		t.Fatal(err)
	}
	return c.HP
}

// Crystal Wall covers the physical half ('pw' 7): Mangyang's physical blow
// ('att' 5) goes into the wall, and Aria's HP does not move
// (Combat_ResolveDamage's absorb, 0x58f03e..0x58f0a6).
func TestRound640CrystalWallTakesAPhysicalBlow(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 99); e != "" {
		t.Fatalf("Crystal Wall: %q", e)
	}
	before := w.hp(t)
	out := w.strike(t, 160)
	if out.damage != 0 || w.hp(t) != before {
		t.Errorf("Mangyang's blow landed %d on the walled caster (HP %d -> %d), want 0: the wall takes it", out.damage, before, w.hp(t))
	}
}

// Recasting a running wall switches it off (Tick_UseSkill's phase 0,
// 0x4ae622..0x4ae64d) -- inside Fire Wall's own 5 s re-use delay, which a
// cast through the gate would be refused by.
func TestRound640RecastSwitchesTheWallOff(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	start, err := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	if e := w.cast(t, 136); e != "" {
		t.Errorf("the recast answered %q, want it accepted as the toggle-off", e)
	}
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Errorf("%d records after the recast, want the wall switched off", n)
	}
	end, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if err != nil || len(end.Tokens) != 1 || end.Tokens[0] != start.Token {
		t.Errorf("OpBuffEnd %+v %v, want the wall's token %d", end, err, start.Token)
	}
}

// Fire Wall covers only the magical half ('pw' 11): a physical blow reaches
// the caster as it would without it. (Both sides agree; not a negative.)
func TestRound640FireWallLetsAPhysicalBlowThrough(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	before := w.hp(t)
	out := w.strike(t, 160)
	if out.damage <= 0 || w.hp(t) != before-out.damage {
		t.Errorf("a physical blow on a Fire-walled caster: damage %d, HP %d -> %d; want it landed", out.damage, before, w.hp(t))
	}
}
