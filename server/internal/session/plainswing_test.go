package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The base attack rows as the retail skilldata carries them (the `att` run
// type/percent/min/max and the `mc` hit count, measured on the RE box's
// skilldata; round 505). Only the damage columns matter here.
var (
	punchRow = &refdata.Skill{ReqLearnSP: 1, ID: 1, ReuseDelayMs: 1500, AttackPercent: 150, AttackType: 5}
	swordRow = &refdata.Skill{ReqLearnSP: 1, ID: 2, ReuseDelayMs: 1200, AttackPercent: 60, HitCount: 2, AttackType: 5}
	staffRow = &refdata.Skill{ReqLearnSP: 1, ID: 9944, ReuseDelayMs: 1666, AttackPercent: 180, HitCount: 1, AttackType: 10}
)

// TestPlainSwingIsTheBaseSkillsAtt: a plain swing is the weapon's base attack
// skill (PrepareAction 0x4ad030 writes DefaultAttackSkillID into the context),
// so its damage terms are that row's `att` share, `mc` hit count and mask.
func TestPlainSwingIsTheBaseSkillsAtt(t *testing.T) {
	ctx := context.Background()
	ref := itemsAndSkills{
		items: map[int64]*refdata.Item{
			100: {ID: 100, TypeID4: combat.WeaponCHSword, PhysAttackMax: 30},
			200: {ID: 200, TypeID4: combat.WeaponEUTStaff, MagAttackMax: 50},
		},
		skills: map[int64]*refdata.Skill{1: punchRow, 2: swordRow, 9944: staffRow},
	}
	sword := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	staff := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 200, Durability: 50}}}
	broken := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: durability.Broken}}}

	if got, want := plainSwingOf(ctx, 1, sword, ref), (plainSwing{flat: 0, percent: 60, hits: 2, atk: 5}); got != want {
		t.Errorf("sword swing = %+v; want %+v (SKILL_CH_SWORD_BASE_01: two hits of 60%%, physical)", got, want)
	}

	st := plainSwingOf(ctx, 1, staff, ref)
	if !st.atk.IsMagical() || st.atk.IsPhysical() || st.percent != 180 || st.hits != 1 {
		t.Errorf("staff swing = %+v; want magical, 180%%, one hit (SKILL_EU_STAFF_BASE_01)", st)
	}

	// A broken weapon swings bare-handed: SKILL_PUNCH_01's 150%.
	if got, want := plainSwingOf(ctx, 1, broken, ref), (plainSwing{percent: 150, hits: 1, atk: 5}); got != want {
		t.Errorf("broken sword swing = %+v; want %+v (SKILL_PUNCH_01)", got, want)
	}
	// So does an empty hand.
	if got := plainSwingOf(ctx, 1, fixedEquipment{}, ref); got.percent != 150 {
		t.Errorf("bare-handed swing = %+v; want SKILL_PUNCH_01's 150%%", got)
	}

	// No skill lookup at all (stubCombatItems): the plain blow OpenSRO dealt
	// before round 505.
	fallback := plainSwing{hits: 1, atk: combat.AttackPhysical}
	plain := stubCombatItems{100: {ID: 100, TypeID4: combat.WeaponCHSword, PhysAttackMax: 30}}
	if got := plainSwingOf(ctx, 1, sword, plain); got != fallback {
		t.Errorf("no skill data: %+v; want the fallback %+v", got, fallback)
	}

	// NEGATIVE: a base row with no `att` must NOT pick up skillDamageBonus's
	// disclosed per-level bonus (3 * DisclosedSkillDamagePerLevel here).
	noAtt := itemsAndSkills{items: ref.items, skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60, BasicLevel: 3}}}
	if got := plainSwingOf(ctx, 1, sword, noAtt); got.flat != 0 || got.percent != 0 || got.hits != 1 || got.atk != combat.AttackPhysical {
		t.Errorf("row with no att = %+v; want 0/0, one physical hit -- not %d flat", got, 3*DisclosedSkillDamagePerLevel)
	}

	// A floor-blow base row (the fortress weapons' att 5/0/0/0) is the
	// engine's floor of 1, not an unscaled swing.
	floor := itemsAndSkills{items: ref.items, skills: map[int64]*refdata.Skill{2: {ID: 2, FloorBlow: true, AttackType: 5}}}
	if got := plainSwingOf(ctx, 1, sword, floor); got.percent != combat.SkillPercentZero || got.flat != 0 {
		t.Errorf("floor-blow row = %+v; want percent SkillPercentZero and no flat", got)
	}

	// A flat range rides along as the cast path's does (DamageMin == Max so
	// the roll is fixed).
	flat := itemsAndSkills{items: ref.items, skills: map[int64]*refdata.Skill{2: {ID: 2, AttackPercent: 100, DamageMin: 7, DamageMax: 7, AttackType: 5}}}
	if got := plainSwingOf(ctx, 1, sword, flat); got.flat != 7 || got.percent != 100 {
		t.Errorf("row with a flat 7 = %+v; want flat 7 at 100%%", got)
	}
}

// plainSwingResults logs in, attacks the monster with one OpAttack and
// returns the first n attack results -- the click's swing and the keep-up's
// repeats.
func plainSwingResults(t *testing.T, ref itemsAndSkills, eq fixedEquipment, monsterHP, defence, n int) []*AttackResult {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	defer keepUp.Cancel(c.ID)

	inv := inventory.NewMemStore(ref)
	quests := quest.NewMemStore()
	skills := skill.NewMemStore()
	hub := world.NewHub()
	monsters := combat.NewHub()
	// Attack 0 still counterattacks: every swing the monster survives costs
	// the player 1 (PlayerDamageTaken 1, MitigateDamage's floor), and a
	// killing swing draws none. No assertion here reads the player's HP.
	monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, monsterHP, defence, 0, 0)

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
	var out []*AttackResult
	for len(out) < n {
		p := read()
		if p.Opcode != OpAttackResult {
			continue
		}
		ar, err := DecodeAttackResult(p.Data)
		if err != nil {
			t.Fatalf("DecodeAttackResult: %v", err)
		}
		if ar.Error != "" {
			t.Fatalf("swing %d failed: %+v", len(out)+1, ar)
		}
		out = append(out, ar)
	}
	return out
}

// TestPlainOpAttackDealsTheBaseSkillsShare: through the real stack, a sword's
// plain swing is SKILL_CH_SWORD_BASE_01 -- two hits of 60% of the mitigated
// blow. The weapon rolls 30 (TestMain pins the roll to its maximum), the
// monster's defence takes 10, and each hit is 60% of 20 = 12: 24 a swing,
// where the skill-less swing before round 505 dealt 20.
func TestPlainOpAttackDealsTheBaseSkillsShare(t *testing.T) {
	items := map[int64]*refdata.Item{100: {ID: 100, TypeID4: combat.WeaponCHSword, PhysAttackMax: 30, Range: 6}}
	sword := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}

	// A long re-use delay: only the click's own swing lands in the test.
	ref := itemsAndSkills{items: items, skills: map[int64]*refdata.Skill{
		2: {ID: 2, ReuseDelayMs: 60000, AttackPercent: 60, HitCount: 2, AttackType: 5},
	}}
	if got := plainSwingResults(t, ref, sword, 1000, 10, 1)[0]; got.MonsterDamage != 24 {
		t.Errorf("sword swing dealt %d; want 24 (2 hits x 60%% of 30-10)", got.MonsterDamage)
	}

	// The keep-up's repeats are the same swing: at a 60 ms re-use a 48 HP
	// monster dies to exactly two swings of 24.
	ref.skills = map[int64]*refdata.Skill{
		2: {ID: 2, ReuseDelayMs: 60, AttackPercent: 60, HitCount: 2, AttackType: 5},
	}
	res := plainSwingResults(t, ref, sword, 48, 10, 2)
	if res[0].MonsterDamage != 24 || res[0].MonsterRemainingHP != 24 || res[0].MonsterDied {
		t.Errorf("first swing: %+v; want 24 leaving 24", res[0])
	}
	if res[1].MonsterDamage != 24 || !res[1].MonsterDied {
		t.Errorf("the keep-up's repeat: %+v; want the same 24, killing", res[1])
	}

	// CONTROL: a base row with no `att` deals the plain 30 - 10 = 20, not
	// 20 plus a disclosed per-level bonus.
	ref.skills = map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 60000, BasicLevel: 3}}
	if got := plainSwingResults(t, ref, sword, 1000, 10, 1)[0]; got.MonsterDamage != 20 {
		t.Errorf("row with no att dealt %d; want the plain 20", got.MonsterDamage)
	}
}

// TestPlainStaffSwingReadsTheMagicalColumns: a staff's base attack is
// magical (SKILL_EU_STAFF_BASE_01, att type 10), so its plain swing reads the
// weapon's MAGICAL damage columns and scales by 180%. The weapon here carries
// both halves so the choice shows: the magical 50 - 10 = 40, at 180% = 72;
// the physical 30 would give 20 (the skill-less swing before round 505) or 36.
func TestPlainStaffSwingReadsTheMagicalColumns(t *testing.T) {
	items := map[int64]*refdata.Item{200: {ID: 200, TypeID4: combat.WeaponEUTStaff, PhysAttackMax: 30, MagAttackMax: 50, Range: 6}}
	staff := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 200, Durability: 50}}}
	ref := itemsAndSkills{items: items, skills: map[int64]*refdata.Skill{
		9944: {ID: 9944, ReuseDelayMs: 60000, AttackPercent: 180, HitCount: 1, AttackType: 10},
	}}
	if got := plainSwingResults(t, ref, staff, 1000, 10, 1)[0]; got.MonsterDamage != 72 {
		t.Errorf("staff swing dealt %d; want 72 (180%% of the magical 50-10)", got.MonsterDamage)
	}
}
