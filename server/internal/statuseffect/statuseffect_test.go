package statuseffect

import "testing"

// The mask table is the identity except for the one swap, and the inverse
// agrees with it. This is the test that would have caught round 248's
// alignment: slot 2 must carry the client's burn bit.
func TestMaskTableSwapsSlotsTwoAndThree(t *testing.T) {
	if MaskForSlot(SlotBurn) != 0x8 {
		t.Errorf("slot 2 mask %#x, want 0x8 -- the client's burn bit", MaskForSlot(SlotBurn))
	}
	if MaskForSlot(SlotElectricShock) != 0x4 {
		t.Errorf("slot 3 mask %#x, want 0x4 -- the client's electricshock bit",
			MaskForSlot(SlotElectricShock))
	}
	for i := 0; i < 32; i++ {
		if i == 2 || i == 3 {
			continue
		}
		if MaskForSlot(i) != 1<<uint(i) {
			t.Errorf("slot %d mask %#x, want %#x", i, MaskForSlot(i), 1<<uint(i))
		}
	}
	for bit := 0; bit < 32; bit++ {
		if got := MaskForSlot(SlotForBit(bit)); got != 1<<uint(bit) {
			t.Errorf("bit %d -> slot %d -> mask %#x; the round trip must close",
				bit, SlotForBit(bit), got)
		}
	}
	if MaskForSlot(32) != 0 || MaskForSlot(-1) != 0 || SlotForBit(99) != -1 {
		t.Error("out-of-range slots and bits should not answer")
	}
}

// Burn scales down with the param it divides by, and the divisor is
// `1 + param/100` -- so param 100 halves it.
func TestBurnTickDamageDividesByTheParamPercent(t *testing.T) {
	if got := BurnTickDamage(100, 0, 1.0); got != 100 {
		t.Errorf("param 0 -> %d, want the table value unchanged", got)
	}
	if got := BurnTickDamage(100, 100, 1.0); got != 50 {
		t.Errorf("param 100 -> %d, want 50 -- the divisor is 1 + 100/100", got)
	}
	if got := BurnTickDamage(100, 900, 1.0); got != 10 {
		t.Errorf("param 900 -> %d, want 10", got)
	}
	if got := BurnTickDamage(100, 0, 0.5); got != 50 {
		t.Errorf("the record's factor should scale it: %d, want 50", got)
	}
	if BurnTickDamage(0, 0, 1.0) != 0 {
		t.Error("no table value, no damage")
	}
}

// Poison stops at 1 HP. This is the rule worth having in a test: whatever the
// value, a poisoned character does not die of it.
func TestPoisonNeverKills(t *testing.T) {
	if got := PoisonTickDamage(30, 100); got != 30 {
		t.Errorf("30 off 100 HP -> %d, want 30", got)
	}
	if got := PoisonTickDamage(30, 20); got != 19 {
		t.Errorf("30 off 20 HP -> %d, want 19 -- it must leave 1 HP", got)
	}
	if got := PoisonTickDamage(30, 1); got != 0 {
		t.Errorf("at 1 HP -> %d, want 0", got)
	}
	for hp := 1; hp <= 200; hp++ {
		if hp-PoisonTickDamage(500, hp) < 1 {
			t.Fatalf("poison took a character at %d HP below 1", hp)
		}
	}
}

// The parry contribution is a percent of normal, clamped, with 100 neutral.
func TestElectricShockParryPercentClampsAroundTheNeutral(t *testing.T) {
	if got := ElectricShockParryPercent(0); got != 100 {
		t.Errorf("value 0 -> %d, want the neutral 100", got)
	}
	if got := ElectricShockParryPercent(40); got != 60 {
		t.Errorf("value 40 -> %d, want 60", got)
	}
	if got := ElectricShockParryPercent(140); got != 0 {
		t.Errorf("value 140 -> %d, want 0 (clamped below)", got)
	}
	if got := ElectricShockParryPercent(-50); got != 100 {
		t.Errorf("a negative value -> %d, want 100 (clamped above)", got)
	}
}

// Duration is the chance times the slot's own unit, and only the six elemental
// slots have one.
func TestDurationIsTheChanceTimesTheSlotUnit(t *testing.T) {
	cases := []struct {
		slot, unit int
	}{
		{SlotFreeze, 97}, {SlotFrostbite, 250}, {SlotBurn, 750},
		{SlotElectricShock, 500}, {SlotPoison, 1000}, {SlotZombie, 750},
	}
	for _, c := range cases {
		got, ok := DurationUnitMs(c.slot)
		if !ok || got != c.unit {
			t.Errorf("slot %d unit %d (ok=%v), want %d", c.slot, got, ok, c.unit)
		}
		if d, ok := DurationMs(c.slot, 20); !ok || d != 20*c.unit {
			t.Errorf("slot %d, chance 20 -> %d ms (ok=%v), want %d",
				c.slot, d, ok, 20*c.unit)
		}
	}
	// A chance of 30 on poison is half a minute; the same chance on freeze is
	// under three seconds. The spread is the engine's, not a rounding of one
	// unit.
	if d, _ := DurationMs(SlotPoison, 30); d != 30000 {
		t.Errorf("poison at chance 30 -> %d ms, want 30000", d)
	}
	if d, _ := DurationMs(SlotFreeze, 30); d != 2910 {
		t.Errorf("freeze at chance 30 -> %d ms, want 2910", d)
	}
	for _, slot := range []int{SlotBleeding, 6, 14, 31} {
		if _, ok := DurationUnitMs(slot); ok {
			t.Errorf("slot %d should have no unit -- the engine asserts there", slot)
		}
	}
}

// The removal test keeps the engine's strictness: alive at exactly the
// duration, gone one millisecond later.
func TestExpiredIsStrictlyGreaterThanTheDuration(t *testing.T) {
	const start, dur = 1_000_000, 5_000
	if Expired(start+dur, start, dur) {
		t.Error("a state at exactly its duration is still alive")
	}
	if !Expired(start+dur+1, start, dur) {
		t.Error("one millisecond past the duration it must go")
	}
	// GetTickCount wraps at 2^32; the engine's unsigned subtraction survives
	// it, and so must this.
	if Expired(5, 0xffffffff-5, 20) {
		t.Error("a state that started before the tick wrap should not expire early")
	}
}

// The overshoot is levels above ten times the status level, floored at zero.
func TestLevelOvershoot(t *testing.T) {
	if got := LevelOvershoot(70, 5); got != 20 {
		t.Errorf("level 70 against a level-5 status -> %d, want 20", got)
	}
	if got := LevelOvershoot(40, 5); got != 0 {
		t.Errorf("a target inside the reach -> %d, want 0", got)
	}
	if got := LevelOvershoot(1, 9); got != 0 {
		t.Errorf("far inside the reach -> %d, want 0", got)
	}
}

// Both falloffs stop at their floor, and the floors bite at the overshoot the
// constants imply: the duration at 20 levels over, the chance at 18.
func TestNonElementalFalloffsStopAtTheirFloors(t *testing.T) {
	if got := NonElementalDurationMs(10000, 0); got != 10000 {
		t.Errorf("no overshoot -> %d, want the authored 10000", got)
	}
	if got := NonElementalDurationMs(10000, 10); got != 7500 {
		t.Errorf("10 levels over -> %d, want 7500 (2.5%% a level)", got)
	}
	if got := NonElementalDurationMs(10000, 20); got != 5000 {
		t.Errorf("20 levels over -> %d, want the floor 5000", got)
	}
	if got := NonElementalDurationMs(10000, 200); got != 5000 {
		t.Errorf("far over -> %d, want the floor to hold at 5000", got)
	}
	if got := NonElementalChance(100, 10); got != 50 {
		t.Errorf("chance 10 levels over -> %d, want 50 (5%% a level)", got)
	}
	if got := NonElementalChance(100, 18); got != 10 {
		t.Errorf("chance 18 levels over -> %d, want the floor 10", got)
	}
	if got := NonElementalChance(100, 999); got != 10 {
		t.Errorf("chance far over -> %d, want the floor to hold at 10", got)
	}
	// The chance falls twice as fast as the duration, so it reaches its floor
	// first -- a deeply over-levelled target is hard to afflict but, once
	// afflicted, keeps the state for half its authored time.
	if NonElementalChance(100, 19) != 10 || NonElementalDurationMs(100, 19) == 50 {
		t.Error("at 19 levels over the chance should be floored and the duration not yet")
	}
}

// Kind is the bit plus one up to stun (round 875: from `ds` on the bit is the
// state's slot, READ at the OR sites), the fields ascend with the kinds, and
// the codes and bits are unique. If any of those breaks, the table was
// mis-transcribed.
func TestStateTableIsInternallyConsistent(t *testing.T) {
	seenCode := map[string]bool{}
	seenBit := map[int]bool{}
	prevField, prevKind := 0, 0
	for _, s := range States {
		if s.Kind <= 15 && s.Kind != s.Bit+1 {
			t.Errorf("%s: kind %d, bit %d -- up to stun kind must be bit+1", s.Code, s.Kind, s.Bit)
		}
		if seenCode[s.Code] || seenBit[s.Bit] {
			t.Errorf("%s / bit %d listed twice", s.Code, s.Bit)
		}
		seenCode[s.Code], seenBit[s.Bit] = true, true
		if s.Field <= prevField || s.Kind <= prevKind {
			t.Errorf("%s: field %#x kind %d does not ascend", s.Code, s.Field, s.Kind)
		}
		prevField, prevKind = s.Field, s.Kind
	}
	if len(States) != 23 {
		t.Errorf("%d states, want the 23 blocks Combat_ApplyStatusEffects carries", len(States))
	}
	// The absent bits: 12 and 23 have no block.
	for _, bit := range []int{12, 23} {
		if s, ok := StateByBit(bit); ok {
			t.Errorf("bit %d should have no applying block, got %q", bit, s.Code)
		}
	}
}

// Round 875: the cs* letters mean the state (READ: each block ORs its slot's
// bit; MEASURED: `cspd` arrives as mask 0x20000 and the client reports decay).
// This replaces round 278's "the codes do not mean their letters", which had
// read the kind as the bit.
func TestTheCurseCodesMeanTheirLetters(t *testing.T) {
	for code, want := range map[string]struct {
		bit   int
		label string
	}{
		"ds": {15, "DISEASE"}, "ca": {16, "CHAOS"}, "cspd": {17, "CURSE_PD"}, "csmd": {18, "CURSE_MD"},
		"cssr": {19, "CURSE_STR"}, "csit": {20, "CURSE_INT"}, "cshp": {21, "CURSE_HP"},
		"csmp": {22, "CURSIE_MP"}, "tb": {24, "TIME_BOMB"},
	} {
		s, ok := StateByCode(code)
		if !ok || s.Bit != want.bit || s.Label != want.label {
			t.Errorf("%s -> %+v, want bit %d %s", code, s, want.bit, want.label)
		}
	}
	// And the ones that DO agree, which is why the join is trustworthy.
	for code, label := range map[string]string{
		"fz": "FZ", "bu": "BU", "es": "ES", "dn": "DN", "tb": "TIME_BOMB",
		"st": "STUN", "my": "MYOPIA", "bl": "BLOOD", "se": "SLEEP", "rt": "ROOT",
	} {
		s, ok := StateByCode(code)
		if !ok || s.Label != label {
			t.Errorf("%s -> %q, want %q", code, s.Label, label)
		}
	}
	// The client's mask for burn is 0x8 and for electric shock 0x4 -- the same
	// swap the server's slot table carries, from the other binary.
	bu, _ := StateByCode("bu")
	es, _ := StateByCode("es")
	if 1<<uint(bu.Bit) != 0x8 || 1<<uint(es.Bit) != 0x4 {
		t.Error("burn must be mask 0x8 and electric shock 0x4")
	}
	if MaskForSlot(SlotBurn) != 1<<uint(bu.Bit) || MaskForSlot(SlotElectricShock) != 1<<uint(es.Bit) {
		t.Error("the server slot table and the client's bits must agree")
	}
}
