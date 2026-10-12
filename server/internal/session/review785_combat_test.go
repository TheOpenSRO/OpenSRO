package session

// Round 785's server review: the combat and skill findings 3-7, 9, 10, 12,
// 13 and 15, each pinned by a test that failed before its fix (finding 11
// is character/hppct785_test.go; the quest findings are
// review785_quest_test.go).

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/skillparam"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// --- Finding 3: the resurrection offer and the party invitation ---------

func reviewPutOffer(t *testing.T, id int64, o resurrectOffer) {
	t.Helper()
	resurrectOffers.Lock()
	resurrectOffers.m[id] = o
	resurrectOffers.Unlock()
	t.Cleanup(func() { resurrectOffers.Lock(); delete(resurrectOffers.m, id); resurrectOffers.Unlock() })
}

// reviewInParty waits up to a second for name to be in a party.
func reviewInParty(w *partyWorld, name string) bool {
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, ok := w.parties.Get(w.ids[name]); ok {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

func reviewHasOffer(id int64) bool {
	resurrectOffers.Lock()
	defer resurrectOffers.Unlock()
	_, ok := resurrectOffers.m[id]
	return ok
}

// An expired offer Bram never answered swallowed his answer to a later
// party invitation (the reviewer's proof).
func TestReview785ExpiredOfferDoesNotTakeThePartyAnswer(t *testing.T) {
	w := newPartyWorld(t)
	reviewPutOffer(t, w.ids["Bram"], resurrectOffer{casterID: w.ids["Cato"], expires: time.Now().Add(-time.Minute)})
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), 0))
	w.c["Bram"].next(party.OpInvitation)
	w.c["Bram"].send(party.OpInvitation, party.EncodeAnswerYes())
	if !reviewInParty(w, "Bram") {
		t.Fatalf("Bram's yes to the invitation went to a stale offer: no party (state %d)", w.parties.State(w.ids["Bram"]))
	}
}

// A live offer and an invitation both pending: the answer is the
// invitation's (skill_support.md: the invitation is asked first; the client
// ignores kinds 4/8, so the box the player answered is the invitation's).
func TestReview785InvitationAnsweredBeforeALiveOffer(t *testing.T) {
	w := newPartyWorld(t)
	reviewPutOffer(t, w.ids["Bram"], resurrectOffer{casterID: w.ids["Cato"], expires: time.Now().Add(time.Minute)})
	w.c["Aria"].send(party.OpCreate, party.EncodeCreate(w.jid("Bram"), 0))
	w.c["Bram"].next(party.OpInvitation)
	w.c["Bram"].send(party.OpInvitation, party.EncodeAnswerYes())
	if !reviewInParty(w, "Bram") {
		t.Fatal("Bram's yes went to the resurrection offer, not the invitation")
	}
}

// An offer goes with its target's logout and its revive by another path.
func TestReview785OfferEndsWithLogoutAndRevive(t *testing.T) {
	w := newPartyWorld(t)
	ctx := context.Background()
	cato := w.ids["Cato"]
	w.hub.SetLifeState(cato, world.LifeAlive, world.LifeDead, time.Now())
	reviewPutOffer(t, cato, resurrectOffer{casterID: w.ids["Aria"], expires: time.Now().Add(time.Minute)})
	if _, _, err := reviveWith(ctx, w.chars, nil, w.hub, cato, false); err != nil {
		t.Fatalf("revive: %v", err)
	}
	if reviewHasOffer(cato) {
		t.Error("the offer outlived its target's revive")
	}
	dara := w.ids["Dara"]
	reviewPutOffer(t, dara, resurrectOffer{casterID: w.ids["Aria"], expires: time.Now().Add(time.Minute)})
	w.c["Dara"].conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for reviewHasOffer(dara) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if reviewHasOffer(dara) {
		t.Error("the offer outlived its target's logout")
	}
}

// --- Finding 4: a plain swing reads the monster's debuffs -----------------

// reviewSwing is plainSwingResults' world with a hook on the monster before
// the click; it returns the click's swing.
func reviewSwing(t *testing.T, ref itemsAndSkills, eq fixedEquipment, hp, defence int, before func(monsterID int64)) *AttackResult {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	defer keepUp.Cancel(c.ID)
	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, hp, defence, 0, 0)
	if before != nil {
		before(monster.ID)
	}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, ref, hub, monsters, quest.NewMemStore(), inventory.NewMemStore(ref), skill.NewMemStore(), nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	cl := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	cl.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	cl.next(OpLoginResult)
	cl.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	cl.next(OpEnterWorldResult)
	cl.send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(cl.next(OpAttackResult).Data)
	if err != nil || ar.Error != "" {
		t.Fatalf("swing: %v %+v", err, ar)
	}
	return ar
}

// A monster whose debuff took its flat defence away (p5, 10 -> 0) takes a
// plain swing's 2 x 60 % of 30 = 36, not the 24 its full defence allows.
// The plain swing skipped the debuffs the casts read (monsterDefence).
func TestReview785PlainSwingReadsTheMonstersDebuffs(t *testing.T) {
	items := map[int64]*refdata.Item{100: {ID: 100, TypeID4: combat.WeaponCHSword, PhysAttackMax: 30, Range: 6}}
	sword := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	ref := itemsAndSkills{items: items, skills: map[int64]*refdata.Skill{
		2: {ID: 2, ReuseDelayMs: 60000, AttackPercent: 60, HitCount: 2, AttackType: 5},
	}}
	if got := reviewSwing(t, ref, sword, 1000, 10, nil); got.MonsterDamage != 24 {
		t.Fatalf("control: %d, want 24", got.MonsterDamage)
	}
	var debuffed int64
	got := reviewSwing(t, ref, sword, 1000, 10, func(id int64) {
		debuffed = id
		spec := buff.Spec{SkillID: 990001, GroupID: 990001, CasterID: 4242, DuraMs: 60000,
			Stats: []buff.Contribution{{Param: buff.ParamPhysDefFlat, Slot: skillparam.SlotBase, Value: -10}}}
		if _, _, r, _ := monsterBooks.Start(id, spec, time.Now()); r != buff.NotRefused {
			t.Fatalf("debuff refused: %v", r)
		}
	})
	defer monsterBooks.EndAll(debuffed)
	if got.MonsterDamage != 36 {
		t.Fatalf("swing at a monster with no defence left: %d, want 36 (the debuff read)", got.MonsterDamage)
	}
	if got.Action == nil || len(got.Action.Targets) != 1 || len(got.Action.Targets[0].Hits) != 2 {
		t.Fatalf("the swing's block %+v, want one target with two hits", got.Action)
	}
}

// --- The skill world (r785World with rows of the test's own) -------------

const (
	reviewStrikeK3  = 950101 // kind 3, TR 1, hostile, 'att' and no 'lnks': strikes
	reviewNoParams  = 950102 // kind 3, TR 1, hostile, no Param block: strikes
	reviewDotLks2   = 950103 // r785Dot with 'lks2': two casters' records coexist (the Warlock DoTs' shape)
	reviewCounterID = 160
)

func reviewRows() map[int64]*refdata.Skill {
	rows := r785Rows()
	att := run("att", 4|1, 100, 10, 10, 100)
	k3 := &refdata.Skill{ID: reviewStrikeK3, GroupID: reviewStrikeK3, BasicCode: "SKILL_TEST_K3_ATT_01", BasicLevel: 1, ReqLearnSP: 1, ReqLearnRace: 3,
		Mastery1: 257, AttackPercent: 100, DamageMin: 10, DamageMax: 10, AttackType: 5, HitCount: 1,
		ReqCastWeapon1: 255, ReqCastWeapon2: 255, Range: 1000, TargetRequired: true, ActionKind: 3, ParamWords: words(3, att)}
	rows[reviewStrikeK3] = k3
	np := *k3
	np.ID, np.GroupID, np.BasicCode, np.ParamWords = reviewNoParams, reviewNoParams, "SKILL_TEST_K3_OLD_01", nil
	rows[reviewNoParams] = &np
	dot := *rows[r785Dot]
	dot.ID, dot.GroupID, dot.BasicCode, dot.Lks2 = reviewDotLks2, reviewDotLks2, "SKILL_TEST_DOT_LKS2_01", true
	dot.ParamWords = words(3, run("lnks", 9, 0, 2, 0), run("lks2"), run("dura", 1000), run("puls", 50), att)
	rows[reviewDotLks2] = &dot
	return rows
}

func startReviewSkillWorld(t *testing.T) *r785World {
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
	rows := reviewRows()
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
	w.next(t, OpLoginResult)
	w.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	w.next(t, OpEnterWorldResult)
	me, ok := hub.EntityByCharacterID(c.ID)
	if !ok {
		t.Fatal("not in the world")
	}
	w.me = me
	return w
}

// hpAfter waits d and returns the monster's HP.
func (w *r785World) hpAfter(id int64, d time.Duration) int {
	time.Sleep(d)
	m, _ := w.monsters.Get(id)
	return m.HP
}

// --- Finding 5: the chain stops with the player's own action and out of reach

// A move right after the head ends the chain: its link (100 ms later) no
// longer strikes. Nothing but a new cast cancelled a chain.
func TestReview785MoveEndsTheChain(t *testing.T) {
	w := startReviewSkillWorld(t)
	p := w.spawn(10, 0, 100000)
	ar := w.cast(t, &UseSkillRequest{SkillID: r785Head, TargetMonsterID: p})
	w.send(t, proto.OpMovementRequest, clickTo(w.me.Pos.X-40, 0, w.me.Pos.Z))
	if hp := w.hpAfter(p, 400*time.Millisecond); hp != int(ar.MonsterRemainingHP) {
		t.Fatalf("the link struck after the move: HP %d -> %d", ar.MonsterRemainingHP, hp)
	}
}

// A caster carried out of the link's reach before it posts: the link does
// not strike (OURS; retail's tick posts it with no reach test, READ, but its
// caster cannot walk while the action runs).
func TestReview785ChainLinkOutOfReachDoesNotStrike(t *testing.T) {
	w := startReviewSkillWorld(t)
	p := w.spawn(10, 0, 100000)
	ar := w.cast(t, &UseSkillRequest{SkillID: r785Head, TargetMonsterID: p})
	w.hub.Relocate(w.me.Session, world.Position{X: w.me.Pos.X + 1800, Y: w.me.Pos.Y, Z: w.me.Pos.Z}, world.MoveRelocate, 0)
	if hp := w.hpAfter(p, 400*time.Millisecond); hp != int(ar.MonsterRemainingHP) {
		t.Fatalf("the link struck from 1800 away: HP %d -> %d", ar.MonsterRemainingHP, hp)
	}
}

// --- Finding 6: a DoT pulse's kill levels its caster ---------------------

func TestReview785DotKillSendsTheLevelUp(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n1,10,1,100\n2,1000000,1,100\n3,1000000,1,100\n"))
	if err != nil {
		t.Fatal(err)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })
	w := startReviewSkillWorld(t)
	sp := combat.Species{Name: "Dummy", CodeName: "MOB_T_DOT", Level: 1, ExpToGive: 5000, HasExpToGive: true}
	m := w.monsters.SpawnSpecies(w.me.Zone, sp, w.me.Pos.X+10, w.me.Pos.Y, w.me.Pos.Z, 5, 0, 0, 0)
	w.cast(t, &UseSkillRequest{SkillID: r785Dot, TargetMonsterID: m.ID})
	lu, err := DecodeLevelUp(w.next(t, OpLevelUp).Data)
	if err != nil || lu.NewLevel < 2 {
		t.Fatalf("level-up %+v %v", lu, err)
	}
}

// --- Finding 7: the debuff gate reads the Param block --------------------

// A hostile kind-3 row with an 'att' and no 'lnks' strikes at the cast, and
// so does one with no Param block at all (a database not re-imported).
// Both were taken for debuffs and dealt nothing.
func TestReview785HostileKind3RowsWithDamageStrike(t *testing.T) {
	w := startReviewSkillWorld(t)
	for _, id := range []int64{reviewStrikeK3, reviewNoParams} {
		p := w.spawn(10, 0, 100000)
		ar := w.cast(t, &UseSkillRequest{SkillID: id, TargetMonsterID: p})
		if m, _ := w.monsters.Get(p); m.HP >= 100000 || ar.MonsterDamage <= 0 {
			t.Errorf("row %d: HP %d, damage %d; want a blow", id, m.HP, ar.MonsterDamage)
		}
		if len(monsterBooks.Active(p)) != 0 {
			t.Errorf("row %d started a debuff record", id)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// --- Finding 9: a broken link ends its own record only -------------------

func TestReview785BrokenLinkEndsOnlyItsCastersRecord(t *testing.T) {
	w := startReviewSkillWorld(t)
	for w.spawn(500, 500, 1) <= w.aria {
		// The monster's id apart from Aria's (finding 10 is its own test).
	}
	p := w.spawn(10, 0, 1000000)
	w.cast(t, &UseSkillRequest{SkillID: reviewDotLks2, TargetMonsterID: p})
	d, ok := skillDeps()
	if !ok {
		t.Fatal("no skill deps")
	}
	m, _ := w.monsters.Get(p)
	const ghost = 424242 // a caster not in the world: its link breaks at its first pulse
	if !startMonsterDebuff(d, reviewRows()[reviewDotLks2], ghost, m, time.Now()) {
		t.Fatal("the second caster's record did not start")
	}
	if n := len(monsterBooks.Active(p)); n != 2 {
		t.Fatalf("the books hold %d records after the second caster's start; want both casters' ('lks2')", n)
	}
	time.Sleep(200 * time.Millisecond)
	var mine, ghosts int
	for _, r := range monsterBooks.Active(p) {
		switch r.CasterID {
		case w.aria:
			mine++
		case ghost:
			ghosts++
		}
	}
	if mine != 1 || ghosts != 0 {
		t.Fatalf("after the ghost's link broke: Aria's records %d (want 1), the ghost's %d (want 0)", mine, ghosts)
	}
}

// --- Finding 10: monster owners and character ids do not share keys ------

func TestReview785MonsterOwnerIsNotItsCasterNamesake(t *testing.T) {
	const id = 777777
	row := reviewRows()[r785Dot]
	rec, _, r, _ := monsterBooks.Start(id, buffSpec(row, id), time.Now())
	defer monsterBooks.EndAll(id)
	if r != buff.NotRefused {
		t.Fatalf("refused %v", r)
	}
	if rec.SelfCast() {
		t.Fatal("character 777777's debuff on monster 777777 was filed as a self-cast")
	}
}

// --- Finding 12: the cast's counter names its skill ----------------------

func TestReview785CastCounterNamesThePrimarySkill(t *testing.T) {
	strikePushForTest(t, true)
	w := startReviewSkillWorld(t)
	sp := strikeMangyang
	sp.Skills = []combat.MonsterSkill{{ID: reviewCounterID, ReuseMs: 3000, Range: 10}}
	m := w.monsters.SpawnSpecies(w.me.Zone, sp, w.me.Pos.X+10, w.me.Pos.Y, w.me.Pos.Z, 100000, 0, 15, 0)
	ar := w.cast(t, &UseSkillRequest{SkillID: r785AoE, TargetMonsterID: m.ID})
	if ar.PlayerDamageTaken <= 0 {
		t.Fatalf("precondition: the counter struck; got %+v", ar)
	}
	ma, err := DecodeMonsterAttacked(w.next(t, OpMonsterAttacked).Data)
	if err != nil {
		t.Fatal(err)
	}
	if ma.SkillID != reviewCounterID {
		t.Fatalf("the counter's push names skill %d, want %d", ma.SkillID, reviewCounterID)
	}
}

// --- Finding 13: a knock's cell crossing reaches the window's edge -------

// A monster at the window's edge knocked out of it: the watcher is told it
// left. Hub.Place's crossing was dropped.
func TestReview785KnockCrossingIsDelivered(t *testing.T) {
	monsters := combat.NewHub()
	id := spawnAt(t, monsters, "jangan", cellX(1)+100, 0) // cell 1, the window's edge for a player in cell 0
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, 0, 0)
	v.reconcile()
	c.quiet(t, 100*time.Millisecond)
	m, _ := monsters.Get(id)
	cc := &castContext{d: combatDeps{monsters: monsters}, attacker: world.Entity{Zone: "jangan", Pos: world.Position{X: 0, Z: 0}}, now: time.Now()}
	h := ActionHit{}
	cc.place(&h, m, HitKindKnockback, 300, knockState{until: time.Now()})
	defer forgetKnock(id)
	if mm, _ := monsters.Get(id); combat.CellOf("jangan", mm.X, mm.Z) == combat.CellOf("jangan", m.X, m.Z) {
		t.Fatalf("precondition: the knock left the monster in its cell (%.0f -> %.0f)", m.X, mm.X)
	}
	left, _, _ := aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	if !sameIDs(left, []int64{id}) {
		t.Fatalf("left %v, want [%d]", left, id)
	}
}

// --- Finding 15: the per-character maps are freed at logout --------------

func TestReview785LogoutFreesTheCharactersState(t *testing.T) {
	InstallQuests(testQuestCatalog(), QuestDeps{Store: quest.NewMemStore()})
	defer InstallQuests(nil, QuestDeps{})
	w := startReviewSkillWorld(t)
	id := w.aria
	rememberRow(false, id, reviewRows()[r785Dot])
	nextChain(id)
	passives.Lock()
	passives.m[id] = passiveState{}
	passives.Unlock()
	if _, err := questRT.Load().logOf(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	w.conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, in := w.hub.EntityByCharacterID(id); !in {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if rowOf(false, id, r785Dot) != nil {
		t.Error("the character's rows outlived its logout")
	}
	chainGen.Lock()
	_, chain := chainGen.m[id]
	chainGen.Unlock()
	if chain {
		t.Error("the chain entry outlived the logout")
	}
	passives.Lock()
	_, pas := passives.m[id]
	passives.Unlock()
	if pas {
		t.Error("the passive set outlived the logout")
	}
	rt := questRT.Load()
	rt.mu.Lock()
	_, ql := rt.logs[id]
	rt.mu.Unlock()
	if ql {
		t.Error("the quest log outlived the logout")
	}
}

// The threat entry is not made again for a monster already gone
// (forgetThreat ran at its death).
func TestReview785NoThreatForAGoneMonster(t *testing.T) {
	const gone = 888888
	cc := &castContext{d: combatDeps{monsters: combat.NewHub()}, casterID: 1}
	addSkillHate(cc, []targetOutcome{{ok: true, before: combat.Monster{ID: gone}, total: 10}})
	threats.Lock()
	_, made := threats.m[gone]
	delete(threats.m, gone)
	threats.Unlock()
	if made {
		t.Fatal("a threat table was made for a monster no longer in the hub")
	}
}

// --- Item 16: OpAttackResult names the skill it answers -------------------

// The u32 skill id follows the action block's leading-target kind byte,
// byte for byte: a client reading "after the trailer's leading-kind byte:
// u32 skillId (0 = plain swing)" finds it there.
func TestReview785AttackResultCarriesTheSkillID(t *testing.T) {
	block := &ActionBlock{Target: 9, TargetKind: ActionTargetMonster, HitCount: 1,
		Targets: []ActionTarget{{UID: 9, Kind: ActionTargetMonster, Hits: []ActionHit{{Kind: HitKindDamage, Flags: HitFlagNormal, Damage: 5}}}}}
	res := &AttackResult{MonsterID: 9, Action: block, SkillID: 950004}
	data := res.Encode()
	tail := block.encode(nil)
	at := len(data) - 4 - len(tail)
	if at < 0 || string(data[at:at+len(tail)]) != string(tail) {
		t.Fatalf("the block is not the bytes before the last four: % x", data)
	}
	if got := binary.LittleEndian.Uint32(data[len(data)-4:]); got != 950004 {
		t.Fatalf("u32 after the leading-kind byte = %d, want 950004", got)
	}
	back, err := DecodeAttackResult(data)
	if err != nil || back.SkillID != 950004 || back.Action == nil {
		t.Fatalf("decoded %+v %v", back, err)
	}
	// No block, no skill id: the result is what it was.
	plain := (&AttackResult{MonsterID: 9}).Encode()
	if withID := (&AttackResult{MonsterID: 9, SkillID: 7}).Encode(); string(plain) != string(withID) {
		t.Fatal("a result without a block carried the skill id")
	}
}

// Through the handlers: a cast's result names its row, a plain swing's 0.
func TestReview785CastAndSwingResultsNameTheirSkill(t *testing.T) {
	w := startReviewSkillWorld(t)
	p := w.spawn(10, 0, 100000)
	if ar := w.cast(t, &UseSkillRequest{SkillID: r785AoE, TargetMonsterID: p}); ar.Action == nil || ar.SkillID != r785AoE {
		t.Fatalf("cast result: skill %d block %v, want %d", ar.SkillID, ar.Action != nil, r785AoE)
	}
	items := map[int64]*refdata.Item{100: {ID: 100, TypeID4: combat.WeaponCHSword, PhysAttackMax: 30, Range: 6}}
	sword := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	ref := itemsAndSkills{items: items, skills: map[int64]*refdata.Skill{
		2: {ID: 2, ReuseDelayMs: 60000, AttackPercent: 60, HitCount: 2, AttackType: 5},
	}}
	if got := reviewSwing(t, ref, sword, 1000, 10, nil); got.Action == nil || got.SkillID != 0 {
		t.Fatalf("plain swing result: skill %d block %v, want 0 with a block", got.SkillID, got.Action != nil)
	}
}
