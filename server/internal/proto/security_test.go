package proto

import "testing"

func TestRollingByteDeterministic(t *testing.T) {
	a := NewRollingByte(1, 2, 3)
	b := NewRollingByte(1, 2, 3)

	for i := 0; i < 10; i++ {
		got, want := a.Next(), b.Next()
		if got != want {
			t.Fatalf("step %d: two generators with identical seeds diverged: %v != %v", i, got, want)
		}
	}
}

func TestRollingByteAdvances(t *testing.T) {
	r := NewRollingByte(0x12, 0x34, 0x56)

	seen := map[byte]bool{}
	for i := 0; i < 20; i++ {
		seen[r.Next()] = true
	}
	if len(seen) < 2 {
		t.Fatalf("generator produced only %d distinct value(s) over 20 steps, expected it to vary", len(seen))
	}
}

func TestRollingByteZeroSeed(t *testing.T) {
	// state[2] == 0 makes every step's multiplication collapse to 0; the
	// generator should still run without panicking (no div/mod involved).
	r := NewRollingByte(0, 0, 0)
	for i := 0; i < 5; i++ {
		r.Next()
	}
}
