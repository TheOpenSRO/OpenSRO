package rates

import (
	"math"
	"testing"
)

// TestResolveMatchesTheEngineShape walks the three steps the config loader
// takes: percentage/100, floor at 1.0, clamp at the per-knob cap.
func TestResolveMatchesTheEngineShape(t *testing.T) {
	for _, tc := range []struct {
		name string
		raw  string
		cap  float64
		want float64
	}{
		{"unset is 1x", "", MaxExpRatio, 1.0},
		{"100 is exactly 1x -- the setting is a percentage", "100", MaxExpRatio, 1.0},
		{"150 is 1.5x", "150", MaxExpRatio, 1.5},
		{"250 hits the exp cap exactly", "250", MaxExpRatio, 2.5},
		{"above the cap is clamped, not rejected", "9999", MaxExpRatio, 2.5},
		{"the drop cap is higher", "9999", MaxDropItemRatio, 3.0},
		{"the hwan cap is higher still", "9999", MaxHwanGainFactor, 10.0},

		// The floor is the engine's "system default" branch, not input
		// validation: anything under 1x becomes 1x rather than being honoured.
		{"below 1x falls back to the default", "50", MaxExpRatio, 1.0},
		{"zero falls back", "0", MaxExpRatio, 1.0},
		{"negative falls back", "-500", MaxExpRatio, 1.0},
		{"99 is still below 1x", "99", MaxExpRatio, 1.0},

		// atol yields 0 for nonsense, and 0/100 is below the floor.
		{"nonsense falls back", "fast", MaxExpRatio, 1.0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolve(tc.raw, tc.cap); math.Abs(got-tc.want) > 1e-9 {
				t.Errorf("resolve(%q, %v) = %v, want %v", tc.raw, tc.cap, got, tc.want)
			}
		})
	}
}

// TestRatesCannotGoBelowOne is the property worth stating on its own: the
// engine has no way to express a slower-than-retail server, so neither does
// this. A future change that lets a 0.5x rate through breaks it here.
func TestRatesCannotGoBelowOne(t *testing.T) {
	caps := []float64{MaxExpRatio, MaxPartyExpRatio, MaxDropItemRatio, MaxGoldRatio, MaxHwanGainFactor}
	for _, c := range caps {
		for n := -1000; n <= 1000; n += 7 {
			got := resolve(itoa(n), c)
			if got < MinRatio {
				t.Fatalf("resolve(%d, %v) = %v, below the floor %v", n, c, got, MinRatio)
			}
			if got > c {
				t.Fatalf("resolve(%d, %v) = %v, above the cap", n, c, got)
			}
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}

// TestExpForPicksOneKnob covers the selection recovered from
// GObjPC_ReceiveKillReward: the engine takes ExpRatio OR ExpRatioParty by party
// membership. It never multiplies them, which is the mistake this guards.
func TestExpForPicksOneKnob(t *testing.T) {
	r := Rates{Exp: 1.5, PartyExp: 2.0}
	if got := r.ExpFor(false); got != 1.5 {
		t.Errorf("solo: got %v, want the ExpRatio 1.5", got)
	}
	if got := r.ExpFor(true); got != 2.0 {
		t.Errorf("in a party: got %v, want the ExpRatioParty 2.0", got)
	}
	// If the two were ever multiplied this would be 3.0.
	if got := r.ExpFor(true); got == r.Exp*r.PartyExp {
		t.Error("the two exp knobs must not be multiplied together")
	}
}

// TestDefaultIsEverythingAtOne pins the engine's pre-config state: the globals
// are statically initialised to 1.0f before any setting is read.
func TestDefaultIsEverythingAtOne(t *testing.T) {
	d := Default()
	for name, v := range map[string]float64{
		"Exp": d.Exp, "PartyExp": d.PartyExp, "DropItem": d.DropItem,
		"Gold": d.Gold, "HwanGain": d.HwanGain,
	} {
		if v != 1 {
			t.Errorf("Default().%s = %v, want 1", name, v)
		}
	}
	if d.ExpFor(false) != 1 || d.ExpFor(true) != 1 {
		t.Error("the default must be 1x whether or not the character is partied")
	}
}
