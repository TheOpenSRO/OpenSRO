// Package alchemy holds the reinforce success model recovered from
// SR_GameServer.exe.
//
// Every number here came out of the binary. The formula is assembled from four
// functions on CEnchant_Reinforce's vtable, and the two magic-option tags it
// tests are the same constants docs/protocol/magic_options.md recovered
// separately, which is the cross-check that makes the reading safe.
//
// See docs/protocol/alchemy.md.
package alchemy

// The tags the reinforce path tests, as the four-byte constants that appear in
// the code. Both are already in this project's magic-option vocabulary,
// recovered by a different route; the numbers agreeing is the point.
const (
	// TagLuck is 'luck' -- MATTR_LUCK. An item carrying it gets
	// LuckyBonus added to its reinforce rate.
	TagLuck uint32 = 0x6c75636b
	// TagAthanasia is 'atha' -- MATTR_ATHANASIA, tested as a precondition by
	// CEnchant_Reinforce's slot 5 when one context flag is set.
	TagAthanasia uint32 = 0x61746861
)

// The constants of the success roll, all literals in the binary.
const (
	// LuckyBonus is added once, as flat percentage points, when the item
	// carries TagLuck and the rate is still below 100
	// (CEnchant_Reinforce::vslot_006, 0x00506020).
	LuckyBonus = 5

	// MinRate is the floor. CEnchant_Reinforce::vslot_001 raises anything
	// below it, so no attempt is ever less than a one-in-ten chance.
	MinRate = 10

	// MaxRate is the ceiling, and it is applied with a STRICTLY GREATER
	// comparison against CeilingTest, not against MaxRate. See ClampRate.
	MaxRate = 100

	// CeilingTest is the literal the binary compares against: `else if (99 <
	// rate) rate = 100`. A rate of exactly 99 is therefore left alone, and
	// this constant exists so that reading ClampRate makes that obvious
	// rather than looking like an off-by-one.
	CeilingTest = 99

	// RollModulus is the divisor in `rand() % 100 < rate`.
	RollModulus = 100

	// SuccessBonusParam is ParamKeeper id 173 (0xad), added to the rate as
	// percentage points after truncation toward zero by the CRT's __ftol2.
	// Its registry row is min 0, max 100, default 0.
	SuccessBonusParam = 173
)

// ClampRate applies the clamp CEnchant_Reinforce::vslot_001 applies, in its
// order and with its comparisons:
//
//	if (rate < 10)      rate = 10;
//	else if (99 < rate) rate = 100;
//
// The asymmetry is deliberate and is in the binary: 99 is not raised, and the
// two arms are exclusive, so a rate below the floor can never also be tested
// against the ceiling.
func ClampRate(rate int) int {
	if rate < MinRate {
		return MinRate
	} else if rate > CeilingTest {
		return MaxRate
	}
	return rate
}

// BaseRate returns the packed success byte for a plus level, given the three
// 32-bit fields the item's _RefObjItem record carries for tiers 1, 2 and 3.
//
// FUN_00505f00:
//
//	tier   = clamp(n/4 + 1, 1, 3)
//	within = (n < 12) ? n % 4 : 3
//	return (tiers[tier-1] >> ((3 - within) * 8)) & 0xff
//
// Four rates are packed per field, high byte first, so plus 0 reads the top
// byte of the tier-1 field. Every level from 12 upward reads the LOW byte of
// the tier-3 field -- the table does not extend past there.
//
// Negative levels cannot occur in the engine, but the division is signed there,
// so this mirrors it rather than assuming: a negative n clamps to tier 1 and
// takes within = n % 4, which Go computes with the same truncated-toward-zero
// sign rule C uses.
func BaseRate(plusLevel int, tiers [3]uint32) int {
	tier := plusLevel/4 + 1
	if tier < 1 {
		tier = 1
	} else if tier > 3 {
		tier = 3
	}
	within := 3
	if plusLevel < 12 {
		within = plusLevel % 4
		if within < 0 {
			within = -within
		}
	}
	shift := uint((3 - within) * 8)
	return int((tiers[tier-1] >> shift) & 0xff)
}

// Inputs are everything the four vtable slots read, gathered in one place.
type Inputs struct {
	// PlusLevel is the item's current reinforcement level.
	PlusLevel int
	// Tiers are the three packed rate fields from the item's ref record.
	Tiers [3]uint32
	// SecondElement reports whether the operation's second element slot
	// (context +0x226a) is filled. When it is, the base rate is added twice.
	SecondElement bool
	// Lucky reports whether the item carries TagLuck.
	Lucky bool
	// ParamBonus is GetParam(173), already truncated toward zero.
	ParamBonus int
}

// Rate assembles the four terms in the order the vtable does, and returns the
// clamped percentage the roll is made against.
//
// Slot 6 (0x00506020):
//
//	rate = base()
//	if (secondElement) { if (rate > 99) return rate; rate += base(); }
//	if (rate < 100 && lucky) rate += 5;
//
// Slot 7 (0x00506df0):
//
//	rate = slot6() + (int)GetParam(173)
//
// Slot 1 (0x00506090) then clamps. The early return inside the second-element
// branch matters: when the first contribution already exceeds 99, slot 6
// returns IMMEDIATELY, so neither the second contribution nor the Lucky bonus
// is applied -- but the param bonus in slot 7 still is, because that is a
// different function.
func Rate(in Inputs) int {
	base := BaseRate(in.PlusLevel, in.Tiers)
	rate := base
	early := false
	if in.SecondElement {
		if rate > CeilingTest {
			early = true
		} else {
			rate += base
		}
	}
	if !early {
		if rate < MaxRate && in.Lucky {
			rate += LuckyBonus
		}
	}
	rate += in.ParamBonus
	return ClampRate(rate)
}

// Succeeds performs the roll exactly as CEnchant_Reinforce::vslot_001 does:
// `rand() % 100 < rate`, where roll is that modulus result in [0, 100).
//
// Taking the roll as an argument rather than drawing it keeps this testable and
// keeps the randomness where the caller can seed it.
func Succeeds(rate, roll int) bool { return roll < rate }

// Outcome is the flag byte the server sends and UI_REINFORCERR::FUN_00592650
// in the client decodes.
type Outcome uint8

const (
	// OutcomeSuccess is bit 0x10, tested first.
	OutcomeSuccess Outcome = 0x10
	// OutcomeFailure is bit 0x20, tested second. Its low nibble carries what
	// else the failure cost.
	OutcomeFailure Outcome = 0x20
	// OutcomeBreakdown is bit 0x40, tested last: the item is destroyed.
	OutcomeBreakdown Outcome = 0x40

	// FailureLostOptionLevel is low-nibble bit 0x01. The client shows
	// FAIL_RESULT_OPTLV_ZERO when the resulting level is 0 and
	// FAIL_RESULT_OPTLV_DOWN otherwise.
	FailureLostOptionLevel Outcome = 0x01
	// FailureLostDurability is low-nibble bit 0x02. It is not exclusive with
	// FailureLostOptionLevel; the client prints both messages.
	FailureLostDurability Outcome = 0x02
)

// Message names the client string an outcome byte produces, given the option
// level left after the attempt. It returns "" when the byte selects nothing,
// which the client handles by returning silently.
//
// The order of the tests is the client's: 0x10, then 0x20, then 0x40.
func (o Outcome) Message(optionLevelAfter int) string {
	switch {
	case o&OutcomeSuccess != 0:
		return "UIIT_MSG_REINFORCERR_SUCCESS"
	case o&OutcomeFailure != 0:
		if o&0x0f == 0 {
			return "UIIT_MSG_REINFORCERR_FAIL"
		}
		if o&FailureLostOptionLevel != 0 {
			if optionLevelAfter == 0 {
				return "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO"
			}
			return "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_DOWN"
		}
		return "UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY"
	case o&OutcomeBreakdown != 0:
		return "UIIT_MSG_REINFORCERR_BREAKDOWN"
	}
	return ""
}

// Messages returns every message the client would print for an outcome byte.
// The durability and option-level bits are independent, so a failure can show
// two lines; Message returns only the first.
func (o Outcome) Messages(optionLevelAfter int) []string {
	if o&OutcomeSuccess != 0 || o&OutcomeFailure == 0 {
		if m := o.Message(optionLevelAfter); m != "" {
			return []string{m}
		}
		return nil
	}
	if o&0x0f == 0 {
		return []string{"UIIT_MSG_REINFORCERR_FAIL"}
	}
	var out []string
	if o&FailureLostOptionLevel != 0 {
		if optionLevelAfter == 0 {
			out = append(out, "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO")
		} else {
			out = append(out, "UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_DOWN")
		}
	}
	if o&FailureLostDurability != 0 {
		out = append(out, "UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY")
	}
	return out
}

// The alchemy error codes, as the numbers they are. The engine names none of
// them anywhere in either binary, so this project does not either -- the codes
// travel on the wire and the client switches on them.
const (
	ErrNoSourceItem  = 0x5406 // CEnchant::vslot_004, slot[0].item == 0
	ErrNoTargetItem  = 0x5407 // CEnchant::vslot_004, target == 0
	ErrBaseCheck     = 0x5408 // CEnchant::vslot_004, the third check
	ErrKindMismatch  = 0x540a // CEnchant_Reinforce::vslot_005
	ErrSlotOccupied  = 0x5412 // CEnchant_Reinforce::vslot_000
	ErrNeedAthanasia = 0x5420 // CEnchant_Reinforce::vslot_005
)

// ErrorCodes is every 0x54xx value the CEnchant family returns, in order.
// Six are placed above; the rest appear in operations not yet read, and are
// listed so a reader knows the range is not exhausted by the named ones.
var ErrorCodes = []int{
	0x5406, 0x5407, 0x5408, 0x5409, 0x540a, 0x540f, 0x5410, 0x5412,
	0x5420, 0x5421, 0x5422, 0x5423, 0x5424, 0x5425, 0x5426,
}

// Success is the value an operation returns when it has nothing to complain
// about. Every slot in the family returns it the same way.
const Success = 1
