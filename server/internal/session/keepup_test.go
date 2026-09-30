package session

import (
	"bufio"
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The tracker repeats until the swing says the fight is over, then forgets
// the run.
func TestAutoAttackRepeatsUntilTheSwingEnds(t *testing.T) {
	a := newAutoAttack()
	var calls int32
	done := make(chan struct{})
	a.Arm(1, 7, time.Millisecond, func() (time.Duration, bool) {
		n := atomic.AddInt32(&calls, 1)
		if n == 3 {
			close(done)
			return 0, false
		}
		return time.Millisecond, true
	})
	if tgt, ok := a.Target(1); !ok || tgt != 7 {
		t.Fatalf("Target = %d,%v; want 7,true while the run lives", tgt, ok)
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the run never reached its third swing")
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, ok := a.Target(1); !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a finished run is still registered")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if n := atomic.LoadInt32(&calls); n != 3 {
		t.Fatalf("swing ran %d times; want exactly 3", n)
	}
}

// A new Arm replaces the old run -- the actor holds one front action -- and
// Cancel ends whatever is running.
func TestAutoAttackArmReplacesAndCancelStops(t *testing.T) {
	a := newAutoAttack()
	var first, second int32
	a.Arm(1, 7, time.Millisecond, func() (time.Duration, bool) {
		atomic.AddInt32(&first, 1)
		return time.Millisecond, true
	})
	time.Sleep(60 * time.Millisecond)
	a.Arm(1, 8, time.Millisecond, func() (time.Duration, bool) {
		atomic.AddInt32(&second, 1)
		return time.Millisecond, true
	})
	time.Sleep(60 * time.Millisecond)
	firstAfterReplace := atomic.LoadInt32(&first)
	time.Sleep(60 * time.Millisecond)
	if got := atomic.LoadInt32(&first); got != firstAfterReplace {
		t.Fatalf("the replaced run kept swinging: %d -> %d", firstAfterReplace, got)
	}
	if atomic.LoadInt32(&second) == 0 {
		t.Fatal("the replacement never swung")
	}
	if tgt, _ := a.Target(1); tgt != 8 {
		t.Fatalf("Target = %d; want the replacement's 8", tgt)
	}
	a.Cancel(1)
	time.Sleep(60 * time.Millisecond)
	secondAfterCancel := atomic.LoadInt32(&second)
	time.Sleep(60 * time.Millisecond)
	if got := atomic.LoadInt32(&second); got != secondAfterCancel {
		t.Fatalf("a cancelled run kept swinging: %d -> %d", secondAfterCancel, got)
	}
	if _, ok := a.Target(1); ok {
		t.Fatal("a cancelled run is still registered")
	}
}

// A repeat is fired from where the two bodies stand: phase 1's reach test.
// A sword (Range 6) against a Mangyang (BCRadius 6): reach = 4 + 6 + 6 = 16,
// and the +2 slack lands the blow up to 18 units out, not 19.
func TestKeepUpReachIsTheApproachBand(t *testing.T) {
	m := combat.Monster{BCRadius: 6, X: 0, Z: 0}
	me := func(x float64) world.Position { return world.Position{X: x} }
	if !keepUpInReach(me(18.9), m, 6) {
		t.Error("18.9 units with a sword: in reach (int 18 <= 16 + 2)")
	}
	if keepUpInReach(me(19), m, 6) {
		t.Error("19 units with a sword: out of reach")
	}
	// Bare-handed the range term is zero: 4 + 6 + 0, +2 -> 12.
	if !keepUpInReach(me(12), m, 0) || keepUpInReach(me(13), m, 0) {
		t.Error("bare hand: 12 in, 13 out")
	}
	// A bow (Range 180) reaches from 192.
	if !keepUpInReach(me(192), m, 180) || keepUpInReach(me(193), m, 180) {
		t.Error("bow: 192 in, 193 out")
	}
}

// The hand-off is AutoAttackType exactly 1 on a row whose Basic_ChainCode is
// 0, after PreparingTime + CastingTime + ActionDuration: Tick_UseSkill (0x4ae590)
// phase 3 waits +0x78 + +0x74, and PostLoadSkillTable (0x5893e0) has already
// folded +0x70 (PreparingTime) into +0x74 -- refdata keeps both raw.
func TestSkillHandOffRule(t *testing.T) {
	smash := &refdata.Skill{ID: 3, AutoAttackType: 1, CastingTimeMs: 411, ActionDurationMs: 1022}
	bolt := &refdata.Skill{ID: 9944, AutoAttackType: 0, CastingTimeMs: 500, ActionDurationMs: 732}
	if !skillHandsOff(smash) || skillHandsOff(bolt) || skillHandsOff(nil) {
		t.Fatal("only AutoAttackType 1 hands off")
	}
	if got := handOffDelay(smash); got != 1433*time.Millisecond {
		t.Fatalf("handOffDelay = %v; want 1433 ms", got)
	}

	// PreparingTime counts: a synthetic row with 300 ms of it waits 1700 ms,
	// not the 1400 ms CastingTime + ActionDuration alone would give.
	prepared := &refdata.Skill{ID: 1, AutoAttackType: 1, PreparingTimeMs: 300, CastingTimeMs: 400, ActionDurationMs: 1000}
	if got := handOffDelay(prepared); got != 1700*time.Millisecond {
		t.Errorf("handOffDelay with PreparingTime 300 = %v; want 1700 ms (the engine's +0x74 includes +0x70)", got)
	}

	// A row with a non-zero Basic_ChainCode does not hand off: the engine
	// would play its links first and test the LAST link's byte, which
	// srrevamp does not model.
	chained := &refdata.Skill{ID: 2, AutoAttackType: 1, BasicChainCode: 12, CastingTimeMs: 411, ActionDurationMs: 834}
	if skillHandsOff(chained) {
		t.Error("a row with BasicChainCode 12 handed off; the engine plays the chain link by link first")
	}

	// AutoAttackType 2 is not 1: the engine's test is `== '\x01'`.
	typeTwo := &refdata.Skill{ID: 4, AutoAttackType: 2, CastingTimeMs: 411, ActionDurationMs: 1022}
	if skillHandsOff(typeTwo) {
		t.Error("AutoAttackType 2 handed off; only 1 does")
	}
}

// One click is the whole fight, through the real stack: a sword whose base
// attack re-uses every 60 ms (the row is the test's, the mechanism is the
// game's) kills a three-hit monster after a single OpAttack -- the second
// and third results arrive with no further request -- and a move stops the
// run before it can start on the next monster.
func TestOneClickKeepsAttackingUntilTheMonsterDies(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	ref := itemsAndSkills{
		items: map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2, PhysAttackMax: 30, Range: 6}},
		// SKILL_CH_SWORD_BASE_01 is id 2; the delay is shortened for the test.
		skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60}},
	}
	eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	inv := inventory.NewMemStore(ref)
	quests := quest.NewMemStore()
	skills := skill.NewMemStore()
	hub := world.NewHub()
	monsters := combat.NewHub()
	// 30 - 10 = 20 a hit; 60 HP is three hits. Attack 0 still counterattacks
	// for 1 (MitigateDamage's floor) after each swing the monster survives;
	// nothing here asserts on the player's HP.
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 60, 10, 0, 0)
	spare := monsters.Spawn("jangan", "Mangyang", 3, 0, 0, 60, 10, 0, 0)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, ref, hub, monsters, quests, inv, skills, nil, nil, nil),
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
	read := func() *proto.Packet {
		conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return p
	}
	// readAttackResult skips whatever else rides behind a swing (a level-up,
	// a kill notice) and returns the next result.
	readAttackResult := func() *AttackResult {
		for {
			p := read()
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
	if lr, err := DecodeLoginResult(read().Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(read().Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	var results []*AttackResult
	for len(results) < 3 {
		ar := readAttackResult()
		if ar.Error != "" {
			t.Fatalf("swing %d failed: %+v", len(results)+1, ar)
		}
		results = append(results, ar)
	}
	for i, ar := range results {
		if ar.MonsterDamage != 20 || ar.MonsterRemainingHP != int32(60-20*(i+1)) {
			t.Fatalf("swing %d: got %+v; want 20 damage leaving %d", i+1, ar, 60-20*(i+1))
		}
	}
	if !results[2].MonsterDied {
		t.Fatalf("the third swing should have killed: %+v", results[2])
	}
	if _, ok := monsters.Get(monster.ID); ok {
		t.Fatal("the monster is still there after three swings")
	}
	// The run ended with the kill.
	deadline := time.Now().Add(time.Second)
	for {
		if _, ok := keepUp.Target(c.ID); !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the keep-up outlived its target")
		}
		time.Sleep(5 * time.Millisecond)
	}

	// Click the spare (once the base attack's 60 ms have passed -- a click
	// inside the delay is dropped, round 255), then walk: the move cancels
	// the run before its first repeat, so only the click's own result arrives.
	time.Sleep(80 * time.Millisecond)
	write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: spare.ID}).Encode())
	if ar := readAttackResult(); ar.Error != "" || ar.MonsterRemainingHP != 40 {
		t.Fatalf("spare's first hit: %+v", ar)
	}
	write(OpMove, (&MoveRequest{X: 1, Y: 0, Z: 0}).Encode())
	time.Sleep(250 * time.Millisecond)
	if m, ok := monsters.Get(spare.ID); !ok || m.HP != 40 {
		t.Fatalf("the spare took repeats after the move: HP %d (ok=%v), want 40", m.HP, ok)
	}
	if _, ok := keepUp.Target(c.ID); ok {
		t.Fatal("a move should have cancelled the keep-up")
	}
}

// A click from out of reach does not land a hit. The repeats always tested
// this; the first swing did not, so one click killed things across the map
// (playtest 2026-09-20, item 2). Walking into reach makes the same click work.
func TestFirstSwingIsGatedByReach(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	_ = c

	ref := itemsAndSkills{
		items:  map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2, PhysAttackMax: 30, Range: 6}},
		skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60}},
	}
	eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	inv := inventory.NewMemStore(ref)
	quests := quest.NewMemStore()
	skills := skill.NewMemStore()
	hub := world.NewHub()
	monsters := combat.NewHub()
	// Far enough that no weapon reaches: the sword's band is 4 + 6 + 6 (+2).
	const farX = 400.0
	monster := monsters.Spawn("jangan", "Mangyang", farX, 0, 0, 200, 0, 0, 0)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, ref, hub, monsters, quests, inv, skills, nil, nil, nil),
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
	read := func() *proto.Packet {
		conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return p
	}

	write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(read().Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(read().Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	ar, err := DecodeAttackResult(read().Data)
	if err != nil || ar.Error != "too far away" {
		t.Fatalf("swing from %g units: %+v (err %v), want a refusal", farX, ar, err)
	}
	if m, _ := monsters.Get(monster.ID); m.HP != 200 {
		t.Fatalf("the monster took %d damage from out of reach", 200-m.HP)
	}

	// Walk up and the same click lands.
	write(OpMove, (&MoveRequest{X: farX - 2, Y: 0, Z: 0}).Encode())
	time.Sleep(50 * time.Millisecond)
	write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
	for {
		p := read()
		if p.Opcode != OpAttackResult {
			continue
		}
		ar, err = DecodeAttackResult(p.Data)
		if err != nil || ar.Error != "" || ar.MonsterDamage <= 0 {
			t.Fatalf("swing in reach: %+v (err %v), want a hit", ar, err)
		}
		break
	}
}

// The post-cast hand-off through the real cast handler (round 502 made it
// live; until now only TestSkillHandOffRule's direct calls covered it). One
// OpUseSkill of a type-1, non-chain, damaging row leaves plain swings running
// at the same target with no further request, the first of them no sooner
// than PreparingTime + CastingTime + ActionDuration after the cast: the wait
// Tick_UseSkill (0x4ae590) phase 3 takes from +0x74 + +0x78, with +0x70
// folded into +0x74 at load (SkillGlobal::PostLoadSkillTable 0x5893e0).
//
// And the two refusals that sit in front of it: a row with a non-zero
// Basic_ChainCode (srrevamp does not play the links, keepup.go's package
// comment) and a ZeroDamage row (useSkillHandler's no-blow early return comes
// before the hand-off) must leave nothing running.
func TestSkillCastHandsOffToPlainSwings(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	defer keepUp.Cancel(c.ID)

	// The cast rows are the test's, the rule is the engine's. Each damaging
	// row carries att 100% (AttackType 5), so a cast hit is the same 30 - 10
	// = 20 a plain swing of the no-`att` base row deals.
	handsOff := &refdata.Skill{ID: 50, BasicLevel: 1, AutoAttackType: 1, ReuseDelayMs: 60000,
		PreparingTimeMs: 100, CastingTimeMs: 100, ActionDurationMs: 100, AttackPercent: 100, AttackType: 5}
	chained := &refdata.Skill{ID: 51, BasicLevel: 1, AutoAttackType: 1, BasicChainCode: 52, ReuseDelayMs: 60000,
		CastingTimeMs: 50, ActionDurationMs: 50, AttackPercent: 100, AttackType: 5}
	zeroDamage := &refdata.Skill{ID: 53, BasicLevel: 1, AutoAttackType: 1, ReuseDelayMs: 60000,
		CastingTimeMs: 50, ActionDurationMs: 50, ZeroDamage: true}
	ref := itemsAndSkills{
		items: map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2, PhysAttackMax: 30, Range: 6}},
		// SKILL_CH_SWORD_BASE_01 is id 2; the delay is shortened for the test.
		skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60}, 50: handsOff, 51: chained, 53: zeroDamage},
	}
	eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	inv := inventory.NewMemStore(ref)
	quests := quest.NewMemStore()
	skills := skill.NewMemStore()
	for _, id := range []int64{50, 51, 53} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatalf("Learn %d: %v", id, err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	// One monster per case, so a stray swing shows on the monster it hit.
	chainedTarget := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1000, 10, 0, 0)
	zeroTarget := monsters.Spawn("jangan", "Mangyang", 1, 0, 0, 1000, 10, 0, 0)
	target := monsters.Spawn("jangan", "Mangyang", 2, 0, 0, 60, 10, 0, 0)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, ref, skills, hub, monsters, quests, inv, ref, nil, nil, nil),
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
	read := func(what string) *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for %s: %v", what, err)
		}
		return p
	}
	// resultFor returns the next attack result about monster id, skipping
	// anything else on the wire.
	resultFor := func(id int64, what string) *AttackResult {
		t.Helper()
		for {
			p := read(what)
			if p.Opcode != OpAttackResult {
				continue
			}
			ar, err := DecodeAttackResult(p.Data)
			if err != nil {
				t.Fatalf("DecodeAttackResult: %v", err)
			}
			if ar.MonsterID == id {
				return ar
			}
		}
	}
	cast := func(skillID, monsterID int64) *AttackResult {
		t.Helper()
		write(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: skillID, TargetMonsterID: monsterID}).Encode())
		ar := resultFor(monsterID, fmt.Sprintf("the result of casting %d", skillID))
		if ar.Error != "" {
			t.Fatalf("cast %d: %+v", skillID, ar)
		}
		return ar
	}
	// noHandOff waits out the row's hand-off delay plus five base-attack
	// periods and checks nothing swung at the monster after the cast.
	noHandOff := func(why string, row *refdata.Skill, monsterID int64, hpAfterCast int) {
		t.Helper()
		time.Sleep(handOffDelay(row) + 5*60*time.Millisecond)
		if m, ok := monsters.Get(monsterID); !ok || m.HP != hpAfterCast {
			t.Errorf("%s: the monster went from %d to %d HP (ok=%v) after the cast; want no swings", why, hpAfterCast, m.HP, ok)
		}
		if tgt, ok := keepUp.Target(c.ID); ok {
			t.Errorf("%s: a keep-up is running against %d; want none", why, tgt)
		}
	}

	write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(read("the login result").Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(read("the enter-world result").Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	// REFUSAL 1: a row with a non-zero Basic_ChainCode resolves its own blow
	// and does not hand off.
	if ar := cast(51, chainedTarget.ID); ar.MonsterDamage != 20 || ar.MonsterRemainingHP != 980 {
		t.Fatalf("BasicChainCode 52 cast: %+v; want 20 damage leaving 980", ar)
	}
	noHandOff("a row with BasicChainCode 52", chained, chainedTarget.ID, 980)

	// REFUSAL 2: a ZeroDamage row resolves no blow and does not hand off.
	if ar := cast(53, zeroTarget.ID); ar.MonsterDamage != 0 {
		t.Fatalf("zero-damage cast: %+v; want no damage", ar)
	} else if ar.MonsterRemainingHP != 1000 {
		// Round 655's review: the no-blow reply carries the monster's health
		// as it is, not the zero value, which the client applies to its bar.
		t.Errorf("zero-damage cast reports MonsterRemainingHP %d; want the monster's unchanged 1000", ar.MonsterRemainingHP)
	}
	noHandOff("a ZeroDamage row", zeroDamage, zeroTarget.ID, 1000)

	// THE HAND-OFF: the cast hits once, then plain swings follow on their own.
	sent := time.Now()
	if ar := cast(50, target.ID); ar.MonsterDamage != 20 || ar.MonsterRemainingHP != 40 {
		t.Fatalf("hand-off cast: %+v; want 20 damage leaving 40", ar)
	}
	first := resultFor(target.ID, "a plain swing after the type-1 cast (no hand-off?)")
	// 100 + 100 + 100: PreparingTime counts, so a wait of CastingTime +
	// ActionDuration alone (200 ms, round 256's sum) would fail here.
	if waited, want := time.Since(sent), 300*time.Millisecond; waited < want {
		t.Errorf("the first plain swing came %v after the cast; want at least PreparingTime + CastingTime + ActionDuration = %v", waited, want)
	}
	if first.Error != "" || first.MonsterDamage != 20 || first.MonsterRemainingHP != 20 {
		t.Fatalf("first handed-off swing: %+v; want 20 damage leaving 20", first)
	}
	second := resultFor(target.ID, "the second handed-off swing")
	if second.Error != "" || second.MonsterDamage != 20 || !second.MonsterDied {
		t.Fatalf("second handed-off swing: %+v; want 20 damage, killing", second)
	}
	// The run ended with the kill, as the plain keep-up's does.
	deadline := time.Now().Add(time.Second)
	for {
		if _, ok := keepUp.Target(c.ID); !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the handed-off keep-up outlived its target")
		}
		time.Sleep(5 * time.Millisecond)
	}
}
