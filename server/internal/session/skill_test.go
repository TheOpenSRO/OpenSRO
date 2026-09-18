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
