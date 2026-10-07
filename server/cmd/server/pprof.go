package main

// The debug listener (OURS, off by default): -pprof-addr / OPENSRO_PPROF_ADDR
// serves net/http/pprof on its own address, and while it is on a runtime
// stats line is logged every 30 s -- GC, heap, goroutines and the scheduler's
// latency -- so a lag report can be lined up against the collector and the
// run queue. Meant for 127.0.0.1:6060: the handlers expose stacks and
// command lines and must never face the internet (deploy/README.md).

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/http/pprof"
	"runtime"
	"runtime/metrics"
	"time"
)

// runtimeStatsEvery is how often the stats line is logged while the debug
// listener is on.
const runtimeStatsEvery = 30 * time.Second

// mutexProfileFraction: one contention event in this many is recorded for
// /debug/pprof/mutex while the listener is on.
const mutexProfileFraction = 100

// startDebug serves pprof on addr until ctx ends and starts the stats line.
// An empty addr does nothing. A listen error is returned (the server refuses
// to start on a typo rather than silently running without the profiler).
func startDebug(ctx context.Context, addr string, logger *slog.Logger) error {
	if addr == "" {
		return nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Warn("pprof listener stopped", "err", err)
		}
	}()
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	// Contended locks sampled one in mutexProfileFraction, so
	// /debug/pprof/mutex says which lock a stall waited on (off without the
	// listener: the runtime's default is 0).
	runtime.SetMutexProfileFraction(mutexProfileFraction)
	if !isLoopback(ln.Addr()) {
		logger.Warn("pprof is listening on a non-loopback address: it exposes stacks and the command line; keep it off the internet",
			"addr", ln.Addr().String())
	}
	logger.Info("pprof on (-pprof-addr): debug only", "addr", "http://"+ln.Addr().String()+"/debug/pprof/",
		"runtime_stats_every", runtimeStatsEvery.String())
	go runRuntimeStats(ctx, logger, runtimeStatsEvery)
	return nil
}

func isLoopback(a net.Addr) bool {
	ta, ok := a.(*net.TCPAddr)
	return ok && ta.IP.IsLoopback()
}

// runtimeSamples are the runtime/metrics the stats line reads.
var runtimeSamples = []string{
	"/sched/latencies:seconds",       // time goroutines sat runnable before running
	"/sched/pauses/total/gc:seconds", // stop-the-world pauses for the GC
	"/sched/goroutines:goroutines",   // live goroutines
	"/gc/cycles/total:gc-cycles",     // completed GC cycles
}

// runRuntimeStats logs one line every `every` until ctx ends: the GC count
// (total and in the window), the last GC pause and the window's longest, the
// heap in use, the goroutines, and the scheduler latency over the window
// (p50 / p99 / max of how long a runnable goroutine waited for a thread: the
// number that rises when the process is CPU-starved). The histograms are
// cumulative, so each line is the difference from the previous one.
func runRuntimeStats(ctx context.Context, logger *slog.Logger, every time.Duration) {
	samples := make([]metrics.Sample, len(runtimeSamples))
	for i, n := range runtimeSamples {
		samples[i].Name = n
	}
	var prevSched, prevPause []uint64
	var prevGC uint64
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		metrics.Read(samples)
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		args := []any{"gc_total", ms.NumGC}
		gc := uint64(0)
		if samples[3].Value.Kind() == metrics.KindUint64 {
			gc = samples[3].Value.Uint64()
		}
		args = append(args, "gc_window", gc-prevGC)
		prevGC = gc
		last := time.Duration(0)
		if ms.NumGC > 0 {
			last = time.Duration(ms.PauseNs[(ms.NumGC+255)%256])
		}
		args = append(args, "gc_pause_last", last.String())
		if samples[1].Value.Kind() == metrics.KindFloat64Histogram {
			h := samples[1].Value.Float64Histogram()
			_, _, mx, _ := histWindow(h, prevPause)
			prevPause = append(prevPause[:0], h.Counts...)
			args = append(args, "gc_pause_max_window", secs(mx))
		}
		args = append(args, "heap_inuse_mb", ms.HeapInuse>>20, "heap_alloc_mb", ms.HeapAlloc>>20, "sys_mb", ms.Sys>>20)
		if samples[2].Value.Kind() == metrics.KindUint64 {
			args = append(args, "goroutines", samples[2].Value.Uint64())
		}
		if samples[0].Value.Kind() == metrics.KindFloat64Histogram {
			h := samples[0].Value.Float64Histogram()
			p50, p99, mx, n := histWindow(h, prevSched)
			prevSched = append(prevSched[:0], h.Counts...)
			args = append(args, "sched_lat_p50", secs(p50), "sched_lat_p99", secs(p99), "sched_lat_max", secs(mx), "sched_events", n)
		}
		logger.Info("runtime stats", args...)
	}
}

// histWindow is the p50, p99 and max (the upper bound of the highest bucket
// with a count) of the histogram h less the counts prev (the previous read;
// nil for the first), and the number of events in the window. A bucket's
// value is its upper bound, so the figures are ceilings at the runtime's
// bucket resolution.
func histWindow(h *metrics.Float64Histogram, prev []uint64) (p50, p99, mx float64, n uint64) {
	d := make([]uint64, len(h.Counts))
	for i, c := range h.Counts {
		if i < len(prev) && prev[i] <= c {
			c -= prev[i]
		}
		d[i] = c
		n += c
	}
	if n == 0 {
		return 0, 0, 0, 0
	}
	upper := func(i int) float64 {
		b := h.Buckets[i+1]
		if math.IsInf(b, 1) {
			return h.Buckets[i]
		}
		return b
	}
	var seen uint64
	q50, q99 := (n+1)/2, n-n/100
	got50, got99 := false, false
	for i, c := range d {
		if c == 0 {
			continue
		}
		seen += c
		if !got50 && seen >= q50 {
			p50, got50 = upper(i), true
		}
		if !got99 && seen >= q99 {
			p99, got99 = upper(i), true
		}
		mx = upper(i)
	}
	return p50, p99, mx, n
}

func secs(s float64) string { return time.Duration(s * float64(time.Second)).String() }
