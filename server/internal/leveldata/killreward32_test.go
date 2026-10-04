package leveldata

import "testing"

// The level scalers at the engine's precision (round 712's review, finding 4):
// the step is a float32 before the `1 -`.
func TestLevelScalersFloat32(t *testing.T) {
	// 14 against 7: 1 - f32(4*0.15) = 0.39999998, not f32(1 - 0.6) = 0.40000001.
	if got, want := ExpWindowScale32(14, 7), float32(1-float64(float32(0.6))); got != want {
		t.Fatalf("window 14 vs 7 = %v, want %v", got, want)
	}
	if ExpWindowScale32(14, 7) == float32(ExpWindowScale(14, 7)) {
		t.Fatalf("the float32 window should differ from the rounded float64 one here")
	}
	if ExpWindowScale32(20, 20) != 1 || ExpWindowScale32(20, 15) != float32(0.9) || ExpWindowScale32(50, 1) != float32(0.1) {
		t.Fatalf("window band, near-below or floor wrong")
	}
	// Diff: f32(bonus + 1) then + steps*0.03, stored. Even level: 1.09.
	if got := ExpDiffScale32(20, 20, false, false); got != float32(1.09) {
		t.Fatalf("diff even = %v", got)
	}
	// Exp-share party, China, a target 9 up: f32(0.45f + 1) + 12*0.03.
	want := float32(12*0.03 + float64(float32(float64(float32(0.45))+1)))
	if got := ExpDiffScale32(20, 29, true, false); got != want {
		t.Fatalf("diff +9 party = %v, want %v", got, want)
	}
	if ExpDiffScale32(30, 20, true, false) != 1 {
		t.Fatalf("out-levelled diff should be 1")
	}
}
