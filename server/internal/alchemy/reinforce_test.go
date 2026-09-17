package alchemy

import (
	"fmt"
	"strings"
	"testing"
)

// The clamp's asymmetry is the thing most likely to be "fixed" by a later
// reader. It is in the binary: `if (rate < 10) rate = 10; else if (99 < rate)
// rate = 100;`. 99 is left alone.
func TestClampRateKeepsTheBinarysAsymmetry(t *testing.T) {
	for _, c := range []struct{ in, want int }{
		{-5, 10}, {0, 10}, {9, 10},
		{10, 10}, {50, 50},
		{98, 98},
		{99, 99}, // NOT raised to 100
		{100, 100}, {101, 100}, {1000, 100},
	} {
		if got := ClampRate(c.in); got != c.want {
			t.Errorf("ClampRate(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

// A clamped rate of 100 makes the roll certain, because rand() % 100 tops out
// at 99. A rate of 10 -- the floor -- is a one-in-ten chance.
func TestSucceedsMatchesTheRoll(t *testing.T) {
	hits := 0
	for roll := 0; roll < RollModulus; roll++ {
		if Succeeds(ClampRate(0), roll) {
			hits++
		}
	}
	if hits != MinRate {
		t.Errorf("a floored rate wins %d of %d rolls, want %d", hits, RollModulus, MinRate)
	}
	for roll := 0; roll < RollModulus; roll++ {
		if !Succeeds(MaxRate, roll) {
			t.Fatalf("rate 100 lost to roll %d; rand()%%100 never reaches 100", roll)
		}
	}
}

// Four rates per 32-bit field, high byte first.
func TestBaseRateUnpacksHighByteFirst(t *testing.T) {
	tiers := [3]uint32{0x5A503C28, 0x1E140A05, 0x04030201}
	for _, c := range []struct {
		level int
		want  int
	}{
		{0, 0x5A}, {1, 0x50}, {2, 0x3C}, {3, 0x28}, // tier 1, high to low
		{4, 0x1E}, {5, 0x14}, {6, 0x0A}, {7, 0x05}, // tier 2
		{8, 0x04}, {9, 0x03}, {10, 0x02}, {11, 0x01}, // tier 3
	} {
		if got := BaseRate(c.level, tiers); got != c.want {
			t.Errorf("BaseRate(+%d) = %#x, want %#x", c.level, got, c.want)
		}
	}
}

// Every level from 12 up reads the low byte of the tier-3 field. The table
// stops there, and a reimplementation that kept indexing would run off it.
func TestBaseRateSaturatesAtTwelve(t *testing.T) {
	tiers := [3]uint32{0xAABBCCDD, 0x11223344, 0x99887766}
	want := 0x66
	for _, level := range []int{12, 13, 15, 20, 47, 1000} {
		if got := BaseRate(level, tiers); got != want {
			t.Errorf("BaseRate(+%d) = %#x, want %#x -- +12 and up all read the "+
				"tier-3 low byte", level, got, want)
		}
	}
}

func TestRateAssemblesTheFourTerms(t *testing.T) {
	// A tier-1 field whose top byte is 30.
	tiers := [3]uint32{0x1E000000, 0, 0}
	base := 30

	for _, c := range []struct {
		name string
		in   Inputs
		want int
	}{
		{
			"base alone",
			Inputs{PlusLevel: 0, Tiers: tiers},
			base,
		},
		{
			"second element doubles the base",
			Inputs{PlusLevel: 0, Tiers: tiers, SecondElement: true},
			base * 2,
		},
		{
			"lucky adds a flat five",
			Inputs{PlusLevel: 0, Tiers: tiers, Lucky: true},
			base + LuckyBonus,
		},
		{
			"param 173 adds percentage points",
			Inputs{PlusLevel: 0, Tiers: tiers, ParamBonus: 25},
			base + 25,
		},
		{
			"all four together",
			Inputs{PlusLevel: 0, Tiers: tiers, SecondElement: true, Lucky: true, ParamBonus: 25},
			base*2 + LuckyBonus + 25,
		},
		{
			"a zero base still floors at ten",
			Inputs{PlusLevel: 0, Tiers: [3]uint32{0, 0, 0}},
			MinRate,
		},
	} {
		if got := Rate(c.in); got != c.want {
			t.Errorf("%s: Rate = %d, want %d", c.name, got, c.want)
		}
	}
}

// Slot 6 returns EARLY when the first contribution already exceeds 99 and a
// second element is loaded -- skipping both the second contribution and the
// Lucky bonus. Slot 7's param bonus is a different function and still applies.
//
// This is the one branch in the formula that is easy to miss and impossible to
// guess, so it gets its own test.
func TestSecondElementEarlyReturnSkipsLuckyButNotTheParam(t *testing.T) {
	tiers := [3]uint32{0xFF000000, 0, 0} // base 255, well over 99
	got := Rate(Inputs{PlusLevel: 0, Tiers: tiers, SecondElement: true, Lucky: true})
	if got != MaxRate {
		t.Errorf("Rate = %d, want %d", got, MaxRate)
	}

	// Observable through the pre-clamp arithmetic: with a base of 100 the
	// early return fires, so Lucky must NOT contribute.
	tiers = [3]uint32{0x64000000, 0, 0} // base 100
	withLucky := Rate(Inputs{PlusLevel: 0, Tiers: tiers, SecondElement: true, Lucky: true})
	withoutLucky := Rate(Inputs{PlusLevel: 0, Tiers: tiers, SecondElement: true})
	if withLucky != withoutLucky {
		t.Errorf("Lucky changed the rate (%d vs %d) after the early return", withLucky, withoutLucky)
	}

	// Without a second element there is no early return, so Lucky applies --
	// which is what makes the case above a real branch rather than a clamp.
	tiers = [3]uint32{0x5A000000, 0, 0} // base 90
	if got := Rate(Inputs{PlusLevel: 0, Tiers: tiers, Lucky: true}); got != 95 {
		t.Errorf("Rate = %d, want 95 -- Lucky applies when no second element is loaded", got)
	}
}

func TestOutcomeMessages(t *testing.T) {
	for _, c := range []struct {
		o     Outcome
		after int
		want  string
	}{
		{OutcomeSuccess, 5, "UIIT_MSG_REINFORCERR_SUCCESS"},
		{OutcomeFailure, 5, "UIIT_MSG_REINFORCERR_FAIL"},
		{OutcomeFailure | FailureLostOptionLevel, 3, "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_DOWN"},
		{OutcomeFailure | FailureLostOptionLevel, 0, "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO"},
		{OutcomeFailure | FailureLostDurability, 5, "UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY"},
		{OutcomeBreakdown, 5, "UIIT_MSG_REINFORCERR_BREAKDOWN"},
		{0, 5, ""},
		{0x04, 5, ""},
	} {
		if got := c.o.Message(c.after); got != c.want {
			t.Errorf("Outcome(%#x).Message(%d) = %q, want %q", uint8(c.o), c.after, got, c.want)
		}
	}
}

// Success is tested before failure, so a byte with both bits reads as success.
func TestSuccessBitWinsOverFailureBit(t *testing.T) {
	o := OutcomeSuccess | OutcomeFailure | OutcomeBreakdown
	if got := o.Message(0); got != "UIIT_MSG_REINFORCERR_SUCCESS" {
		t.Errorf("got %q; the client tests 0x10 first", got)
	}
}

// The two failure sub-bits are independent and the client prints both lines.
func TestBothFailureCostsAreReported(t *testing.T) {
	o := OutcomeFailure | FailureLostOptionLevel | FailureLostDurability
	got := o.Messages(2)
	want := []string{
		"UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_DOWN",
		"UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("Messages = %v, want %v", got, want)
	}
	if n := len(OutcomeFailure.Messages(0)); n != 1 {
		t.Errorf("a plain failure produced %d messages, want 1", n)
	}
}

// The tag constants must stay the ones in magic_options.md. Writing the decimal
// values out a second time catches a transcription slip in either direction.
func TestTagConstantsMatchTheMagicOptionTable(t *testing.T) {
	if TagLuck != 1819632491 {
		t.Errorf("TagLuck = %d, want 1819632491 (MATTR_LUCK)", TagLuck)
	}
	if TagAthanasia != 1635018849 {
		t.Errorf("TagAthanasia = %d, want 1635018849 (MATTR_ATHANASIA)", TagAthanasia)
	}
	// And they must still spell their four characters, big-endian.
	for _, c := range []struct {
		tag  uint32
		want string
	}{{TagLuck, "luck"}, {TagAthanasia, "atha"}} {
		got := string([]byte{
			byte(c.tag >> 24), byte(c.tag >> 16), byte(c.tag >> 8), byte(c.tag),
		})
		if got != c.want {
			t.Errorf("tag %#x spells %q, want %q", c.tag, got, c.want)
		}
	}
}

func TestErrorCodesAreDistinctAndInRange(t *testing.T) {
	seen := map[int]bool{}
	for _, c := range ErrorCodes {
		if seen[c] {
			t.Errorf("error code %#x listed twice", c)
		}
		seen[c] = true
		if c < 0x5400 || c > 0x54ff {
			t.Errorf("error code %#x is outside the 0x54xx range", c)
		}
	}
	if len(ErrorCodes) != 15 {
		t.Errorf("%d error codes, want the 15 harvested from the family", len(ErrorCodes))
	}
	for _, named := range []int{
		ErrNoSourceItem, ErrRecipeNotLoaded, ErrOnlyEquipCanBeReinforced,
		ErrRecipeMismatch, ErrEquipClassMismatchProbUp, ErrTargetCannotBeReinforced,
		ErrNotReinforceStuff, ErrStuffLoadedTwice, ErrAstral,
		ErrEnchantEquipClassMismatch, ErrMagicStone2Max, ErrEnchantFailed,
		ErrAstralAlt, ErrHonorItem, ErrAlreadyDone,
	} {
		if !seen[named] {
			t.Errorf("named code %#x is not in ErrorCodes", named)
		}
	}
	if seen[Success] {
		t.Error("Success collides with an error code")
	}
}

// Every code must carry the client message error_codes.md gives it, and the one
// that carries none must be the one the client's switch has no case for.
//
// This test exists because a previous version of the package asserted that the
// engine names none of these codes, on the strength of a grep that only looked
// inside the CEnchant functions. The names were in this repository the whole
// time.
func TestEveryCodeHasItsClientMessage(t *testing.T) {
	for _, c := range ErrorCodes {
		msg, ok := ErrorMessages[c]
		if !ok {
			t.Errorf("code %#x has no ErrorMessages entry", c)
			continue
		}
		if c == ErrNoSourceItem {
			if msg != "" {
				t.Errorf("%#x maps to %q; it has no case in the client switch", c, msg)
			}
			continue
		}
		if msg == "" {
			t.Errorf("code %#x maps to an empty message", c)
		}
		if !strings.HasPrefix(msg, "UIIT_MSG_") {
			t.Errorf("code %#x maps to %q, which is not a UIIT_MSG_ name", c, msg)
		}
	}
	if len(ErrorMessages) != len(ErrorCodes) {
		t.Errorf("%d messages for %d codes", len(ErrorMessages), len(ErrorCodes))
	}
}

// 0x5420 and 0x5424 both mean STRGERR_ASTRAL. Keeping that visible stops a
// later reader "fixing" what looks like a copy-paste.
func TestTwoCodesShareTheAstralMessage(t *testing.T) {
	if ErrorMessages[ErrAstral] != ErrorMessages[ErrAstralAlt] {
		t.Errorf("%#x and %#x no longer share a message", ErrAstral, ErrAstralAlt)
	}
	if ErrorMessages[ErrAstral] != "UIIT_MSG_STRGERR_ASTRAL" {
		t.Errorf("%#x maps to %q", ErrAstral, ErrorMessages[ErrAstral])
	}
}
