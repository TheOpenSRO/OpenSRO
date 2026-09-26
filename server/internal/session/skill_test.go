package session

import (
	"bufio"
	"context"
	"errors"
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

// stubSkillRef knows no real skills, so LearnSkillHandler falls back to the
// own-design combat catalog (Power Strike etc.) -- what this test learns/uses.
type stubSkillRef struct{}

func (stubSkillRef) GetSkill(_ context.Context, _ int64) (*refdata.Skill, error) {
	return nil, errors.New("no such skill")
}

// skill998ManaCost is two thirds of a starting caster's mana pool: enough that
// one cast lands and a second is refused.
const skill998ManaCost = character.StartingMaxMP * 2 / 3

// fakeSkillRef knows one real (refdata) skill, id 999, learnable for free (no
// mastery/SP gate) so the full network flow can learn and CAST a real skill.
// Every other id falls through to the own-design catalog, as in production.
type fakeSkillRef struct{}

func (fakeSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if id == 999 {
		return &refdata.Skill{ID: 999, BasicLevel: 1, ReuseDelayMs: 500}, nil
	}
	// 998 is the mana test: no cooldown, and a Consume_MP pinned to two
	// thirds of a starting caster's pool so exactly one cast is affordable.
	// Tied to the pool rather than written as a number, because the pool comes
	// from the recovered Int-based formula and a literal would silently stop
	// testing the refusal the moment that changed.
	if id == 998 {
		return &refdata.Skill{ID: 998, BasicLevel: 1, ReuseDelayMs: 0, ConsumeMP: skill998ManaCost}, nil
	}
	// 997 carries a REAL 'att' parameter -- 200% and no flat term -- so the
	// skill-percentage path can be exercised end to end. See
	// TestSkillPercentageAppliesAfterMitigation.
	if id == 997 {
		return &refdata.Skill{ID: 997, BasicLevel: 1, ReuseDelayMs: 0, AttackPercent: 200}, nil
	}
	// 996 carries NO combat parameter -- a buff, heal or passive, which is
	// 5.6% of the real table. BasicLevel 5 is deliberate: under the disclosed
	// fallback this skill dealt 5 * DisclosedSkillDamagePerLevel, so a test
	// that finds zero is finding the flag and not an accident of the numbers.
	if id == 996 {
		return &refdata.Skill{ID: 996, BasicLevel: 5, ReuseDelayMs: 0, NoCombatParam: true}, nil
	}
	// 995 is the WIDER case: it carries a combat parameter, so the engine does
	// resolve a blow for it, but it has no 'att' and no 'ck', so `local_d0` is
	// 1 and the blow's damage is zero. 669 real rows are like this, and they
	// are NOT covered by NoCombatParam.
	if id == 995 {
		return &refdata.Skill{ID: 995, BasicLevel: 5, ReuseDelayMs: 0, ZeroDamage: true}, nil
	}
	// 994 is a FLOOR blow: it carries 'att', so the engine does compute its
	// damage, but with a percent of 0 -- the mall pets' elemental skills are 420
	// of the 446 real rows like this. The computed blow is identically zero and
	// the engine floors it at 1.
	if id == 994 {
		return &refdata.Skill{ID: 994, BasicLevel: 5, ReuseDelayMs: 0, FloorBlow: true}, nil
	}
	// 993 is a flat SELF-HEAL, SKILL_CH_WATER_SELFHEAL's shape (round 503): no
	// combat parameter, and a 'heal' the exporter turned into SelfHealHP. 992
	// is its MP twin, SKILL_EU_BARD_RECOVERA_ABNORMALTIME's shape.
	if id == 993 {
		return &refdata.Skill{ID: 993, BasicLevel: 1, ReuseDelayMs: 0, NoCombatParam: true, ZeroDamage: true, SelfHealHP: 50}, nil
	}
	if id == 992 {
		return &refdata.Skill{ID: 992, BasicLevel: 1, ReuseDelayMs: 0, NoCombatParam: true, ZeroDamage: true, SelfHealMP: 50}, nil
	}
	// 990 carries 'ao' or 'pw' -- a Cold/Fire Wall's shape (round 605): the
	// skill-use gate refuses it to a seated caster. 996 above carries neither.
	if id == 990 {
		return &refdata.Skill{ID: 990, BasicLevel: 1, ReuseDelayMs: 0, NoCombatParam: true, SitGate: refdata.SitGateActionOff}, nil
	}
	return nil, errors.New("no such skill")
}

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
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		LearnSkillHandler(chars, skills, fakeSkillRef{}),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
		SkillListHandler(chars, skills),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		// Through readReply (round 544): with -monster-strike-push on, the
		// Power Strike cast's counter is followed by its OpMonsterAttacked,
		// and a reader that took the next packet as the next reply decoded
		// that push as the cooldown refusal (TestCounterTestsHoldWithTheStrikePushOn).
		return readReply(t, conn, r)
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

	// Before learning anything, the list should show both catalog skills,
	// neither known.
	resp = send(OpSkillList, (&SkillListRequest{CharacterName: "Aria"}).Encode())
	slr, err := DecodeSkillListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeSkillListResult: %v", err)
	}
	if slr.Error != "" || len(slr.Skills) != 2 {
		t.Fatalf("got %+v, want 2 skills no error", slr)
	}
	if slr.Skills[0].ID != 1 || slr.Skills[0].Known || slr.Skills[0].Name != "Power Strike" {
		t.Fatalf("got %+v, want skill 1 'Power Strike' not known", slr.Skills[0])
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

	// The list should now show skill 1 as known and on cooldown.
	resp = send(OpSkillList, (&SkillListRequest{CharacterName: "Aria"}).Encode())
	slr, err = DecodeSkillListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeSkillListResult: %v", err)
	}
	if !slr.Skills[0].Known {
		t.Fatalf("got %+v, want skill 1 known", slr.Skills[0])
	}
	if slr.Skills[0].ReadySeconds <= 0 {
		t.Fatalf("got %+v, want skill 1 to report a positive cooldown remaining", slr.Skills[0])
	}

	// A real (refdata) skill, id 999 (BasicLevel 1): learn it (free here) then
	// cast it. It takes the real ReuseDelay cooldown and adds the DISCLOSED
	// own-design skill bonus (BasicLevel * DisclosedSkillDamagePerLevel = 1*4):
	// 30 weapon + 4 skill - 10 defense = 24. (The real formula is unrecoverable
	// -- skill damage is server-authoritative; see disclosedSkillDamageBonus.)
	resp = send(OpLearnSkill, (&LearnSkillRequest{CharacterName: "Aria", SkillID: 999}).Encode())
	if lr, err := DecodeLearnSkillResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("learn real skill failed: err=%v result=%+v", err, lr)
	}
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 999, TargetMonsterID: monster.ID}).Encode())
	ar, err = DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	want := 30 + DisclosedSkillDamagePerLevel - 10
	if ar.Error != "" || int(ar.MonsterDamage) != want {
		t.Fatalf("got %+v, want a real-skill cast for %d damage (30 weapon + %d skill - 10 defense)", ar, want, DisclosedSkillDamagePerLevel)
	}
	// Immediately again: the real ReuseDelay (500ms) keeps it on cooldown.
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 999, TargetMonsterID: monster.ID}).Encode())
	if ar2, err := DecodeAttackResult(resp.Data); err != nil || ar2.Error != "skill on cooldown" {
		t.Fatalf("got %+v (err %v), want error 'skill on cooldown'", ar2, err)
	}

	// A skill's real Consume_MP is actually spent, and a cast that cannot be
	// paid for is refused. Skill 998 costs two thirds of a starting caster's
	// pool, so the first cast lands and the second cannot.
	resp = send(OpLearnSkill, (&LearnSkillRequest{CharacterName: "Aria", SkillID: 998}).Encode())
	if lr, err := DecodeLearnSkillResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("learn mana-costing skill failed: err=%v result=%+v", err, lr)
	}
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 998, TargetMonsterID: monster.ID}).Encode())
	if ar3, err := DecodeAttackResult(resp.Data); err != nil || ar3.Error != "" {
		t.Fatalf("first cast of a %d-mana skill should land: got %+v (err %v)", skill998ManaCost, ar3, err)
	}
	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 998, TargetMonsterID: monster.ID}).Encode())
	if ar4, err := DecodeAttackResult(resp.Data); err != nil || ar4.Error != "not enough mana" {
		t.Fatalf("second cast should be refused for mana: got %+v (err %v)", ar4, err)
	}
}

// TestSkillPercentageAppliesAfterMitigation drives a real percentage skill
// through the whole network path and pins that its percentage lands AFTER the
// target's defence is subtracted, not before.
//
// The engine's order is mitigate, clamp at zero, then multiply by the skill's
// percentage (Formula_MitigatePhysicalDamage 0040e450; see
// combat.ApplySkillPercent). With a 30-damage weapon, a 200% skill and a
// monster carrying 10 flat defence:
//
//	correct:  (30 - 10) * 2 = 40
//	wrong:    (30 * 2) - 10 = 50
//
// This code produced 50 until 2026-09-15, because the percentage was folded
// into the raw roll before mitigation.
func TestSkillPercentageAppliesAfterMitigation(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	// A degenerate weapon range so the blow is exact, and no reinforce so
	// Strength contributes nothing to this particular assertion.
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
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
	if err := skills.Learn(ctx, c.ID, 997); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 997, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("skill cast failed: %s", ar.Error)
	}
	const wantCorrect, wantWrongOrder = 40, 50
	if ar.MonsterDamage == wantWrongOrder {
		t.Fatalf("skill damage %d: the percentage was applied BEFORE mitigation", ar.MonsterDamage)
	}
	if ar.MonsterDamage != wantCorrect {
		t.Fatalf("skill damage = %d, want %d ((30 - 10) * 2)", ar.MonsterDamage, wantCorrect)
	}
}

// Casting a skill the engine resolves no blow for must not hurt the monster.
//
// This is the behaviour Combat_ResolveDamage's 33-parameter test settles: it
// RETURNS before resolving anything when a skill carries none of them. Before
// refdata.Skill.NoCombatParam existed, every such skill dealt
// DisclosedSkillDamagePerLevel * level, so using a buff on a monster hurt it.
//
// Skill 996 is level 5, so the old behaviour would be a visible 20 damage.
func TestNoCombatParamSkillDealsNoDamage(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
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
	if err := skills.Learn(ctx, c.ID, 996); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)
	before := monster.HP

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 996, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	// The cast SUCCEEDS -- the engine pays the costs and records the use, it
	// simply resolves no blow.
	if ar.Error != "" {
		t.Fatalf("cast of a no-combat skill failed: %s", ar.Error)
	}
	if ar.MonsterDamage != 0 {
		t.Errorf("a skill with no combat parameter dealt %d damage, want 0", ar.MonsterDamage)
	}
	if monster.HP != before {
		t.Errorf("monster HP %d -> %d; a skill with no combat parameter must not hurt it", before, monster.HP)
	}
}

func TestZeroDamageSkillDealsNoDamage(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
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
	if err := skills.Learn(ctx, c.ID, 995); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)
	before := monster.HP

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 995, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	// The cast SUCCEEDS -- the engine pays the costs and records the use, it
	// simply resolves no blow.
	if ar.Error != "" {
		t.Fatalf("cast of a no-combat skill failed: %s", ar.Error)
	}
	if ar.MonsterDamage != 0 {
		t.Errorf("a zero-damage skill dealt %d damage, want 0", ar.MonsterDamage)
	}
	if monster.HP != before {
		t.Errorf("monster HP %d -> %d; a zero-damage skill must not hurt it", before, monster.HP)
	}
}

// A FLOOR blow: the skill carries 'att', so Combat_ResolveDamage computes its
// damage, but the percent is 0, the mitigation formulas multiply by it with no
// guard, and the engine floors the computed zero at 1. The weapon here rolls 30
// into a defence of 10, so anything but exactly 1 means the percent was read as
// "no percentage" (a full 20) or the disclosed bonus crept back in (40).
func TestFloorBlowSkillDealsExactlyOne(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
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
	if err := skills.Learn(ctx, c.ID, 994); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)
	before := monster.HP

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 994, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	// The cast SUCCEEDS -- the engine pays the costs and records the use, it
	// simply resolves no blow.
	if ar.Error != "" {
		t.Fatalf("cast of a no-combat skill failed: %s", ar.Error)
	}
	if ar.MonsterDamage != 1 {
		t.Errorf("a floor-blow skill dealt %d damage, want exactly 1", ar.MonsterDamage)
	}
	if monster.HP != before-1 {
		t.Errorf("monster HP %d -> %d; a floor blow takes exactly 1", before, monster.HP)
	}
}

// Damage kind 4: a PC whose weapon-slot item has TypeID4 == 16, a fortress
// weapon, deals exactly 1 to anything that is not a fortress structure.
// Combat_ResolveDamage tests `(Equip_GetWeaponTID() & 0xf800) == 0x8000` and its
// case 4 writes `total = 1`. See combat.SelectDamageKind.
func TestFortressWeaponDealsExactlyOne(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	// A degenerate weapon range so the blow is exact, and no reinforce so
	// Strength contributes nothing to this particular assertion.
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30, TypeID3: 6, TypeID4: combat.FortressWeaponTypeID4}}
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
	if err := skills.Learn(ctx, c.ID, 997); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 997, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("skill cast failed: %s", ar.Error)
	}
	// Skill 997 is 200% of a 30-point weapon into 10 defence -- 40 on the
	// ordinary kind. A fortress weapon is damage kind 4, which assigns the
	// total directly and past every formula, so the percentage never applies.
	if ar.MonsterDamage != 1 {
		t.Fatalf("a fortress weapon dealt %d, want exactly 1 (40 would mean the ordinary kind ran)", ar.MonsterDamage)
	}
}

// Damage kind 2: the hard-coded event list. EventMobList_BuildWinterSnowman
// (0x00615b20) looks up the literal "MOB_EV_WINTER_SNOWMAN" and stores 1 as the
// damage every blow deals, and real characterdata gives that monster 11 HP --
// eleven blows from anyone, whatever they are holding.
func TestWinterSnowmanTakesExactlyOnePerBlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	// A degenerate weapon range so the blow is exact, and no reinforce so
	// Strength contributes nothing to this particular assertion.
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
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
	if err := skills.Learn(ctx, c.ID, 997); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.SpawnSpecies("jangan", combat.Species{Name: "Snowman", CodeName: "MOB_EV_WINTER_SNOWMAN"}, 0, 0, 0, 11, 10, 5, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	resp = send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 997, TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeAttackResult: %v", err)
	}
	if ar.Error != "" {
		t.Fatalf("skill cast failed: %s", ar.Error)
	}
	// The same 200% skill that lands for 40 on a Mangyang. The snowman's real
	// MaxHP is 11, so under the ordinary kind this one cast would kill it.
	if ar.MonsterDamage != 1 {
		t.Fatalf("the winter snowman took %d, want exactly 1", ar.MonsterDamage)
	}
	if ar.MonsterDied || ar.MonsterRemainingHP != 10 {
		t.Fatalf("after one blow: died=%v hp=%d, want alive at 10 of 11", ar.MonsterDied, ar.MonsterRemainingHP)
	}
}

// Round 503: a flat self-heal restores its authored amount to the caster,
// capped at the maximum, and every non-damaging cast reports the caster's real
// HP. Before it, PlayerHP was left at its zero value on this path -- the HUD
// painted an empty bar after any buff -- and the heal did nothing.
func TestSelfHealSkillRestoresCasterHP(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	maxHP, maxMP := c.MaxHP(), c.MaxMP()
	if maxHP != 200 {
		t.Fatalf("test premise: a new character's max HP is %d, want 200", maxHP)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	inv.TruncateForTest(ctx)

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)

	skills, err := skill.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("skill.OpenSQLStore: %v", err)
	}
	defer skills.Close()
	skills.TruncateForTest(ctx)
	for _, id := range []int64{993, 992, 996} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatalf("Learn %d: %v", id, err)
		}
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)
	monsterBefore := monster.HP

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	mp := mana.NewTracker()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, fakeSkillRef{}, nil, mp, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	cast := func(id int64) *AttackResult {
		t.Helper()
		resp := send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: id, TargetMonsterID: monster.ID}).Encode())
		ar, err := DecodeAttackResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeAttackResult: %v", err)
		}
		if ar.Error != "" {
			t.Fatalf("cast of %d failed: %s", id, ar.Error)
		}
		return ar
	}
	storedHP := func() int {
		t.Helper()
		got, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("GetByID: %v", err)
		}
		return got.HP
	}
	setHP := func(hp int) {
		t.Helper()
		if _, _, err := chars.ApplyDamage(ctx, c.ID, storedHP()-hp); err != nil {
			t.Fatalf("ApplyDamage: %v", err)
		}
		if got := storedHP(); got != hp {
			t.Fatalf("test premise: HP %d, want %d", got, hp)
		}
	}

	// 100 of 200, then a 50-point self-heal: 150, reported and stored, and the
	// selected monster untouched.
	setHP(100)
	if ar := cast(993); ar.PlayerHP != 150 {
		t.Errorf("self-heal from 100: PlayerHP = %d, want 150", ar.PlayerHP)
	}
	if got := storedHP(); got != 150 {
		t.Errorf("self-heal from 100: stored HP = %d, want 150", got)
	}
	if monster.HP != monsterBefore {
		t.Errorf("monster HP %d -> %d; a self-heal must not touch it", monsterBefore, monster.HP)
	}

	// Ten short of the maximum: capped, as GObjChar::FUN_004a66f0 clamps.
	setHP(maxHP - 10)
	if ar := cast(993); ar.PlayerHP != int32(maxHP) {
		t.Errorf("self-heal from max-10: PlayerHP = %d, want the cap %d", ar.PlayerHP, maxHP)
	}
	if got := storedHP(); got != maxHP {
		t.Errorf("self-heal from max-10: stored HP = %d, want %d", got, maxHP)
	}

	// A plain buff heals nothing but still reports the real HP, not 0.
	setHP(170)
	if ar := cast(996); ar.PlayerHP != 170 {
		t.Errorf("plain buff: PlayerHP = %d, want the current 170", ar.PlayerHP)
	}
	if got := storedHP(); got != 170 {
		t.Errorf("plain buff changed HP to %d", got)
	}

	// The MP half lands in the mana pool.
	if _, ok := mp.Spend(c.ID, maxMP, 60); !ok {
		t.Fatal("test premise: could not spend 60 MP")
	}
	mpBefore := mp.Current(c.ID, maxMP)
	cast(992)
	if got := mp.Current(c.ID, maxMP); got < mpBefore+50 {
		t.Errorf("MP self-heal: %d -> %d, want at least %d", mpBefore, got, mpBefore+50)
	}

	// A dead caster is not healed (0x5942c0: the caster must be alive).
	setHP(0)
	if ar := cast(993); ar.PlayerHP != 0 {
		t.Errorf("dead caster: PlayerHP = %d, want 0", ar.PlayerHP)
	}
	if got := storedHP(); got != 0 {
		t.Errorf("dead caster: stored HP = %d, want 0", got)
	}
}

// Round 504: skills in one cooldown group share one re-use timer, as
// SkillCooldowns::IsReady (0x64c1a0) answers from the group map for a
// non-zero Overlap high byte. The rows are no-blow casts so the test is about
// the timer and nothing else: 993 and 992 are group 2 (Smash A and Smash D's
// shape), 991 is group 3, 990 ungrouped, and 989 is group 2 with no ReuseDelay
// -- IsReady's +0x7c guard answers ready for it without consulting the group.
func TestSkillCooldownGroupIsShared(t *testing.T) {
	// The group map is process-wide; start this test from an empty one, and
	// keep the two names pointing at the one tracker, as in production. Put
	// the process's tracker back afterwards, so no later test inherits the
	// timers this one arms.
	savedItems, savedGroups := itemCooldowns, skillGroupCooldowns
	t.Cleanup(func() { itemCooldowns, skillGroupCooldowns = savedItems, savedGroups })
	itemCooldowns = newItemCooldownTracker()
	skillGroupCooldowns = itemCooldowns

	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	inv.TruncateForTest(ctx)

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)

	skills, err := skill.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("skill.OpenSQLStore: %v", err)
	}
	defer skills.Close()
	skills.TruncateForTest(ctx)

	const reuse = 400 // ms
	row := func(id int64, group, reuseMs int) *refdata.Skill {
		return &refdata.Skill{ID: id, BasicLevel: 1, ReuseDelayMs: reuseMs, CooldownGroup: group, NoCombatParam: true, ZeroDamage: true}
	}
	ref := mapSkillRef{
		993: row(993, 2, reuse),
		992: row(992, 2, reuse),
		991: row(991, 3, reuse),
		990: row(990, 0, reuse),
		989: row(989, 2, 0),
	}
	for id := range ref {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatalf("Learn %d: %v", id, err)
		}
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 5, 500)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, ref, nil, mana.NewTracker(), nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
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

	cast := func(id int64) string {
		t.Helper()
		resp := send(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: id, TargetMonsterID: monster.ID}).Encode())
		ar, err := DecodeAttackResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeAttackResult: %v", err)
		}
		return ar.Error
	}
	expect := func(id int64, want, why string) {
		t.Helper()
		if got := cast(id); got != want {
			t.Errorf("cast %d (%s): error %q, want %q", id, why, got, want)
		}
	}

	expect(993, "", "group 2, nothing armed yet")
	// The negative case: 992 has never been cast, so its own timer is clear;
	// only the shared group can refuse it.
	expect(992, "skill on cooldown", "group 2 armed by 993")
	expect(991, "", "group 3 has its own timer")
	expect(990, "", "an ungrouped row keeps only its own timer")
	expect(989, "", "no ReuseDelay: IsReady never consults the group")
	// The engine agrees for an action-kind-0 row: its handler,
	// Skill_BuildUseContext_B, arms only when ReuseDelay != 0 (0x586c03). A
	// kind-1 or kind-3 row whose arm delay comes to 0 (no ReuseDelay, not
	// active with a duration) and that carries no 'cbuf' WOULD release the
	// group (FUN_0064c700 files a delay-0 entry over the group's pointer,
	// 0x64cc15-0x64cc25), but no real grouped row is one (round 507).
	expect(992, "skill on cooldown", "group 2 still armed; 989 did not clear or re-arm it")

	time.Sleep((reuse + 50) * time.Millisecond)
	expect(992, "", "group 2 has run out")
	// And the other way round: 993's own timer ran out with the group, but
	// 992's cast re-armed the group.
	expect(993, "skill on cooldown", "group 2 re-armed by 992")
}

// A CAST THAT SPENDS THE CASTER'S WHOLE POOL LEAVES HER ALIVE AT 0, AND THE
// NEXT BLOW KILLS HER (round 551). Aria, 200 HP, casts a skill whose
// Consume_HP is 200 at a Mangyang whose counter is inside its ReuseDelay
// (armed by hand through CounterattackReady), so the cast draws no reply: the
// engine's gate passes on HP == cost (`cmp eax,[esp+0x10]; jge` at
// 0x58e28c/0x58e290 in SR_GameServer.exe, combat.CanPaySkillHealth), the cast
// lands, its result carries PlayerHP 0 and no death, and she stands in life
// state 1. Then she swings at a second, ready Mangyang whose counter deals 15:
// with -player-dead-state off that counter is her death -- PlayerDied, PlayerHP
// the respawn -- and with it on, PlayerDied with PlayerHP 0 and life state 2.
// On round 550's tree the counter read (0, false) from the store and was
// dropped: no death, PlayerHP 0, and she went on swinging, immune.
func TestCounterOnACasterAliveAtZeroKills(t *testing.T) {
	for _, flag := range []bool{false, true} {
		t.Run(map[bool]string{true: "dead state on", false: "dead state off"}[flag], func(t *testing.T) {
			deadStateForTest(t, flag)
			ctx := context.Background()
			accounts := account.NewMemStore()
			accounts.Add("alice", "hunter2")
			chars := character.NewMemStore()
			c, err := chars.Create(ctx, 1, "Aria")
			if err != nil {
				t.Fatalf("creating character: %v", err)
			}
			defer keepUp.Cancel(c.ID)
			if c.MaxHP() != 200 {
				t.Fatalf("test premise: a new character's max HP is %d, want 200", c.MaxHP())
			}
			// The rows are the test's: a sword and a skill costing the whole pool.
			drain := &refdata.Skill{ID: 64, BasicLevel: 1, ReuseDelayMs: 60000, ConsumeHP: 200,
				AttackPercent: 100, AttackType: 5}
			ref := itemsAndSkills{
				items:  map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2, PhysAttackMax: 30, Range: 6}},
				skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60}, 64: drain},
			}
			eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
			inv := inventory.NewMemStore(ref)
			quests := quest.NewMemStore()
			skills := skill.NewMemStore()
			if err := skills.Learn(ctx, c.ID, drain.ID); err != nil {
				t.Fatalf("Learn: %v", err)
			}
			hub := world.NewHub()
			monsters := combat.NewHub()
			mp := mana.NewTracker()
			handle := gateway.Chain(
				LoginHandler(accounts),
				WorldHandler(chars, eq, hub),
				UseSkillHandler(chars, eq, ref, skills, hub, monsters, quests, inv, ref, nil, mp, nil),
				CombatHandler(chars, eq, ref, hub, monsters, quests, inv, skills, nil, mp, nil),
			)
			addr, cleanup := startTestServer(t, handle)
			defer cleanup()
			conn := dialTestServer(t, addr)
			defer conn.Close()
			r := bufio.NewReader(conn)
			write := func(opcode uint16, data []byte) {
				if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
					t.Fatalf("Write: %v", err)
				}
			}
			attackResult := func(what string) *AttackResult {
				t.Helper()
				for {
					conn.SetReadDeadline(time.Now().Add(3 * time.Second))
					p, err := proto.Read(r, nil, nil)
					if err != nil {
						t.Fatalf("waiting for %s: %v", what, err)
					}
					if p.Opcode != OpAttackResult {
						continue
					}
					ar, err := DecodeAttackResult(p.Data)
					if err != nil {
						t.Fatalf("DecodeAttackResult: %v", err)
					}
					return ar
				}
			}
			write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
			conn.SetReadDeadline(time.Now().Add(3 * time.Second))
			if p, err := proto.Read(r, nil, nil); err != nil {
				t.Fatalf("login: %v", err)
			} else if lr, err := DecodeLoginResult(p.Data); err != nil || !lr.OK {
				t.Fatalf("login failed: err=%v result=%+v", err, lr)
			}
			write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
			conn.SetReadDeadline(time.Now().Add(3 * time.Second))
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("enter world: %v", err)
			}
			ewr, err := DecodeEnterWorldResult(p.Data)
			if err != nil || !ewr.OK {
				t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
			}
			x, z := float64(ewr.X), float64(ewr.Z)

			// The cast's target: a Mangyang with its real 3000 ms ReuseDelay,
			// armed now, so the cast is not answered ("there is no reply").
			armed := monsters.SpawnSpecies("jangan", combat.Species{Name: "Mangyang", Level: 1, AttackReuseMs: 3000}, x, 0, z, 5000, 0, 15, 0)
			if !monsters.CounterattackReady(armed.ID, time.Now()) {
				t.Fatal("setup: a fresh monster's counter is not ready")
			}
			write(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: drain.ID, TargetMonsterID: armed.ID}).Encode())
			cast := attackResult("the cast's result")
			if cast.Error != "" || cast.MonsterDamage <= 0 {
				t.Fatalf("the cast costing the whole pool: %+v; want it to land (the gate passes on HP == cost)", cast)
			}
			if cast.PlayerDied || cast.PlayerHP != 0 || cast.PlayerDamageTaken != 0 {
				t.Fatalf("the cast's result %+v; want PlayerHP 0, no death and no counter", cast)
			}
			at0, _ := chars.GetByID(ctx, c.ID)
			if at0.HP != 0 {
				t.Fatalf("stored HP after the cast = %d, want 0", at0.HP)
			}
			if e, ok := hub.EntityByCharacterID(c.ID); !ok || e.Life != world.LifeAlive {
				t.Fatalf("life state after the cast = %d (in world %v), want 1: alive at 0", e.Life, ok)
			}

			// The next blow: a ready Mangyang's counter to her swing.
			killer := monsters.Spawn("jangan", "Mangyang", x, 0, z, 5000, 0, 15, 0)
			write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: killer.ID}).Encode())
			blow := attackResult("the swing's result")
			if blow.Error != "" {
				t.Fatalf("the swing at 0 HP: %+v; want it to go through (alive, life state 1)", blow)
			}
			if !blow.PlayerDied || blow.PlayerDamageTaken != 15 {
				t.Fatalf("the counter on a caster alive at 0: %+v; want PlayerDied with the 15-point blow (round 550 dropped it)", blow)
			}
			after, _ := chars.GetByID(ctx, c.ID)
			e, _ := hub.EntityByCharacterID(c.ID)
			if flag {
				if blow.PlayerHP != 0 || after.HP != 0 || e.Life != world.LifeDead {
					t.Errorf("flag on: PlayerHP %d, stored %d, life %d; want dead at 0", blow.PlayerHP, after.HP, e.Life)
				}
			} else {
				want := int(float64(after.MaxHP()) * character.RespawnFraction)
				if int(blow.PlayerHP) != want || after.HP != want || e.Life != world.LifeAlive {
					t.Errorf("flag off: PlayerHP %d, stored %d, life %d; want the respawn HP %d, alive", blow.PlayerHP, after.HP, e.Life, want)
				}
			}
		})
	}
}
