package guild

import "testing"

// The cap is the point of this file. It was an unverified project note for a
// long time and is now read four ways; if it ever changes, it must change
// because someone re-read the binary, not because a test was loosened.
func TestMaxAllianceGuilds(t *testing.T) {
	if MaxAllianceGuilds != 8 {
		t.Fatalf("MaxAllianceGuilds is %d; the member array at alliance+0x1c is "+
			"walked with `while (i < 8)` and guarded by `7 < index` asserts in "+
			"both the setter and the clearer", MaxAllianceGuilds)
	}
	// The engine's bound is spelled as `7 < index`, so the last legal index is
	// MaxAllianceGuilds-1. Pin the relationship rather than the literal, since
	// that is the shape a future reader has to preserve.
	lastLegalIndex := MaxAllianceGuilds - 1
	if lastLegalIndex != 7 {
		t.Errorf("last legal slot index is %d, want 7", lastLegalIndex)
	}
}

func TestMinLevelForAlliance(t *testing.T) {
	if MinLevelForAlliance != 2 {
		t.Fatalf("MinLevelForAlliance is %d, want 2", MinLevelForAlliance)
	}
	// It must be reachable: a guild starts at level 1 and MaxLevel is 5, so a
	// minimum of 2 means one level-up buys the ability to ally. A minimum above
	// MaxLevel would make alliances impossible and is the failure this catches.
	if MinLevelForAlliance > MaxLevel {
		t.Errorf("MinLevelForAlliance %d exceeds MaxLevel %d, so no guild could ever ally",
			MinLevelForAlliance, MaxLevel)
	}
}

// The two level refusals are DIFFERENT codes, and which is which is the part
// most likely to be swapped by someone tidying the function. The client names
// them creator and joiner; the engine checks the requester first.
func TestCanRequestAllianceDistinguishesCreatorFromJoiner(t *testing.T) {
	if got := CanRequestAlliance(1, 2, 1, 5, false); got != ErrAllianceCreatorTooLow {
		t.Errorf("a low REQUESTER gave %#x, want %#x (CREATOR)", got, ErrAllianceCreatorTooLow)
	}
	if got := CanRequestAlliance(1, 2, 5, 1, false); got != ErrAllianceJoinerTooLow {
		t.Errorf("a low TARGET gave %#x, want %#x (JOINER)", got, ErrAllianceJoinerTooLow)
	}
	if ErrAllianceCreatorTooLow == ErrAllianceJoinerTooLow {
		t.Error("the two level refusals collapsed to one code")
	}
}

func TestCanRequestAllianceLadder(t *testing.T) {
	for _, tc := range []struct {
		name               string
		req, tgt           int64
		reqLevel, tgtLevel int
		targetAllied       bool
		want               int
	}{
		{"no guild", 0, 2, 5, 5, false, ErrAllianceNoGuild},
		{"requester too low", 1, 2, 1, 5, false, ErrAllianceCreatorTooLow},
		{"no target guild", 1, 0, 5, 5, false, ErrAllianceCantFindTargetGuild},
		{"own guild", 1, 1, 5, 5, false, ErrAllianceCantAllyToOwnGuild},
		{"target too low", 1, 2, 5, 1, false, ErrAllianceJoinerTooLow},
		{"target already allied", 1, 2, 5, 5, true, ErrAllianceTargetHasAlliance},
		{"allowed", 1, 2, 2, 2, false, 0},
		{"allowed at exactly the minimum", 1, 2, MinLevelForAlliance, MinLevelForAlliance, false, 0},
	} {
		if got := CanRequestAlliance(tc.req, tc.tgt, tc.reqLevel, tc.tgtLevel, tc.targetAllied); got != tc.want {
			t.Errorf("%s: got %#x, want %#x", tc.name, got, tc.want)
		}
	}
}

// Ordering matters: a validator returning the right set of refusals in the
// wrong order shows the player the wrong message. The engine checks the
// requester's own level BEFORE it looks at the target at all, so a level-1
// guild asking to ally with itself hears "you are too low", not "you cannot
// ally with your own guild".
func TestCanRequestAllianceChecksRequesterBeforeTarget(t *testing.T) {
	if got := CanRequestAlliance(1, 1, 1, 1, false); got != ErrAllianceCreatorTooLow {
		t.Errorf("got %#x, want %#x -- the requester's level is checked first",
			got, ErrAllianceCreatorTooLow)
	}
}

// Every code in the vocabulary is distinct, including the two the server never
// raises. Those two are carried deliberately (see alliance.go); a duplicate
// would mean a transcription slip from the error table.
func TestAllianceCodesAreDistinct(t *testing.T) {
	codes := map[string]int{
		"ImDead": ErrAllianceImDead, "NoGuild": ErrAllianceNoGuild,
		"PermissionDenied":    ErrAlliancePermissionDenied,
		"TargetMasterAbsent":  ErrAllianceTargetMasterAbsent,
		"CantFindTargetGuild": ErrAllianceCantFindTargetGuild,
		"CantAllyToOwnGuild":  ErrAllianceCantAllyToOwnGuild,
		"AlreadyAllied":       ErrAllianceAlreadyAllied,
		"TargetHasAlliance":   ErrAllianceTargetHasAlliance,
		"Full":                ErrAllianceFull,
		"CreatorTooLow":       ErrAllianceCreatorTooLow,
		"JoinerTooLow":        ErrAllianceJoinerTooLow,
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
}
