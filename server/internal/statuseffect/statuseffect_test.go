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
