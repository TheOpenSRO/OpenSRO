package session

import (
	"bytes"
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
)

// Round 880: a monster skill whose 'mc' count is 2 lands two blows a swing,
// each resolved on its own, and the push lists them (MonsterAttacked.Hits).
// MEASURED: a level-104 monster's 76 % skill with a count of 2 landed
// `442 ; 463`, `685 ; 558`, and under a decay `1815 ; 1815`, one swing each,
// where its 152 % skills (count 1) landed one number. Synthetic ids.

func TestMonsterSwingLandsEveryBlowOfItsCount(t *testing.T) {
	f := startBattleFixture(t, 44, 0, 0)
	sp := testWaterGhost
	sp.Skills = []combat.MonsterSkill{
		{ID: 880168, ReuseMs: 2000, Range: 16, AttMin: 47, AttMax: 54, Chance: 100, Hits: 2},
		{ID: 880169, ReuseMs: 2000, Range: 16, AttMin: 47, AttMax: 54, Chance: 100},
	}
	m := f.monsters.SpawnSpecies("jangan", sp, 20, 0, 0, 1000, 0, 15, 0)
	cur, _ := f.monsters.Get(m.ID)
	ctx := context.Background()

	out, err := monsterStrike(ctx, f.a.deps, cur, cur.Skills[0], f.aria, 1)
	if err != nil {
		t.Fatal(err)
	}
	hits := out.hits.List()
	if len(hits) != 2 {
		t.Fatalf("a swing of a count-2 skill listed %d blows, want 2 (%+v)", len(hits), out)
	}
	// The starting character's naked defence is 3: each blow of 47-54 lands
	// at least 44, and the swing's damage is their sum.
	sum := 0
	for i, h := range hits {
		if h.Damage < 44 || h.Blocked {
			t.Errorf("blow %d = %+v, want at least 44 landed", i, h)
		}
		sum += int(h.Damage)
	}
	if out.damage != sum || out.damage < 88 {
		t.Errorf("the swing's damage %d, want the two blows' sum %d (at least 88)", out.damage, sum)
	}
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != character.StartingMaxHP-sum {
		t.Errorf("HP after the swing %d, want %d - %d", c.HP, character.StartingMaxHP, sum)
	}
	// The push carries both blows after the skill id, and decodes back.
	msg := out.message(cur.ID, f.aria)
	msg.SkillID = 880168
	back, err := DecodeMonsterAttacked(msg.Encode())
	if err != nil || *back != *msg {
		t.Fatalf("round trip: %+v, %v; want %+v", back, err, msg)
	}
	if got := len(msg.Encode()); got != MonsterAttackedSkillOffset+4+1+2*5 {
		t.Errorf("a two-blow push is %d bytes, want %d", got, MonsterAttackedSkillOffset+4+1+2*5)
	}

	// CONTROL: a count of 1 (or none) lists nothing, and its push is byte for
	// byte what it was before the list existed.
	f.chars.ResetHP(ctx, f.aria)
	one, err := monsterStrike(ctx, f.a.deps, cur, cur.Skills[1], f.aria, 1)
	if err != nil || one.hits.N != 0 || one.damage < 44 {
		t.Fatalf("a swing of a count-1 skill = %+v (err %v), want one blow of at least 44 and no list", one, err)
	}
	plain := one.message(cur.ID, f.aria)
	plain.SkillID = 880169
	want := append(append((&MonsterAttacked{MonsterID: plain.MonsterID, TargetCharacterID: plain.TargetCharacterID,
		Damage: plain.Damage, Critical: plain.Critical, TargetHP: plain.TargetHP}).Encode(), make([]byte, wallInfoSize)...),
		0x29, 0x6e, 0x0d, 0x00) // 880169 as a u32
	if got := plain.Encode(); !bytes.Equal(got, want) {
		t.Errorf("a one-blow push changed: % x, want % x", got, want)
	}
}
