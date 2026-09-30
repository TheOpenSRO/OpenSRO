package ai

// The unique AI-skill selectors' summon choice (round 661), READ from
// SR_GameServer.exe: AI::CAISkill_Unique_Summon_A::PickSkill (0x5621b0) and
// AI::CAISkill_Unique_Summon_B::PickSkill (0x562570), which run before the
// Basic pick (PickSkill 0x561b00: the triggers, then the weighted draw).
// docs/protocol/monster_ai.md, "The unique rotation and the minions".

// HPBucket is AITactics_HPBucket (0x541d70): the owner's CurHP over MaxHP as
// a float32 (1.0 when MaxHP <= 0), mapped by FUN_00541fd0 against the doubles
// 0.2/0.4/0.6/0.8 (0xb45be8/0xb45be0/0xb45bd8/0xb45bd0):
//
//	< 0.2 -> 0 ; < 0.4 -> 1 ; < 0.6 -> 2 ; < 0.8 -> 3 ; else 4
func HPBucket(curHP, maxHP int) int {
	f := float32(1.0)
	if maxHP > 0 {
		f = float32(curHP) / float32(maxHP)
	}
	v := float64(f)
	switch {
	case v < 0.2:
		return 0
	case v < 0.4:
		return 1
	case v < 0.6:
		return 2
	case v < 0.8:
		return 3
	}
	return 4
}

// SummonDuePercent is the float at 0xb45b44, 10.0: a summon is picked only
// once the damage the monster has taken since its last summon is this
// percent of its MaxHP or more.
const SummonDuePercent = 10.0

// SummonDue is both selectors' gate (0x562214..0x562257 in A, 0x5625c5..
// 0x562608 in B): the context's damage total (+0xb0, which
// AITactics_CreditAttacker adds each blow's damage to) over MaxHP (slot 68,
// at least 1) times 100.0, as a float32, at least SummonDuePercent. The
// total is zeroed when a summon skill is used (slot 6, FUN_00562540: `ctx+0xb0
// = 0` when the armed skill has an 'ssou' block), so a unique summons once per
// tenth of its MaxHP it loses -- not once per HP bucket. READ.
func SummonDue(damageTaken int64, maxHP int) bool {
	m := maxHP
	if m < 2 {
		m = 1
	}
	// fild, fild, fdivp, fmul 100.0 on the x87 stack, then fstp to a float.
	pct := float32(float64(uint32(damageTaken)) / float64(uint32(m)) * 100.0)
	return pct >= SummonDuePercent
}

// SummonAIndex is Summon_A's slot for an HP bucket (the jump table at
// 0x562310: buckets 0,1 -> 3, 2 -> 2, 3 -> 1, 4 -> 0): above 80 % HP the
// chance-80 skill, 60-80 % the chance-60 one, 40-60 % the chance-40 one,
// below 40 % slot 3. An empty slot falls through to the Basic pick. READ.
func SummonAIndex(bucket int) int {
	switch bucket {
	case 4:
		return 0
	case 3:
		return 1
	case 2:
		return 2
	}
	return 3
}

// SummonBIndex is Summon_B's index into its summon list (the skills with an
// 'ssou' block in registration order, RegisterSkill 0x562470) for an HP
// bucket and one rand(): the set offset is 0 when rand() % 1000 < 500, else 4
// (0x56261f..0x56263a), and the jump table at 0x5626b4 gives
//
//	bucket 4 -> 3 ; 3 -> off ; 2 -> off + 1 ; 0, 1 -> off + 2
//
// -- the "R1"/"R2" pairs of the uniques' skill names. The die is thrown
// before the bucket is read, whatever the bucket. READ.
func SummonBIndex(bucket, r int) int {
	off := 4
	if r%1000 < 500 {
		off = 0
	}
	switch bucket {
	case 4:
		return 3
	case 3:
		return off
	case 2:
		return off + 1
	}
	return off + 2
}
