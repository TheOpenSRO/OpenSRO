package session

// Round 636's review follow-up. Like buffstack636_test.go, this file uses
// only what the round-636 commit (ff30b8b) already had, so it compiles there
// and is its negative. Rows in the export's CSV layout, typed with only the
// values the cast path reads -- MEASURED on the RE box's export; every other
// column is zero (SYNTHETIC):
//
//	SKILL_EU_ROG_STEALTHA_HIDING_A_01 id 9374, group 588, lv 1, MP 53,  kind 3, dura 60000, hide, Action_Overlap 48, skc value[1] 10, Activity 2
//	SKILL_EU_ROG_STEALTHA_HIDING_A_05 id 9378, group 588, lv 5, MP 212, the same
//	SKILL_CH_FIRE_DETECT_A_01         id 21209, group 818, lv 1, MP 274, dura 120000, nbuf, bbuf, dttp 6,3, efr 1 (column 82), Action_Overlap 47, Activity 2
//	SKILL_CH_LIGHTNING_GYEONGGONG_A_01 id 113, as in buffstack636_test.go, with a 60 s re-use delay (SYNTHETIC)
//
// and 21210, SYNTHETIC: Fire Detect without its 'efr' kind 1.

import (
	"bufio"
	"context"
	"net"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const review636CSV = `9374,588,SKILL_EU_ROG_STEALTHA_HIDING_A_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,53,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,60000,0,0,0,0,0,0,"hide:1,3,50",0,0,0,48,0,0,0,0,0,0,0,1,10,SKILL_EU_ROG_STEALTHA_HIDING_A,2,0,0,0,0,0,0,0
9378,588,SKILL_EU_ROG_STEALTHA_HIDING_A_05,0,5,0,0,0,0,0,0,0,0,0,0,0,0,0,212,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,60000,0,0,0,0,0,0,"hide:1,7,50",0,0,0,48,0,0,0,0,0,0,0,1,10,SKILL_EU_ROG_STEALTHA_HIDING_A,2,0,0,0,0,0,0,0
21209,818,SKILL_CH_FIRE_DETECT_A_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,274,0,0,,0,0,0,0,0,0,0,0,0,0,,0,0,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,120000,0,1,1,0,0,0,,0,0,0,47,0,1,6,3,0,1,0,0,0,SKILL_CH_FIRE_DETECT_A,2,0,0,0,0,0,0,1
21210,819,SKILL_CH_FIRE_DETECT_SYNTHETIC,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,274,0,0,,0,0,0,0,0,0,0,0,0,0,,0,0,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,120000,0,1,1,0,0,0,,0,0,0,47,0,1,6,3,0,1,0,0,0,SKILL_CH_FIRE_DETECT_SYNTHETIC,2,0,0,0,0,0,0,0
113,260,SKILL_CH_LIGHTNING_GYEONGGONG_A_01,0,1,0,0,0,0,0,60000,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,355462,0,0,0,0,0,0,hste:20,0,0,0,6,0,0,0,0,0,0,0,0,0,SKILL_CH_LIGHTNING_GYEONGGONG_A,1,0
`

// The marker the server answers a silently ended cast with (session
// silentRefusal; typed here so the file compiles before it existed).
const review636Silent = "the skill action ended"

type reviewWorld struct {
	*stackWorld
	mp    *mana.Tracker
	chars character.Store
}

func startReview636World(t *testing.T) *reviewWorld {
	t.Helper()
	ctx := context.Background()
	rows, err := refdata.LoadSkillsCSV(strings.NewReader(review636CSV))
	if err != nil || len(rows) != 5 {
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
		// A learn cost (SYNTHETIC; the rows above carry none): a mastery-less
		// row with none is a monster's shape, which a player may not cast
		// (playerHoldRefusal, the round 691 review).
		rows[i].ReqLearnSP = 1
		ref[rows[i].ID] = &rows[i]
		if err := skills.Learn(ctx, c.ID, rows[i].ID); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	mp := mana.NewTracker()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, combat.NewHub(), quest.NewMemStore(), inv, ref, nil, mp, nil),
		BuffHandler(chars, hub),
		GMCommandHandler(chars, gm.ParseAccounts("alice"), nil, hub, nil),
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
	w := &reviewWorld{stackWorld: &stackWorld{aria: c.ID, conn: conn, r: bufio.NewReader(conn)}, mp: mp, chars: chars}
	t.Cleanup(func() { buffBooks.EndAll(c.ID); motions.clear(c.ID) })
	w.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.expect(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.expect(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	// Level 1's pool is too small for the rows' MP: raise the character so
	// every cast can pay (the test is about the recast rule, not the pool).
	if err := chars.SetLeveling(ctx, c.ID, 100, 0, 0, 120, 120); err != nil {
		t.Fatal(err)
	}
	return w
}

func (w *reviewWorld) mana(t *testing.T) int {
	t.Helper()
	c, err := w.chars.GetByID(context.Background(), w.aria)
	if err != nil {
		t.Fatal(err)
	}
	return w.mp.Current(w.aria, c.MaxMP())
}

func (w *reviewWorld) skills() []int64 {
	var ids []int64
	for _, r := range buffBooks.Active(w.aria) {
		ids = append(ids, r.SkillID)
	}
	return ids
}

// 1. A lower level of an active stealth is refused 0x300c at the request's
// gate, and the stealth stays: the category end runs only after the gate
// (FUN_0059b480 at 0x59b745, reached from the skill tick's case 2).
func TestRound636ReviewLowerStealthIsRefused(t *testing.T) {
	w := startReview636World(t)
	if e := w.cast(t, 9378); e != "" {
		t.Fatalf("stealth lv5: %q", e)
	}
	if e := w.cast(t, 9374); e != overlapRefusal {
		t.Errorf("stealth lv1 over lv5: %q, want the overlap refusal", e)
	}
	if ids := w.skills(); len(ids) != 1 || ids[0] != 9378 {
		t.Errorf("records %v, want stealth lv5 alone", ids)
	}
}

// 2. A refused cast (Grass Walk on its re-use delay) ends nothing: the
// stealth survives. A cast that passes does end it.
func TestRound636ReviewRefusedCastKeepsStealth(t *testing.T) {
	w := startReview636World(t)
	if e := w.cast(t, 113); e != "" {
		t.Fatalf("grass walk: %q", e)
	}
	if e := w.cast(t, 9374); e != "" {
		t.Fatalf("stealth: %q", e)
	}
	if e := w.cast(t, 113); e == "" {
		t.Fatal("grass walk inside its re-use delay was accepted")
	}
	found := false
	for _, id := range w.skills() {
		found = found || id == 9374
	}
	if !found {
		t.Errorf("a refused cast ended the stealth: records %v", w.skills())
	}
}

// 3. Fire Detect cast again while it runs: the gate's 'dttp' owner shortcut
// passes it; its 'efr' kind 1 (Activity 2) takes the collector path, which
// charges; the engage finds byte 47 set and starts nothing. So the cast is
// answered as a success, its MP is taken, and one record stays (READ,
// 0x5830b0). The same row without 'efr' kind 1 meets sub-state 0's bit test
// instead: ended silently, nothing charged.
func TestRound636ReviewFireDetectRecast(t *testing.T) {
	w := startReview636World(t)
	if e := w.cast(t, 21209); e != "" {
		t.Fatalf("the first Fire Detect: %q", e)
	}
	before := w.mana(t)
	if e := w.cast(t, 21209); e != "" {
		t.Errorf("the second Fire Detect: %q, want the success retail sends", e)
	}
	if got := w.mana(t); got != before-274 {
		t.Errorf("MP %d after the second, want %d (charged)", got, before-274)
	}
	if n := len(w.skills()); n != 1 {
		t.Errorf("%d records, want 1", n)
	}
	buffBooks.EndAll(w.aria)
	if e := w.cast(t, 21210); e != "" {
		t.Fatalf("the first synthetic detect: %q", e)
	}
	before = w.mana(t)
	if e := w.cast(t, 21210); e != review636Silent {
		t.Errorf("the second synthetic detect: %q, want the silent end", e)
	}
	if got := w.mana(t); got != before {
		t.Errorf("MP %d after the silent end, want %d (nothing charged)", got, before)
	}
}
