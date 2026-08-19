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

// TestLFSRByteKnownValues cross-checks lfsrByte's 32-round output against an
// independently computed reference for the same seeds, to catch transcription
// bugs in a bit-exact algorithm where "looks about right" isn't good enough.
func TestLFSRByteKnownValues(t *testing.T) {
	cases := []struct {
		seed uint32
		want byte
	}{
		{0, 0x00},
		{1, 0xff},
		{0x9abfb3b6, 0x2d},
		{0xdeadbeef, 0xed},
		{12345, 0xa6},
	}
	for _, c := range cases {
		if got := lfsrByte(c.seed); got != c.want {
			t.Errorf("lfsrByte(0x%x) = 0x%02x, want 0x%02x", c.seed, got, c.want)
		}
	}
}

func TestDeriveSeedDeterministic(t *testing.T) {
	a0, a1, a2 := DeriveSeed(42)
	b0, b1, b2 := DeriveSeed(42)
	if a0 != b0 || a1 != b1 || a2 != b2 {
		t.Fatalf("DeriveSeed(42) not deterministic: (%v,%v,%v) != (%v,%v,%v)", a0, a1, a2, b0, b1, b2)
	}
}

func TestDeriveSeedNoZeroBytes(t *testing.T) {
	// b1/b2 feed RollingByte's multiplication; a zero there would collapse
	// the generator, which is exactly what the 0->1 substitution guards
	// against (see DeriveSeed's doc comment).
	for _, seed := range []uint32{0, 1, 2, 3, 0xffffffff} {
		_, b1, b2 := DeriveSeed(seed)
		if b1 == 0 || b2 == 0 {
			t.Errorf("DeriveSeed(0x%x) produced a zero state byte: b1=%v b2=%v", seed, b1, b2)
		}
	}
}
