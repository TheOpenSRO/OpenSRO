package metrics

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// The game loops' families: how long each tick took, how often a tick took
// longer than its own period (an overrun: the loop is falling behind), and
// when the loop last ticked (a loop that stops ticking -- a deadlock, a
// panic that killed its goroutine -- shows as a timestamp that stops moving).
var (
	loopSeconds = factory.histogramVec("loop_tick_seconds",
		"Time one tick of a server loop took, by loop (monster_ai, monster_aoi, cos, buffs, toggles, status, regen, mover, ground_items, potions, nest, ...).",
		LatencyBuckets, "loop")
	loopOverruns = factory.counterVec("loop_overruns_total",
		"Ticks that took longer than the loop's own period, by loop.", "loop")
	loopLast = factory.gaugeVec("loop_last_tick_timestamp_seconds",
		"Unix time a loop's last tick ended, by loop. The mover loop stops while nobody moves; every other loop ticks for the life of the server.",
		"loop")
	loopPeriod = factory.gaugeVec("loop_period_seconds",
		"Each loop's configured tick period, by loop.", "loop")
)

// Loop is one server loop's pre-resolved children.
type Loop struct {
	period   time.Duration
	seconds  prometheus.Observer
	overruns prometheus.Counter
	last     prometheus.Gauge
}

// NewLoop registers loop name with its tick period. Call it once per loop
// (at package init of the loop's file).
func NewLoop(name string, period time.Duration) *Loop {
	loopPeriod.WithLabelValues(name).Set(period.Seconds())
	return &Loop{
		period:   period,
		seconds:  loopSeconds.WithLabelValues(name),
		overruns: loopOverruns.WithLabelValues(name),
		last:     loopLast.WithLabelValues(name),
	}
}

// Tick records one tick that started at start and ends now. A nil Loop does
// nothing, so a caller may hold an optional one.
func (l *Loop) Tick(start time.Time) {
	if l == nil {
		return
	}
	now := time.Now()
	d := now.Sub(start)
	l.seconds.Observe(d.Seconds())
	if l.period > 0 && d > l.period {
		l.overruns.Inc()
	}
	l.last.Set(float64(now.UnixNano()) / 1e9)
}
