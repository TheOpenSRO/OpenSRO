package session

import (
	"bufio"
	"context"
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

// A cast refused as too far away costs nothing (round 534). The engine never
// pays for one: Tick_UseSkill (0x4ae590) walks while Action_IsTargetWithinReach
// (0x4aea39) fails and posts the 0x7070 command only in reach (0x4aebc6);
// neither it nor the 0x7074 handler calls EngageSkill (the costs, slot 0x308)
// or the reuse-timer arm FUN_0064c700. srrevamp refuses instead of walking, and
// until round 534 it refused after spending the HP and MP and recording the
// use -- so the client's retry after its walk was refused on cooldown.
//
// NEGATIVE: with session/skill.go at round 533 the far cast drains the MP,
// arms the per-id and group cooldowns, and the in-reach retry is refused "skill
// on cooldown".
//
// The gate's own order is kept: a cast short of mana is refused for its mana
// wherever it stands (mask bit 0x10 is in both gates the tick runs before the
// reach test, 0x4ae6af and 0x4aea11), which the handler did before too.
func TestSkillRefusedAsTooFarCostsNothing(t *testing.T) {
	// The group map is process-wide, and the in-reach cast at the end arms
	// group 250 for a minute; MemStore hands the character ID 1 again on the
	// next run, so without this a second run in the same process (-count=2)
	// was refused "skill on cooldown" instead of "too far away" (round 534's
	// review). Start from an empty tracker, keep the two names pointing at the
	// one tracker as in production, and put the process's back afterwards --
	// as TestSkillCooldownGroupIsShared (skill_test.go) does.
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
	defer keepUp.Cancel(c.ID)

	// The rows are the test's; the order is the engine's. Group 250 is used by
	// no real skill or item table (itemcooldown.go lists both), so no other
	// test's arm can stand in for this one's.
	const group = 250
	strike := &refdata.Skill{ID: 60, BasicLevel: 1, ReuseDelayMs: 60000, CooldownGroup: group,
		ConsumeMP: 5, AttackPercent: 100, AttackType: 5}
	bleed := &refdata.Skill{ID: 61, BasicLevel: 1, ReuseDelayMs: 60000, ConsumeHP: 7,
		AttackPercent: 100, AttackType: 5}
	greedy := &refdata.Skill{ID: 62, BasicLevel: 1, ReuseDelayMs: 60000, ConsumeMP: 1 << 30,
		AttackPercent: 100, AttackType: 5}
	ref := itemsAndSkills{
		items:  map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2, PhysAttackMax: 30, Range: 6}},
		skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60}, 60: strike, 61: bleed, 62: greedy},
	}
	eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	inv := inventory.NewMemStore(ref)
	quests := quest.NewMemStore()
	skills := skill.NewMemStore()
	for _, id := range []int64{60, 61, 62} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatalf("Learn %d: %v", id, err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	// Far enough that no cast reaches: the sword's band is 4 + 0 + 6 (+2).
	const farX = 400.0
	monster := monsters.Spawn("jangan", "Mangyang", farX, 0, 0, 1000, 0, 0, 0)
	mp := mana.NewTracker()
	owned, err := chars.GetByID(ctx, c.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	maxMP := owned.MaxMP()
	if maxMP < strike.ConsumeMP {
		t.Fatalf("probe: a fresh character's max MP %d cannot pay the fixture's %d", maxMP, strike.ConsumeMP)
	}

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, ref, skills, hub, monsters, quests, inv, ref, nil, mp, nil),
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
	cast := func(skillID int64) *AttackResult {
		t.Helper()
		write(OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: skillID, TargetMonsterID: monster.ID}).Encode())
		for {
			p := read("the cast's result")
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
	if lr, err := DecodeLoginResult(read("the login result").Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(read("the enter-world result").Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}
	hpBefore, _, err := chars.ApplyDamage(ctx, c.ID, 0)
	if err != nil {
		t.Fatalf("reading HP: %v", err)
	}

	// From out of reach: refused, and nothing is paid or armed.
	if ar := cast(60); ar.Error != "too far away" {
		t.Fatalf("cast from %g units: %+v; want \"too far away\"", farX, ar)
	}
	if got := mp.Current(c.ID, maxMP); got != maxMP {
		t.Errorf("MP after a cast refused as too far away = %d, want the full %d", got, maxMP)
	}
	if _, ever, err := skills.LastUsed(ctx, c.ID, 60); err != nil || ever {
		t.Errorf("a cast refused as too far away was recorded as a use (ever=%v, err=%v)", ever, err)
	}
	if !skillGroupCooldowns.Ready(c.ID, group, time.Now()) {
		t.Errorf("a cast refused as too far away armed its cooldown group %d", group)
	}
	if ar := cast(61); ar.Error != "too far away" {
		t.Fatalf("health-cost cast from %g units: %+v; want \"too far away\"", farX, ar)
	}
	if hp, _, _ := chars.ApplyDamage(ctx, c.ID, 0); hp != hpBefore {
		t.Errorf("HP after a health-cost cast refused as too far away = %d, want %d", hp, hpBefore)
	}
	if m, _ := monsters.Get(monster.ID); m.HP != 1000 {
		t.Fatalf("the monster took %d damage from out of reach", 1000-m.HP)
	}
	// Short of mana AND out of reach: the mana row comes first, as before.
	if ar := cast(62); ar.Error != "not enough mana" {
		t.Errorf("an unaffordable cast from out of reach: %+v; want \"not enough mana\"", ar)
	}

	// Walk up and the same cast lands, paying once.
	write(OpMove, (&MoveRequest{X: farX - 2, Y: 0, Z: 0}).Encode())
	time.Sleep(50 * time.Millisecond)
	ar := cast(60)
	if ar.Error != "" || ar.MonsterDamage <= 0 {
		t.Fatalf("the cast in reach after a refusal: %+v; want a hit (a refused cast must not have armed the cooldown)", ar)
	}
	if got, want := mp.Current(c.ID, maxMP), maxMP-strike.ConsumeMP; got != want {
		t.Errorf("MP after one refusal and one hit = %d, want %d (the cost paid once)", got, want)
	}
	if skillGroupCooldowns.Ready(c.ID, group, time.Now()) {
		t.Errorf("the cast that landed did not arm its cooldown group %d", group)
	}
}
