package session

import (
	"bufio"
	"context"
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

// The hand-off is AutoAttackType 1, after CastingTime + ActionDuration.
func TestSkillHandOffRule(t *testing.T) {
	smash := &refdata.Skill{ID: 3, AutoAttackType: 1, CastingTimeMs: 411, ActionDurationMs: 1022}
	bolt := &refdata.Skill{ID: 9944, AutoAttackType: 0, CastingTimeMs: 500, ActionDurationMs: 732}
	if !skillHandsOff(smash) || skillHandsOff(bolt) || skillHandsOff(nil) {
		t.Fatal("only AutoAttackType 1 hands off")
	}
	if got := handOffDelay(smash); got != 1433*time.Millisecond {
		t.Fatalf("handOffDelay = %v; want 1433 ms", got)
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
	// 30 - 10 = 20 a hit; 60 HP is three hits. No counterattack (attack 0)
	// so the player's HP stays out of the picture.
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
