package repair

import "testing"

func TestUnitPriceFloorsAtOne(t *testing.T) {
	// A cheap item with a long durability bar would price below 1 per point;
	// the binary's `fld1` clamp stops it.
	if got := UnitPrice(10, 1000); got != MinUnitPrice {
		t.Errorf("UnitPrice(10, 1000) = %v, want the floor %v", got, MinUnitPrice)
	}
	if got := UnitPrice(1000, 100); got != 10 {
		t.Errorf("UnitPrice(1000, 100) = %v, want 10", got)
	}
	// Exactly at the floor stays at the floor.
	if got := UnitPrice(100, 100); got != 1 {
		t.Errorf("UnitPrice(100, 100) = %v, want 1", got)
	}
}

func TestEstimateRefusals(t *testing.T) {
	if q := Estimate(0, 1000, 100, 50); q.Refusal != ErrNotEnoughMoney {
		t.Errorf("no gold gave %#x, want %#x", q.Refusal, ErrNotEnoughMoney)
	}
	if q := Estimate(-1, 1000, 100, 50); q.Refusal != ErrNotEnoughMoney {
		t.Errorf("negative gold gave %#x, want %#x", q.Refusal, ErrNotEnoughMoney)
	}
	// Whole item: missing is 0, which is `< 1`.
	if q := Estimate(1_000_000, 1000, 100, 100); q.Refusal != ErrNothingToRepair {
		t.Errorf("an undamaged item gave %#x, want %#x", q.Refusal, ErrNothingToRepair)
	}
	// Over-full is also `missing < 1`.
	if q := Estimate(1_000_000, 1000, 100, 150); q.Refusal != ErrNothingToRepair {
		t.Errorf("an over-full item gave %#x, want %#x", q.Refusal, ErrNothingToRepair)
	}
}

func TestEstimateFullRepairCostsTheBasis(t *testing.T) {
	// The division spreads the price basis across the durability range, so
	// restoring every point costs the basis back.
	q := Estimate(1_000_000, 1000, 100, 0)
	if q.Refusal != 0 {
		t.Fatalf("refused with %#x", q.Refusal)
	}
	if q.Units != 100 {
		t.Errorf("restored %d units, want 100", q.Units)
	}
	if q.Cost != 1000 {
		t.Errorf("cost %v, want the price basis 1000", q.Cost)
	}
}

// A character who cannot pay for a full repair gets a partial one, not a
// refusal -- the engine repairs what the gold buys.
func TestEstimateIsPartialWhenGoldIsShort(t *testing.T) {
	// price 10/point, 100 points missing, only 250 gold.
	q := Estimate(250, 1000, 100, 0)
	if q.Refusal != 0 {
		t.Fatalf("refused with %#x", q.Refusal)
	}
	if q.Units != 25 {
		t.Errorf("restored %d units, want 25", q.Units)
	}
	if q.Cost != 250 {
		t.Errorf("cost %v, want 250", q.Cost)
	}
}

// The cap applies to the AFFORDABLE count before the missing comparison, so an
// item missing more than 100,000 cannot be made whole in one repair even by
// someone who could pay.
func TestUnitCapAppliesToTheAffordableCount(t *testing.T) {
	const missing = MaxUnitsPerRepair + 5000
	q := Estimate(1<<62, 1, missing+1, 0) // price floors at 1.0
	if q.Refusal != 0 {
		t.Fatalf("refused with %#x", q.Refusal)
	}
	if q.Units != MaxUnitsPerRepair {
		t.Errorf("restored %d units, want the cap %d", q.Units, MaxUnitsPerRepair)
	}
}

func TestConstants(t *testing.T) {
	if MaxUnitsPerRepair != 0x186a0 {
		t.Errorf("MaxUnitsPerRepair is %d; the comparison is against 0x186a0", MaxUnitsPerRepair)
	}
	if MinUnitPrice != 1.0 {
		t.Errorf("MinUnitPrice is %v; the clamp is a literal fld1", MinUnitPrice)
	}
	seen := map[int]bool{}
	for _, c := range []int{ErrNotEnoughMoney, ErrNothingToRepair, ErrCannotBeRepaired, ErrCannotBeRevived} {
		if seen[c] {
			t.Errorf("code %#x listed twice", c)
		}
		seen[c] = true
	}
}
