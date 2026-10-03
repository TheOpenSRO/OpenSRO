package guild

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// TestGuildMemberCapMatchesTheEngine pins the recovered table. The engine keys
// the cap on guild level and asserts the level is 1..5, so the table has exactly
// five entries; MaxMembers is a new guild's cap, the entry for FoundingLevel.
func TestGuildMemberCapMatchesTheEngine(t *testing.T) {
	want := [5]int{15, 20, 25, 35, 50}
	if MaxMembersByLevel != want {
		t.Errorf("MaxMembersByLevel = %v, want %v (the dwords at .rdata 0x00ade8dc)", MaxMembersByLevel, want)
	}
	if MaxMembers != MaxMembersByLevel[0] {
		t.Errorf("MaxMembers = %d, want the level-1 entry %d", MaxMembers, MaxMembersByLevel[0])
	}
	// The engine's assert allows only levels 1..5; MaxMembersFor clamps rather
	// than panicking, so a future caller cannot index out of the table.
	for _, tc := range []struct{ level, want int }{
		{0, 15}, {1, 15}, {3, 25}, {5, 50}, {9, 50}, {-2, 15},
	} {
		if got := MaxMembersFor(tc.level); got != tc.want {
			t.Errorf("MaxMembersFor(%d) = %d, want %d", tc.level, got, tc.want)
		}
	}
}

// TestJoinRefusesWhenFull walks a guild to MaxMembers and checks the refusal
// lands exactly at the cap, so the constant and the check cannot drift apart.
func TestJoinRefusesWhenFull(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()
	g, err := m.Create(ctx, "Ironsong", 1, "Leader")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	// The leader is already a member, so MaxMembers-1 more fit.
	for i := 2; i <= MaxMembers; i++ {
		if _, err := m.Join(ctx, g.ID, int64(i), "M"); err != nil {
			t.Fatalf("member %d of %d: %v", i, MaxMembers, err)
		}
	}
	if _, err := m.Join(ctx, g.ID, int64(MaxMembers+1), "OneTooMany"); !errors.Is(err, ErrGuildFull) {
		t.Errorf("member %d: got %v, want ErrGuildFull", MaxMembers+1, err)
	}
}

// TestPermissionMasksMatchTheEngine pins the bit positions read off the seven
// call sites of FUN_005d0f80, and the ALL-bits semantics of its comparison.
func TestPermissionMasksMatchTheEngine(t *testing.T) {
	for _, tc := range []struct {
		name string
		got  Permission
		want Permission
	}{
		{"invite is bit 0", PermInvite, 0x01},
		{"warehouse is bit 3", PermWarehouse, 0x08},
		{"notice is bit 4", PermNotice, 0x10},
	} {
		if tc.got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, tc.got, tc.want)
		}
	}

	// The engine's test is `(perms & required) == required`, so a member needs
	// EVERY requested bit -- not merely one of them. A non-zero check would pass
	// the third case below and let a warehouse-only member edit the notice.
	full := PermInvite | PermWarehouse | PermNotice
	if !full.Has(PermNotice) {
		t.Error("a member with every bit must pass a single-bit requirement")
	}
	if !full.Has(PermInvite | PermWarehouse) {
		t.Error("a member with every bit must pass a multi-bit requirement")
	}
	if PermWarehouse.Has(PermWarehouse | PermNotice) {
		t.Error("holding one bit of a two-bit requirement must NOT pass")
	}
	if Permission(0).Has(PermInvite) {
		t.Error("holding nothing must not pass")
	}
	// A requirement of zero is vacuously satisfied, which is what the engine's
	// equality does too.
	if !Permission(0).Has(0) {
		t.Error("an empty requirement is satisfied by anyone")
	}
}

// --- values recovered 2026-09-17 -------------------------------------

// `len - 2u < 0xb` accepts 2 through 12. The boundaries are what a restatement
// of the range gets wrong, and the minimum is the half OpenSRO did not have.
func TestValidNameMatchesTheUnsignedCheck(t *testing.T) {
	for n := MinNameLength; n <= MaxNameLength; n++ {
		if !ValidName(strings.Repeat("a", n)) {
			t.Errorf("a %d-character name was rejected", n)
		}
	}
	for _, n := range []int{0, 1, 13, 14, 32, 100} {
		if ValidName(strings.Repeat("a", n)) {
			t.Errorf("a %d-character name was accepted", n)
		}
	}
	// And against the instruction rather than the range.
	for n := 0; n <= 200; n++ {
		want := uint(n-MinNameLength) < uint(MaxNameLength-MinNameLength+1)
		if got := ValidName(strings.Repeat("a", n)); got != want {
			t.Fatalf("length %d: got %v want %v", n, got, want)
		}
	}
}

// MaxLevel and the capacity table were recovered from different functions and
// must agree; that agreement is the evidence for both.
func TestMaxLevelAgreesWithTheCapacityTable(t *testing.T) {
	if MaxLevel != len(MaxMembersByLevel) {
		t.Errorf("MaxLevel is %d but MaxMembersByLevel has %d entries; the level-up "+
			"cap and the capacity table came from different functions and agreeing "+
			"is what makes either trustworthy", MaxLevel, len(MaxMembersByLevel))
	}
	if MaxMembersFor(MaxLevel) != 50 {
		t.Errorf("a level-%d guild holds %d, want 50", MaxLevel, MaxMembersFor(MaxLevel))
	}
}

func TestLevelUpCost(t *testing.T) {
	for _, c := range []struct {
		from   int
		gold   int64
		points int
	}{
		{1, 3_000_000, 5_400},
		{2, 9_000_000, 50_400},
		{3, 15_000_000, 135_000},
		{4, 21_000_000, 378_000},
	} {
		gold, points, ok := LevelUpCost(c.from)
		if !ok {
			t.Errorf("level %d has no cost", c.from)
			continue
		}
		if gold != c.gold || points != c.points {
			t.Errorf("level %d costs %d gold / %d GP, want %d / %d",
				c.from, gold, points, c.gold, c.points)
		}
	}
	// The switch accepts 1..4 and nothing else. Level 5 is the cap, so it has
	// no cost -- which is a different statement from its cost being zero.
	for _, from := range []int{0, -1, MaxLevel, MaxLevel + 1, 99} {
		if _, _, ok := LevelUpCost(from); ok {
			t.Errorf("level %d reported a cost; the engine's switch rejects it", from)
		}
	}
}

// The gold costs rise by a constant six million. Recording the shape catches a
// transcription slip that a per-value check would not, because a wrong digit in
// one entry breaks the progression.
func TestLevelUpGoldIsAnArithmeticProgression(t *testing.T) {
	const step = 6_000_000
	for from := 2; from < MaxLevel; from++ {
		if d := LevelUpGold[from] - LevelUpGold[from-1]; d != step {
			t.Errorf("the step from level %d to %d is %d, want %d", from-1, from, d, step)
		}
	}
	// The guild-point costs do NOT form a clean progression, and that is the
	// point of saying so: they are a hand-tuned table, so nothing here should
	// try to derive them.
	if LevelUpGuildPoints[2]-LevelUpGuildPoints[1] == LevelUpGuildPoints[3]-LevelUpGuildPoints[2] {
		t.Error("the guild-point costs became a progression; they are a hand-tuned table")
	}
}

// Guild points are the skill points a member earns, batched: nine pending
// stays pending, the tenth flushes all of it, and a big grant flushes at once.
func TestGuildPointsAccumulateFromSkillPoints(t *testing.T) {
	var acc PointAccumulator
	for i := 0; i < 9; i++ {
		if got := acc.Add(1); got != 0 {
			t.Fatalf("point %d flushed %d; want nothing before ten", i+1, got)
		}
	}
	if acc.Pending() != 9 {
		t.Fatalf("pending %d; want 9", acc.Pending())
	}
	if got := acc.Add(1); got != 10 || acc.Pending() != 0 {
		t.Fatalf("the tenth point flushes 10 and clears: got %d, pending %d", got, acc.Pending())
	}
	if got := acc.Add(25); got != 25 {
		t.Fatalf("a grant past the threshold flushes at once: %d", got)
	}
	if got := acc.Add(0); got != 0 || acc.Pending() != 0 {
		t.Fatalf("nothing earned, nothing booked: %d / %d", got, acc.Pending())
	}
}

// TestCheckCreator pins FUN_00514b20's founder ladder: level 20 (`bVar3 < 0x14`
// -> 0x4c0a), 500,000 gold (64-bit, `< 500000` -> 0x4c0c), and the engine's
// order -- dead before level, level before gold.
func TestCheckCreator(t *testing.T) {
	if MinCreatorLevel != 20 {
		t.Errorf("MinCreatorLevel = %d, want 20 (FUN_00514b20: bVar3 < 0x14 -> 0x4c0a)", MinCreatorLevel)
	}
	if CreateGoldRequired != 500_000 {
		t.Errorf("CreateGoldRequired = %d, want 500000 (FUN_00514b20 -> 0x4c0c; FUN_004e4140 pushes 0xfff85ee0)", CreateGoldRequired)
	}
	for _, tc := range []struct {
		alive bool
		level int
		gold  int64
		want  error
	}{
		{true, 20, 500_000, nil},
		{true, 19, 500_000, ErrCreatorLevelTooLow},
		{true, 20, 499_999, ErrNotEnoughGold},
		{true, 99, 1 << 40, nil},
		{false, 1, 0, ErrCreatorDead},
		{false, 99, 1 << 40, ErrCreatorDead},
		{true, 19, 0, ErrCreatorLevelTooLow},
		{true, 20, -1, ErrNotEnoughGold},
	} {
		if got := CheckCreator(tc.alive, tc.level, tc.gold); !errors.Is(got, tc.want) {
			t.Errorf("CheckCreator(%v, %d, %d) = %v, want %v", tc.alive, tc.level, tc.gold, got, tc.want)
		}
	}
}

// TestCheckLevelUpLadder pins CGuild::HandleLevelUp's refusal order (0x005c63d0,
// srv.asm 0x5c63e3-0x5c644c) and CheckLevelUpCost's two deficits (0x005c6240):
// dead, no guild, not the master, level 5, gold, guild points. Each row makes
// every LATER rung fail too, so a ladder checked in any other order returns
// the wrong refusal.
func TestCheckLevelUpLadder(t *testing.T) {
	const rich = int64(1) << 40
	for _, tc := range []struct {
		name                   string
		alive, inGuild, master bool
		level                  int
		gold, gatheredSP       int64
		want                   error
		code                   int
	}{
		{"dead, and everything else wrong", false, false, false, MaxLevel, 0, 0, ErrLevelUpDead, 0x4c07},
		{"no guild, and everything after wrong", true, false, false, MaxLevel, 0, 0, ErrNotInGuild, 0x4c0d},
		{"not the master, at the cap, broke", true, true, false, MaxLevel, 0, 0, ErrNotGuildMaster, 0x4c1e},
		{"at the cap, broke", true, true, true, MaxLevel, 0, 0, ErrLevelUpFull, 0x4c21},
		{"one gold short and no points", true, true, true, 1, 2_999_999, 0, ErrLevelUpGoldDeficit, 0x4c31},
		{"gold enough, 5,399 points", true, true, true, 1, 3_000_000, 5_399, ErrLevelUpGPDeficit, 0x4c32},
		{"level 4, one point short", true, true, true, 4, rich, 377_999, ErrLevelUpGPDeficit, 0x4c32},
	} {
		_, _, err := CheckLevelUp(tc.alive, tc.inGuild, tc.master, tc.level, tc.gold, tc.gatheredSP)
		if !errors.Is(err, tc.want) {
			t.Errorf("%s: got %v, want %v", tc.name, err, tc.want)
		}
		if got := LevelUpCode(err); got != tc.code {
			t.Errorf("%s: LevelUpCode = 0x%x, want 0x%x", tc.name, got, tc.code)
		}
	}

	// Passing: the cost is the CURRENT level's (5c6445 pushes GetLevel()'s
	// byte), exactly what the check compared.
	for from := 1; from < MaxLevel; from++ {
		wantGold, wantGP, _ := LevelUpCost(from)
		gold, gp, err := CheckLevelUp(true, true, true, from, wantGold, int64(wantGP))
		if err != nil || gold != wantGold || gp != int64(wantGP) {
			t.Errorf("level %d with exactly the cost: got %d / %d, %v; want %d / %d",
				from, gold, gp, err, wantGold, wantGP)
		}
	}

	// A level below 1 is a damaged row: refused, and not an engine code.
	if _, _, err := CheckLevelUp(true, true, true, 0, rich, rich); err == nil || LevelUpCode(err) != 0 {
		t.Errorf("level 0: got %v (code 0x%x), want a non-engine error", err, LevelUpCode(err))
	}
	if LevelUpCode(nil) != 0 || LevelUpCode(errors.New("db down")) != 0 {
		t.Error("LevelUpCode gave an engine code to something that is not a level-up refusal")
	}
}
