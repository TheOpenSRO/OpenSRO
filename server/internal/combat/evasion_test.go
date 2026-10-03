package combat

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEvadedChance(t *testing.T) {
	for _, c := range []struct {
		name   string
		chance int
		evade  float64
		want   int
	}{
		// The zero every call site passes today: the chance is untouched.
		{"no evasion", 30, 0, 30},
		// The recovered divisor, chance / (1 + evade/100).
		{"evade 100 halves it", 30, 100, 15},
		{"evade 50", 30, 50, 20},
		// Rounded, because the roll takes whole percent (ChanceRollSides).
		{"rounds to nearest", 25, 30, 19}, // 25/1.3 = 19.23
		// A chance of zero stays zero however it is opposed -- every Jangan
		// species has Block 0, so this is the shipped roster's real case.
		{"zero chance", 0, 250, 0},
		{"negative chance is zero", -5, 0, 0},
		// A negative evasion would MULTIPLY the chance; the engine cannot
		// produce one and neither can this.
		{"negative evasion is ignored", 30, -40, 30},
	} {
		if got := EvadedChance(c.chance, c.evade); got != c.want {
			t.Errorf("%s: EvadedChance(%d, %v) = %d, want %d", c.name, c.chance, c.evade, got, c.want)
		}
	}
}

// evasionTagAllowlist is where 'evcr' and 'evbl' are permitted to appear: the
// vocabulary table that names every param tag, its test, and the divisor's own
// file. Anywhere else means a player-side evasion source has been added.
var evasionTagAllowlist = map[string]bool{
	"internal/combat/paramtags.go":      true,
	"internal/combat/paramtags_test.go": true,
	"internal/combat/evasion.go":        true,
	"internal/combat/evasion_test.go":   true,
}

// The disclosure in EvadedChance rests on a precondition: NO PLAYER IN OPENSRO
// CAN CARRY 'evcr' OR 'evbl', because nothing aggregates an item's magic
// options into combat stats. Four of the six evasion divisors are zero for that
// reason alone.
//
// A prose caveat about an absent feature rots silently the day the feature
// arrives -- which is exactly how three comments came to justify six call sites
// with a measurement that covered two. This is the tripwire: it fails when a
// consumer of either tag appears, and the fix is to pass the real term at the
// four disclosed sites rather than to widen the allowlist.
//
// It scans source at RUNTIME, so Go's test cache cannot see the inputs change.
// Run `go test -count=1` when trusting it.
func TestNoPlayerEvasionSourceExists(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	var offenders []string
	seen := 0
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") {
			return err
		}
		rel, rerr := filepath.Rel(root, path)
		if rerr != nil || evasionTagAllowlist[filepath.ToSlash(rel)] {
			return nil
		}
		b, rerr := os.ReadFile(path)
		if rerr != nil {
			return nil
		}
		seen++
		for _, tag := range []string{"TagEvadeCri", "TagEvadeBlk", `"evcr"`, `"evbl"`} {
			if strings.Contains(string(b), tag) {
				offenders = append(offenders, rel+" mentions "+tag)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	// The probe must have looked at something. A walk that silently visited no
	// files would pass this test while proving nothing -- this project has been
	// caught by an empty probe reading as a negative result more than once.
	if seen < 50 {
		t.Fatalf("the scan only read %d .go files under %s; it is not probing the tree", seen, root)
	}
	if len(offenders) > 0 {
		t.Errorf("a player-side evasion source now exists, so four of the six "+
			"divisors in EvadedChance are no longer zero:\n  %s\n"+
			"Pass the real evade term at the disclosed call sites (session's "+
			"playerEvasion) instead of widening the allowlist.",
			strings.Join(offenders, "\n  "))
	}
}
