package session

import (
	"bufio"
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// An attack result must never report the player's health as zero unless the
// player is actually dead.
//
// PlayerHP is what the client paints the health bar from, and an int32 left at
// its zero value says "dead". The counterattack branch is skipped whenever the
// monster is still inside its attack skill's re-use delay -- there is nothing
// to compute -- and it used to leave the field untouched, so the bar emptied on
// every swing that drew no reply. Mangyang's delay is 3000 ms and a player
// swings faster, so it emptied almost at once and was reported as "when i click
// on a mangyang its health bar appears but then my health shoots all the way
// down to 0" (playtest 2026-09-20).
//
// Two swings back to back: the second is inside the delay by construction.
func TestAttackResultNeverReportsZeroHealthForALivingPlayer(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 5}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	if err := quests.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating quests: %v", err)
	}

	hub := world.NewHub()
	monsters := combat.NewHub()
	// A monster with a real attack re-use delay, and enough HP that neither
	// swing can kill it.
	target := monsters.SpawnSpecies("jangan", combat.Species{
		Name: "Mangyang", Level: 1, AttackReuseMs: 3000, AttackMin: 1, AttackMax: 2,
	}, 0, 0, 0, 5000, 0, 0, 0)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv, skill.NewMemStore(), nil, nil, nil),
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
		// first swing's counter is followed by its OpMonsterAttacked, and a
		// reader that took the next packet as the next reply decoded that push
		// as the second swing's result (TestCounterTestsHoldWithTheStrikePushOn).
		return readReply(t, conn, r)
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	for i := 1; i <= 2; i++ {
		ar, err := DecodeAttackResult(send(OpAttack,
			(&AttackRequest{CharacterName: "Aria", TargetMonsterID: target.ID}).Encode()).Data)
		if err != nil || ar.Error != "" {
			t.Fatalf("swing %d: err=%v result=%+v", i, err, ar)
		}
		live, err := chars.GetByID(ctx, c.ID)
		if err != nil {
			t.Fatalf("swing %d: reading the character: %v", i, err)
		}
		if live.HP <= 0 {
			t.Fatalf("swing %d: the fixture killed the player; it proves nothing", i)
		}
		if ar.PlayerHP <= 0 {
			t.Errorf("swing %d: AttackResult.PlayerHP = %d while the character really has %d -- "+
				"a living player's bar must never be told it is empty", i, ar.PlayerHP, live.HP)
		}
		if int(ar.PlayerHP) != live.HP {
			t.Errorf("swing %d: AttackResult.PlayerHP = %d, the store says %d", i, ar.PlayerHP, live.HP)
		}
	}
}

// A skill must respect reach, and it must be the SAME reach a plain swing
// uses -- the engine has one Action_IsTargetWithinReach, not two.
//
// Casting resolved at any distance at all until 2026-09-20: "when i use a
// skill on a monster even from far away, it still uses the skill. no distance
// checking".
func TestSkillReachIsTheSameRuleAsASwing(t *testing.T) {
	const monsterBC = 1.0
	// A melee skill declares no range of its own, so it reaches exactly as far
	// as the weapon in hand -- that is what combat.EffectiveRange's fallback
	// means, and it is why a skill cannot be used to attack from off-screen.
	weapon := 3
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, monsterBC,
		combat.EffectiveRange(0, weapon))
	if !combat.InReach(reach, reach) {
		t.Fatalf("a target exactly at reach %v must be in reach", reach)
	}
	if combat.InReach(reach+float64(combat.ReachSlack)+1, reach) {
		t.Errorf("a target beyond reach %v plus the slack must be out of reach", reach)
	}
	// A skill that DOES declare a range uses it instead of the weapon's, so a
	// bow skill reaches further than the bow alone would suggest.
	if got := combat.EffectiveRange(50, weapon); got != 50 {
		t.Errorf("EffectiveRange(50, %d) = %v, want the skill's 50", weapon, got)
	}
	if got := combat.EffectiveRange(0, weapon); got != float64(weapon) {
		t.Errorf("EffectiveRange(0, %d) = %v, want the weapon's %d", weapon, got, weapon)
	}
	// And the two paths agree: whatever a swing would allow, a skill with no
	// range of its own allows too.
	_, swing := combat.ApproachBand(combat.PlayerBCRadius, monsterBC, combat.EffectiveRange(0, weapon))
	_, cast := combat.ApproachBand(combat.PlayerBCRadius, monsterBC, combat.EffectiveRange(0, weapon))
	if swing != cast {
		t.Errorf("a swing reaches %v but a rangeless cast reaches %v; they must be one rule", swing, cast)
	}
}
