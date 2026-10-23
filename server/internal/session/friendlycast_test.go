package session

// Round 622: friendly-target casts on a named character, and the zone's
// OpSkillCast. Two players, Aria (casting) and Bram (the friend), on one
// server. Rows are typed from the retail values MEASURED on the RE box, or
// marked SYNTHETIC with the MEASURED shape they stand for.

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	skPartyBuff = 8101 // SYNTHETIC id; the MEASURED shape of 20 retail rows: kind 3, TR 1, Party only (no Self, no Ally)
	skAllyBuff  = 8102 // SYNTHETIC id; the MEASURED shape of 72 retail rows: kind 3, TR 1, Ally + Party (no Self)
	skAllyBuff2 = 8103 // SYNTHETIC: skAllyBuff's level 2, the same group
)

type friendSkillRef struct{}

func (friendSkillRef) GetSkill(ctx context.Context, id int64) (*refdata.Skill, error) {
	switch id {
	case skHealA1:
		r, _ := healSkillRef{}.GetSkill(ctx, id)
		r.TargetHealHP = 369 // (heal 369, 0, 0, 0): skillparam.TargetHealAmounts
		return r, nil
	case skPartyBuff:
		return &refdata.Skill{ReqLearnSP: 1, ID: id, GroupID: 8101, BasicLevel: 1, ActionKind: 3, TargetRequired: true,
			TargetParty: true, DuraMs: 60000, NoCombatParam: true, ZeroDamage: true}, nil
	case skAllyBuff, skAllyBuff2:
		lv := 1
		if id == skAllyBuff2 {
			lv = 2
		}
		return &refdata.Skill{ReqLearnSP: 1, ID: id, GroupID: 8102, BasicLevel: lv, ActionKind: 3, TargetRequired: true,
			TargetAlly: true, TargetParty: true, DuraMs: 60000, NoCombatParam: true, ZeroDamage: true}, nil
	}
	return buffSkillRef{}.GetSkill(ctx, id)
}

type friendClient struct {
	id   int64
	conn net.Conn
	r    *bufio.Reader
	held []*proto.Packet
}

type friendWorld struct {
	chars   *character.MemStore
	hub     *world.Hub
	parties *party.Hub
	monster int64
	aria    *friendClient
	bram    *friendClient
}

func startFriendWorld(t *testing.T) *friendWorld {
	t.Helper()
	ctx := context.Background()
	// The act is announced after the row's prep + cast; the tests take it at
	// once.
	prev := swapCastAfter(func(_ time.Duration, f func()) { f() })
	t.Cleanup(func() { swapCastAfter(prev) })
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	bram, err := chars.Create(ctx, 2, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	skills := skill.NewMemStore()
	for _, id := range []int64{skHealA1, skPartyBuff, skAllyBuff, skAllyBuff2, skGrassWalkA1, skSmashA1} {
		if err := skills.Learn(ctx, aria.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	m := monsters.Spawn("jangan", "Mangyang", 1, 5000, 0, 5000, 100000, 0, 0)
	parties := party.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, friendSkillRef{}, nil, mana.NewTracker(), parties),
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
	t.Cleanup(func() { buffBooks.EndAll(aria.ID); buffBooks.EndAll(bram.ID) })
	w := &friendWorld{chars: chars, hub: hub, parties: parties, monster: m.ID}
	enter := func(user, pass, name string, id int64) *friendClient {
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		c := &friendClient{id: id, conn: conn, r: bufio.NewReader(conn)}
		c.send(t, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode())
		if lr, err := DecodeLoginResult(c.expect(t, OpLoginResult).Data); err != nil || !lr.OK {
			t.Fatalf("login %s: %v %+v", user, err, lr)
		}
		c.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		if ewr, err := DecodeEnterWorldResult(c.expect(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
			t.Fatalf("enter world %s: %v %+v", name, err, ewr)
		}
		return c
	}
	w.aria = enter("alice", "hunter2", "Aria", aria.ID)
	w.bram = enter("bob", "hunter3", "Bram", bram.ID)
	return w
}

func (c *friendClient) send(t *testing.T, op uint16, data []byte) {
	t.Helper()
	if err := proto.Write(c.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

func (c *friendClient) expect(t *testing.T, op uint16) *proto.Packet {
	t.Helper()
	for i, p := range c.held {
		if p.Opcode == op {
			c.held = append(c.held[:i], c.held[i+1:]...)
			return p
		}
	}
	for i := 0; i < 32; i++ {
		c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for 0x%04X: %v", op, err)
		}
		if p.Opcode == op {
			return p
		}
		c.held = append(c.held, p)
	}
	t.Fatalf("no 0x%04X", op)
	return nil
}

func (c *friendClient) expectNone(t *testing.T, op uint16, d time.Duration) {
	t.Helper()
	for _, p := range c.held {
		if p.Opcode == op {
			t.Fatalf("an unexpected 0x%04X: % x", op, p.Data)
		}
	}
	deadline := time.Now().Add(d)
	for {
		c.conn.SetReadDeadline(deadline)
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			return
		}
		if p.Opcode == op {
			t.Fatalf("an unexpected 0x%04X: % x", op, p.Data)
		}
		c.held = append(c.held, p)
	}
}

func (w *friendWorld) cast(t *testing.T, req *UseSkillRequest) *AttackResult {
	t.Helper()
	req.CharacterName = "Aria"
	w.aria.send(t, OpUseSkill, req.Encode())
	ar, err := DecodeAttackResult(w.aria.expect(t, OpAttackResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	return ar
}

func (w *friendWorld) expectCast(t *testing.T, c *friendClient, phase uint8) *SkillCast {
	t.Helper()
	sc, err := DecodeSkillCast(c.expect(t, OpSkillCast).Data)
	if err != nil {
		t.Fatal(err)
	}
	if sc.Phase != phase {
		t.Fatalf("OpSkillCast phase %d, want %d: %+v", sc.Phase, phase, sc)
	}
	return sc
}

// Heal on another player: Bram's HP rises by the row's 369 (capped at his
// maximum), his client is pushed his stats, and he -- not Aria -- is told of
// Aria's cast, start then act, naming him as its target.
func TestHealOnAnotherPlayerRestoresHisHP(t *testing.T) {
	w := startFriendWorld(t)
	ctx := context.Background()
	bram, _ := w.chars.GetByID(ctx, w.bram.id)
	if _, _, err := w.chars.ApplyDamage(ctx, w.bram.id, bram.HP-1); err != nil {
		t.Fatal(err)
	}
	ar := w.cast(t, &UseSkillRequest{SkillID: skHealA1, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true})
	if ar.Error != "" {
		t.Fatalf("Heal on Bram refused: %q", ar.Error)
	}
	if ar.EchoedTargetType() != TargetCharacter || ar.MonsterID != 0 {
		t.Fatalf("reply echoes type %d monster %d, want 3 and 0", ar.EchoedTargetType(), ar.MonsterID)
	}
	after, _ := w.chars.GetByID(ctx, w.bram.id)
	want := 1 + 369
	if want > after.MaxHP() {
		want = after.MaxHP()
	}
	if after.HP != want {
		t.Fatalf("Bram's HP %d after the Heal, want %d (1 + 369, capped at %d)", after.HP, want, after.MaxHP())
	}
	stats, err := DecodeCharacterStatsResult(w.bram.expect(t, OpCharacterStatsResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	if int(stats.HP) != want {
		t.Fatalf("Bram's pushed HP %d, want %d", stats.HP, want)
	}
	start := w.expectCast(t, w.bram, CastPhaseStart)
	if start.CasterID != w.aria.id || start.CasterKind != OwnerCharacter || start.SkillID != skHealA1 ||
		start.TargetType != TargetCharacter || start.TargetID != w.bram.id || start.CastID == 0 {
		t.Fatalf("OpSkillCast start %+v", start)
	}
	act := w.expectCast(t, w.bram, CastPhaseAct)
	if act.CastID != start.CastID || act.TargetID != w.bram.id {
		t.Fatalf("OpSkillCast act %+v does not pair with start %+v", act, start)
	}
	w.aria.expectNone(t, OpSkillCast, 200*time.Millisecond)
}

// Heal on oneself, named by one's own id (Self is set): the caster's HP.
func TestHealOnOneselfByName(t *testing.T) {
	w := startFriendWorld(t)
	ctx := context.Background()
	aria, _ := w.chars.GetByID(ctx, w.aria.id)
	w.chars.ApplyDamage(ctx, w.aria.id, aria.HP-1)
	ar := w.cast(t, &UseSkillRequest{SkillID: skHealA1, TargetMonsterID: w.aria.id, TargetType: TargetCharacter, HasTargetType: true})
	if ar.Error != "" {
		t.Fatalf("Heal on oneself refused: %q", ar.Error)
	}
	after, _ := w.chars.GetByID(ctx, w.aria.id)
	if after.HP <= 1 || int(ar.PlayerHP) != after.HP {
		t.Fatalf("Aria's HP %d, the reply's %d: want the heal on her", after.HP, ar.PlayerHP)
	}
}

// A friend beyond the skill's reach is refused before anything is spent.
func TestHealOutOfReachIsRefused(t *testing.T) {
	w := startFriendWorld(t)
	e, _ := w.hub.EntityByCharacterID(w.bram.id)
	w.bram.send(t, OpMove, (&MoveRequest{X: float32(e.Pos.X) + 400, Y: float32(e.Pos.Y), Z: float32(e.Pos.Z)}).Encode())
	deadline := time.Now().Add(2 * time.Second)
	for {
		if cur, _ := w.hub.EntityByCharacterID(w.bram.id); cur.Pos.X > e.Pos.X+300 || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	ar := w.cast(t, &UseSkillRequest{SkillID: skHealA1, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true})
	if ar.Error != "too far away" {
		t.Fatalf("Heal 400 away answered %q, want \"too far away\" (Range 150)", ar.Error)
	}
}

// A Party-only buff needs caster and target in the same party (FUN_0058d7a0
// step 8); then it starts on the target, cast by the caster, and the zone
// hears it.
func TestPartyBuffNeedsTheSameParty(t *testing.T) {
	w := startFriendWorld(t)
	req := &UseSkillRequest{SkillID: skPartyBuff, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true}
	if ar := w.cast(t, req); ar.Error != "Invalid target" {
		t.Fatalf("a Party-only buff on a stranger answered %q, want \"Invalid target\"", ar.Error)
	}
	if _, err := w.parties.Form(party.Member{Session: gateway.NewTestSession(9001), CharacterID: w.aria.id, Name: "Aria", Level: party.MinCreatorLevel},
		party.Member{Session: gateway.NewTestSession(9002), CharacterID: w.bram.id, Name: "Bram"}, party.FlagExpShare); err != nil {
		t.Fatal(err)
	}
	req = &UseSkillRequest{SkillID: skPartyBuff, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true}
	if ar := w.cast(t, req); ar.Error != "" {
		t.Fatalf("a Party-only buff on a party member refused: %q", ar.Error)
	}
	start, err := DecodeBuffStart(w.bram.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	if start.OwnerID != w.bram.id || start.SkillID != skPartyBuff {
		t.Fatalf("OpBuffStart %+v, want Bram's", start)
	}
	recs := buffBooks.Active(w.bram.id)
	if len(recs) != 1 || recs[0].CasterID != w.aria.id || recs[0].SelfCast() {
		t.Fatalf("Bram's book %+v, want one record cast by Aria", recs)
	}
	if n := len(buffBooks.Active(w.aria.id)); n != 0 {
		t.Fatalf("Aria's book has %d records, want none", n)
	}
}

// An Ally buff with no Self may not be cast on oneself (step 5).
func TestAllyBuffWithoutSelfRefusesTheCaster(t *testing.T) {
	w := startFriendWorld(t)
	ar := w.cast(t, &UseSkillRequest{SkillID: skAllyBuff, TargetMonsterID: w.aria.id, TargetType: TargetCharacter, HasTargetType: true})
	if ar.Error != "Invalid target" {
		t.Fatalf("an Ally buff without Self on its caster answered %q, want \"Invalid target\"", ar.Error)
	}
	if ar := w.cast(t, &UseSkillRequest{SkillID: skAllyBuff, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true}); ar.Error != "" {
		t.Fatalf("an Ally buff on another player refused: %q", ar.Error)
	}
}

// A hostile skill named at a character is vslot_394's (round 802,
// jobpvp.go): two low-level players out of a job are refused the PK's level
// test first (0x3016), before anything is spent and with no cast announced.
func TestHostileSkillAtACharacterIsRefused(t *testing.T) {
	w := startFriendWorld(t)
	ar := w.cast(t, &UseSkillRequest{SkillID: skSmashA1, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true})
	if ar.Error != "UIIT_MSG_SKILL_USE_FAIL_YOUR_LEVEL_TOO_LOW_TO_PK" {
		t.Fatalf("Smash at a character answered %q, want the PK level refusal", ar.Error)
	}
	w.bram.expectNone(t, OpSkillCast, 200*time.Millisecond)
}

// A hostile skill at an opposed job lands (round 802, performSkillAttackPvP):
// a thief's Smash on a trader answers its damage with targetType 3, the
// trader hears OpPlayerStruck and the zone the cast.
func TestHostileSkillAtAnOpposedJobLands(t *testing.T) {
	w := startFriendWorld(t)
	ctx := context.Background()
	for _, id := range []int64{w.aria.id, w.bram.id} {
		if err := w.chars.SetLeveling(ctx, id, 50, 0, 0, 60, 60); err != nil {
			t.Fatal(err)
		}
		w.hub.SetLevel(id, 50)
	}
	jobStates.Store(w.aria.id, jobs.StateThief)
	jobStates.Store(w.bram.id, jobs.StateTrader)
	t.Cleanup(func() {
		jobStates.Delete(w.aria.id)
		jobStates.Delete(w.bram.id)
		pvpKeepUp.cancel(w.aria.id)
	})
	before, _ := w.chars.GetByID(ctx, w.bram.id)
	ar := w.cast(t, &UseSkillRequest{SkillID: skSmashA1, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true})
	if ar.Error != "" || ar.MonsterDamage < 1 || ar.MonsterID != w.bram.id || ar.TargetType != TargetCharacter || ar.SkillID != skSmashA1 {
		t.Fatalf("Smash at an opposed trader: %+v", ar)
	}
	st := w.bram.expect(t, OpPlayerStruck).Data
	if binary.LittleEndian.Uint32(st) != uint32(w.aria.id) || binary.LittleEndian.Uint32(st[5:]) != uint32(w.bram.id) ||
		int32(binary.LittleEndian.Uint32(st[9:])) != ar.MonsterDamage {
		t.Fatalf("OpPlayerStruck % x for %d damage", st, ar.MonsterDamage)
	}
	after, _ := w.chars.GetByID(ctx, w.bram.id)
	if after.HP != before.HP-int(ar.MonsterDamage) {
		t.Fatalf("Bram's HP %d -> %d for %d damage", before.HP, after.HP, ar.MonsterDamage)
	}
	if start := w.expectCast(t, w.bram, CastPhaseStart); start.TargetID != w.bram.id || start.TargetType != TargetCharacter {
		t.Fatalf("OpSkillCast start %+v", start)
	}
}

// Grass Walk's cast is announced to the zone -- Bram, not Aria -- with no
// target, start then act.
func TestSelfCastIsAnnouncedToTheZone(t *testing.T) {
	w := startFriendWorld(t)
	if ar := w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true}); ar.Error != "" {
		t.Fatalf("Grass Walk refused: %q", ar.Error)
	}
	start := w.expectCast(t, w.bram, CastPhaseStart)
	if start.CasterID != w.aria.id || start.SkillID != skGrassWalkA1 || start.TargetType != TargetNone || start.TargetID != 0 {
		t.Fatalf("OpSkillCast start %+v", start)
	}
	w.expectCast(t, w.bram, CastPhaseAct)
	w.aria.expectNone(t, OpSkillCast, 200*time.Millisecond)
}

// A refused cast is not announced.
func TestRefusedCastIsNotAnnounced(t *testing.T) {
	w := startFriendWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skHealA1, TargetType: TargetNone, HasTargetType: true})
	w.bram.expectNone(t, OpSkillCast, 200*time.Millisecond)
}

func TestSkillCastRoundTripAndOpcode(t *testing.T) {
	in := SkillCast{CasterID: 7, CasterKind: OwnerMonster, SkillID: 149, CastID: 9, Phase: CastPhaseAct,
		TargetType: TargetGround, TargetID: 0, X: 1.5, Y: -2, Z: 3.25}
	b := in.Encode()
	if len(b) != 43 {
		t.Fatalf("OpSkillCast is %d bytes, want 43", len(b))
	}
	out, err := DecodeSkillCast(b)
	if err != nil || *out != in {
		t.Fatalf("round trip %+v %v, want %+v", out, err, in)
	}
	if _, err := DecodeSkillCast(b[:42]); err == nil {
		t.Fatal("a short OpSkillCast decoded")
	}
	if OpSkillCast != 0x00FA {
		t.Fatalf("OpSkillCast 0x%04X, want 0x00FA", OpSkillCast)
	}
	req := &UseSkillRequest{CharacterName: "Aria", SkillID: 149, TargetMonsterID: 42, TargetType: TargetCharacter, HasTargetType: true}
	got, err := DecodeUseSkillRequest(req.Encode())
	if err != nil || got.Target() != TargetCharacter || got.TargetMonsterID != 42 {
		t.Fatalf("targetType 3 round trip: %+v %v", got, err)
	}
}

func TestCastActDelay(t *testing.T) {
	if d := castActDelay(&refdata.Skill{ReqLearnSP: 1, PreparingTimeMs: 1000, CastingTimeMs: 1000}); d != 2*time.Second {
		t.Fatalf("Heal's act after %v, want 2s (prep + cast)", d)
	}
	if d := castActDelay(&refdata.Skill{ReqLearnSP: 1}); d != 0 {
		t.Fatalf("Grass Walk's act after %v, want at once", d)
	}
	if d := castActDelay(&refdata.Skill{ReqLearnSP: 1, CastingTimeMs: 60000}); d != castActMax {
		t.Fatalf("a 60 s cast's act after %v, want the %v bound", d, castActMax)
	}
	if d := castActDelay(nil); d != 0 {
		t.Fatalf("a catalog skill's act after %v", d)
	}
}

var _ = errors.New

// Round 622's review: the recast rule on the TARGET's book (FUN_0058cc70 ->
// FUN_0059d870(target+0xa30), 0x58d2ca..0x58d2d3). Three casts of the same
// level on one ally leave one record; a lower level over a higher one is
// refused 0x300c before anything is spent.
func TestFriendlyBuffRecastOnTheTarget(t *testing.T) {
	w := startFriendWorld(t)
	on := func(skillID int64) *AttackResult {
		return w.cast(t, &UseSkillRequest{SkillID: skillID, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true})
	}
	for i := 0; i < 3; i++ {
		if ar := on(skAllyBuff2); ar.Error != "" {
			t.Fatalf("cast %d of the ally buff refused: %q", i+1, ar.Error)
		}
	}
	if recs := buffBooks.Active(w.bram.id); len(recs) != 1 {
		t.Fatalf("three casts on one ally left %d records, want 1", len(recs))
	}
	if ar := on(skAllyBuff); ar.Error != overlapRefusal {
		t.Fatalf("a lower level over a higher one answered %q, want %q (0x300c)", ar.Error, overlapRefusal)
	}
	if recs := buffBooks.Active(w.bram.id); len(recs) != 1 || recs[0].SkillID != skAllyBuff2 {
		t.Fatalf("after the refused lower level Bram's book is %+v", recs)
	}
}

// Round 622's review: a cast performAttack refuses after its costs (the
// monster is gone) is not announced.
func TestCastRefusedInsidePerformAttackIsNotAnnounced(t *testing.T) {
	w := startFriendWorld(t)
	ar := w.cast(t, &UseSkillRequest{SkillID: skSmashA1, TargetMonsterID: 987654, TargetType: TargetEntity, HasTargetType: true})
	if ar.Error != "target not found" {
		t.Fatalf("Smash at no monster answered %q, want \"target not found\"", ar.Error)
	}
	w.bram.expectNone(t, OpSkillCast, 300*time.Millisecond)
}

// Round 622's review: a delayed act is dropped when the caster arrived anew
// (a teleport, even into the same bucket) between the start and the act.
func TestDelayedActDroppedAfterATeleport(t *testing.T) {
	w := startFriendWorld(t)
	pending := make(chan func(), 4)
	swapCastAfter(func(_ time.Duration, f func()) { pending <- f })
	if ar := w.cast(t, &UseSkillRequest{SkillID: skHealA1, TargetMonsterID: w.bram.id, TargetType: TargetCharacter, HasTargetType: true}); ar.Error != "" {
		t.Fatalf("Heal refused: %q", ar.Error)
	}
	w.expectCast(t, w.bram, CastPhaseStart)
	var act func()
	select {
	case act = <-pending:
	case <-time.After(2 * time.Second):
		t.Fatal("no delayed act was scheduled (Heal's prep + cast)")
	}
	e, _ := w.hub.EntityByCharacterID(w.aria.id)
	if _, _, _, ok := w.hub.ChangeZone(e.Session, e.Zone, world.Position{X: e.Pos.X + 500, Y: e.Pos.Y, Z: e.Pos.Z}); !ok {
		t.Fatal("teleport failed")
	}
	act()
	w.bram.expectNone(t, OpSkillCast, 300*time.Millisecond)
}

// swapCastAfter replaces the delayed-act hook under its lock and returns the
// one it replaced.
func swapCastAfter(h func(time.Duration, func())) func(time.Duration, func()) {
	castAfterMu.Lock()
	defer castAfterMu.Unlock()
	prev := castAfterHook
	castAfterHook = h
	return prev
}
