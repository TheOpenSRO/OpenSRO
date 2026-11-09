package metrics

// The multi-process mode's measurements (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.7): each instance's tick cost by world
// code, the hand-offs' entry time (the source's send to the target's zone
// change), and a raw tally the load test reads off the log.

import (
	"sync"
	"time"
)

var (
	worldTickSeconds = factory.histogramVec("world_tick_seconds",
		"time one instance's base tick took (its nest pass, monster AI and area of interest), by world code",
		[]float64{0.00005, 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1},
		"world")
	handoffSeconds = factory.histogramVec("handoff_seconds",
		"time from a hand-off's send on the source to the zone change on the target",
		[]float64{0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5}, "dir")
)

// tickTally is every tick's duration since the last Drain (the load test's
// percentiles), bounded; kept only once DrainTicks has been called (a world
// host's "world load" line), so one process keeps nothing.
var tickTally = struct {
	sync.Mutex
	on bool
	d  []time.Duration
}{}

const tickTallyMax = 1 << 20

// WorldTick records one instance tick of the world code.
func WorldTick(code string, d time.Duration) {
	worldTickSeconds.WithLabelValues(code).Observe(d.Seconds())
	tickTally.Lock()
	if tickTally.on && len(tickTally.d) < tickTallyMax {
		tickTally.d = append(tickTally.d, d)
	}
	tickTally.Unlock()
}

// DrainTicks is the tick durations recorded since the last call.
func DrainTicks() []time.Duration {
	tickTally.Lock()
	defer tickTally.Unlock()
	tickTally.on = true
	out := tickTally.d
	tickTally.d = nil
	return out
}

// Handoff records one hand-off's entry time.
func Handoff(d time.Duration) { handoffSeconds.WithLabelValues("in").Observe(d.Seconds()) }
