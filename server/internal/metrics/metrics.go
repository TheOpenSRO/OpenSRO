// Package metrics is the game server's Prometheus instrumentation (round 858,
// OURS): one registry, registered once at package init, and the small helpers
// the gateway, the world, the game loops and the stores call at their
// chokepoints. Everything on a hot path is a pre-resolved counter or
// histogram child (an atomic add); nothing is labelled per player or per
// character, and every label takes its values from a fixed set (an opcode
// from the generated table, a zone from the named zones, a loop name, ...).
//
// The server serves the registry on -metrics-addr (default 127.0.0.1:9469,
// cmd/server); Grafana Alloy on the host scrapes it and remote-writes to the
// monitoring stack (deploy/observability/README.md).
package metrics

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"runtime"
	"runtime/debug"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Namespace prefixes every OpenSRO metric.
const Namespace = "opensro"

// Registry holds every metric the server exposes: the Go runtime and process
// collectors, the build info and the families below. A private registry, not
// prometheus.DefaultRegisterer, so a test (or a tool linking this package)
// sees exactly what the server serves.
var Registry = prometheus.NewRegistry()

// factory registers on Registry.
var factory = promauto{Registry}

type promauto struct{ r *prometheus.Registry }

func (f promauto) counter(name, help string) prometheus.Counter {
	c := prometheus.NewCounter(prometheus.CounterOpts{Namespace: Namespace, Name: name, Help: help})
	f.r.MustRegister(c)
	return c
}

func (f promauto) counterVec(name, help string, labels ...string) *prometheus.CounterVec {
	c := prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: Namespace, Name: name, Help: help}, labels)
	f.r.MustRegister(c)
	return c
}

func (f promauto) gauge(name, help string) prometheus.Gauge {
	g := prometheus.NewGauge(prometheus.GaugeOpts{Namespace: Namespace, Name: name, Help: help})
	f.r.MustRegister(g)
	return g
}

func (f promauto) gaugeVec(name, help string, labels ...string) *prometheus.GaugeVec {
	g := prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: Namespace, Name: name, Help: help}, labels)
	f.r.MustRegister(g)
	return g
}

func (f promauto) histogramVec(name, help string, buckets []float64, labels ...string) *prometheus.HistogramVec {
	h := prometheus.NewHistogramVec(prometheus.HistogramOpts{Namespace: Namespace, Name: name, Help: help, Buckets: buckets}, labels)
	f.r.MustRegister(h)
	return h
}

// LatencyBuckets are for things that should take micro- to milliseconds and
// matter when they take a second: a handler, a tick, a query.
var LatencyBuckets = []float64{.0001, .00025, .0005, .001, .0025, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5}

var buildInfo = prometheus.NewGaugeVec(prometheus.GaugeOpts{
	Namespace: Namespace, Name: "build_info",
	Help: "Always 1; the labels say which server build is running (version from -ldflags -X main.version, commit from the Go build's VCS stamp).",
}, []string{"version", "commit", "modified", "go_version"})

var startTime = prometheus.NewGauge(prometheus.GaugeOpts{
	Namespace: Namespace, Name: "start_time_seconds",
	Help: "Unix time the server process started its metrics (a restart moves it).",
})

func init() {
	Registry.MustRegister(
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		// The default Go collector plus the scheduler's latency histogram
		// (go_sched_latencies_seconds): the number that rises when the
		// process is CPU-starved, a lag spike's first suspect.
		collectors.NewGoCollector(collectors.WithGoCollectorRuntimeMetrics(collectors.MetricsScheduler, collectors.MetricsGC)),
		buildInfo, startTime,
	)
	startTime.Set(float64(time.Now().UnixNano()) / 1e9)
	SetBuildInfo("dev")
}

// SetBuildInfo labels opensro_build_info with version (main.version, "dev"
// when not stamped) and the VCS revision the Go toolchain embedded.
func SetBuildInfo(version string) {
	commit, modified := "unknown", "unknown"
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision":
				commit = s.Value
				if len(commit) > 12 {
					commit = commit[:12]
				}
			case "vcs.modified":
				modified = s.Value
			}
		}
	}
	if version == "" {
		version = "dev"
	}
	buildInfo.Reset()
	buildInfo.WithLabelValues(version, commit, modified, runtime.Version()).Set(1)
}

// Handler serves Registry in the Prometheus text (or OpenMetrics) format.
func Handler() http.Handler {
	return promhttp.HandlerFor(Registry, promhttp.HandlerOpts{
		Registry:          Registry, // promhttp_metric_handler_errors_total
		EnableOpenMetrics: true,
	})
}

// Serve serves /metrics on addr until ctx ends. An empty addr does nothing
// (metrics off). A listen error is returned, so a typo stops the server
// rather than leaving it unobserved. A non-loopback address is logged: the
// page names no secret, but the game port is the only one meant for the
// internet.
func Serve(ctx context.Context, addr string, logger *slog.Logger) (net.Addr, error) {
	if addr == "" {
		return nil, nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.Handle("/metrics", Handler())
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("OpenSRO server metrics: /metrics\n"))
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) && logger != nil {
			logger.Warn("metrics listener stopped", "err", err)
		}
	}()
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	if logger != nil {
		if ta, ok := ln.Addr().(*net.TCPAddr); ok && !ta.IP.IsLoopback() {
			logger.Warn("metrics are listening on a non-loopback address; keep the port off the internet", "addr", ln.Addr().String())
		}
		logger.Info("metrics on (-metrics-addr)", "addr", "http://"+ln.Addr().String()+"/metrics")
	}
	return ln.Addr(), nil
}
