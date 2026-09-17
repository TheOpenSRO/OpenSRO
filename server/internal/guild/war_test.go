package guild

import "testing"

// The cap is 50, and the reason this test carries the instructions is that the
// DECOMPILER says 49. Anyone re-deriving it from the Ghidra output will get the
// wrong number; the raw `cmp al,0x32 ; jb` is the authority.
func TestMaxHostileGuilds(t *testing.T) {
	if MaxHostileGuilds != 50 {
		t.Fatalf("MaxHostileGuilds is %d; the check is `cmp al,0x32 ; jb` at "+
			"0x005c6de0, i.e. proceed while count < 50. Ghidra renders it as "+
			"`0x31 < count`, which reads as 49 and is wrong.", MaxHostileGuilds)
	}
	// A guild holding one fewer than the cap may still declare; one holding
	// the cap may not. That boundary is the whole content of the constant.
	if got := CanDeclareWar(MaxHostileGuilds-1, 0, 2, false, false); got != 0 {
		t.Errorf("a guild with %d wars was refused (%#x); the bound is strict",
			MaxHostileGuilds-1, got)
	}
	if got := CanDeclareWar(MaxHostileGuilds, 0, 2, false, false); got != ErrWarMaxHostileGuild {
		t.Errorf("a guild with %d wars gave %#x, want %#x",
			MaxHostileGuilds, got, ErrWarMaxHostileGuild)
	}
}

// The two cap refusals are different codes and must not be swapped: the client
// names one for the declarer and one for the target, and that naming is the
// only thing distinguishing two identical comparisons.
func TestCanDeclareWarDistinguishesDeclarerFromTarget(t *testing.T) {
	if got := CanDeclareWar(MaxHostileGuilds, 0, 2, false, false); got != ErrWarMaxHostileGuild {
		t.Errorf("a full DECLARER gave %#x, want %#x", got, ErrWarMaxHostileGuild)
	}
	if got := CanDeclareWar(0, MaxHostileGuilds, 2, false, false); got != ErrWarTargetMaxHostileGuild {
		t.Errorf("a full TARGET gave %#x, want %#x", got, ErrWarTargetMaxHostileGuild)
	}
	if ErrWarMaxHostileGuild == ErrWarTargetMaxHostileGuild {
		t.Error("the two cap refusals collapsed to one code")
	}
	// The declarer is checked first, so a case where BOTH are full reports the
	// declarer's refusal.
	if got := CanDeclareWar(MaxHostileGuilds, MaxHostileGuilds, 2, false, false); got != ErrWarMaxHostileGuild {
		t.Errorf("both full gave %#x, want the declarer's %#x", got, ErrWarMaxHostileGuild)
	}
}

func TestCanDeclareWarLadder(t *testing.T) {
	for _, tc := range []struct {
		name            string
		mine, theirs    int
		target          int64
		atWar, sameAlly bool
		want            int
	}{
		{"no target", 0, 0, 0, false, false, ErrWarCantFindTargetGuild},
		{"declarer full", 50, 0, 2, false, false, ErrWarMaxHostileGuild},
		{"target full", 0, 50, 2, false, false, ErrWarTargetMaxHostileGuild},
		{"already at war", 0, 0, 2, true, false, ErrWarEnemyGuild},
		{"same alliance", 0, 0, 2, false, true, ErrWarAllyGuild},
		{"allowed", 0, 0, 2, false, false, 0},
		{"allowed at the boundary", 49, 49, 2, false, false, 0},
	} {
		if got := CanDeclareWar(tc.mine, tc.theirs, tc.target, tc.atWar, tc.sameAlly); got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, got, tc.want)
		}
	}
}

// An ally cannot be a war target, so the two systems are mutually exclusive on
// the same pair of guilds. Both are recovered now; a future implementation that
// lets a guild ally and declare war on the same target contradicts the engine.
func TestAllianceAndWarAreMutuallyExclusive(t *testing.T) {
	if got := CanDeclareWar(0, 0, 2, false, true); got != ErrWarAllyGuild {
		t.Errorf("declaring on an ally gave %#x, want %#x", got, ErrWarAllyGuild)
	}
	// And the alliance side refuses a guild that already belongs to one, which
	// is the nearest thing it has to the same exclusion.
	if got := CanRequestAlliance(1, 2, 5, 5, true); got != ErrAllianceTargetHasAlliance {
		t.Errorf("allying with an allied guild gave %#x, want %#x",
			got, ErrAllianceTargetHasAlliance)
	}
}

func TestWarCodesAreDistinctAndInTheGuildFamily(t *testing.T) {
	codes := map[string]int{
		"CantFindTargetGuild": ErrWarCantFindTargetGuild,
		"PermissionDenied":    ErrWarPermissionDenied,
		"EnemyGuild":          ErrWarEnemyGuild,
		"MaxHostileGuild":     ErrWarMaxHostileGuild,
		"TargetMaxHostile":    ErrWarTargetMaxHostileGuild,
		"AllyGuild":           ErrWarAllyGuild,
		"TooFar":              ErrWarTooFar,
		"InBattleArena":       ErrWarInBattleArena,
		"BreakWar":            ErrWarBreakWar,
	}
	seen := map[int]string{}
	for name, c := range codes {
		if prev, dup := seen[c]; dup {
			t.Errorf("%s and %s are both %#x", prev, name, c)
		}
		seen[c] = name
		if c>>8 != 0x4c {
			t.Errorf("%s is %#x, outside the guild family 0x4cxx", name, c)
		}
	}
	// The war codes must not collide with the alliance ones recovered
	// alongside them; both sets are read out of the same 0x4cxx family and a
	// transcription slip would show up here.
	for name, c := range map[string]int{
		"AllianceFull": ErrAllianceFull, "AlreadyAllied": ErrAllianceAlreadyAllied,
		"CreatorTooLow": ErrAllianceCreatorTooLow, "JoinerTooLow": ErrAllianceJoinerTooLow,
	} {
		if prev, dup := seen[c]; dup && prev != name {
			t.Errorf("alliance code %s (%#x) collides with war code %s", name, c, prev)
		}
	}
}
