package world

import (
	"math"
	"math/rand"
	"os"
	"sort"
	"testing"
	"time"
)

// Round 749's review, F7: how long the mover pass holds the hub's write lock,
// every player walking at 50, 40 passes of 250 ms on a simulated clock (the
// review's own setup). OPENSRO_PASS_BENCH=1 runs the table; without it a
// 1,000-player pass runs once as a smoke check.
func TestMoverPassLockHold(t *testing.T) {
	cases := []struct {
		n      int
		blocks int
	}{{1000, 10}}
	if os.Getenv("OPENSRO_PASS_BENCH") != "" {
		cases = []struct {
			n      int
			blocks int
		}{{1000, 10}, {10000, 10}, {10000, 100}}
	}
	for _, c := range cases {
		h, clk := clockedHub()
		rng := rand.New(rand.NewSource(749))
		span := float64(c.blocks) * 320
		sess := make([]interface{ ID() uint64 }, c.n)
		for i := 0; i < c.n; i++ {
			s := fakeSession(uint64(i + 1))
			sess[i] = s
			h.Enter(s, int64(i+1), "Crowd", 1, "jangan", Position{X: rng.Float64()*span - span/2, Z: rng.Float64()*span - span/2})
		}
		walk := func() {
			for i := 0; i < c.n; i++ {
				e, _ := h.EntityBySession(sess[i].ID())
				a := rng.Float64() * 2 * math.Pi
				h.StartMove(fakeSession(uint64(i+1)), MoveOrder{Dest: Position{X: e.Pos.X + 200*math.Sin(a), Z: e.Pos.Z + 200*math.Cos(a)}, Speed: 50})
			}
		}
		walk()
		var holds []time.Duration
		crossings := 0
		for p := 0; p < 40; p++ {
			if p%16 == 15 {
				walk() // the legs are 4 s; keep everyone walking
			}
			clk.add(250 * time.Millisecond)
			pass := h.AdvanceMovers(func(int64) float64 { return 50 })
			holds = append(holds, time.Duration(h.passHold.Load()))
			crossings += len(pass.Crossings)
		}
		sort.Slice(holds, func(i, j int) bool { return holds[i] < holds[j] })
		var sum time.Duration
		for _, d := range holds {
			sum += d
		}
		mean := sum / time.Duration(len(holds))
		t.Logf("MOVERPASS n=%d blocks=%dx%d: write lock per pass mean %v, worst %v, share of the 250 ms %.2f%%, crossings per pass %d",
			c.n, c.blocks, c.blocks, mean, holds[len(holds)-1], 100*float64(mean)/float64(250*time.Millisecond), crossings/40)
	}
}
