package main

// The server's observability (round 858, OURS): where the log goes and at
// which level, and the Prometheus endpoint. deploy/observability/README.md
// says how prod feeds Loki and Prometheus from these.

import (
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/logfile"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
)

// version is the release this binary was built as, stamped with
// -ldflags "-X main.version=v0.1.623" (opensro_build_info); "dev" otherwise.
var version = "dev"

// defaultMetricsAddr is where /metrics is served unless -metrics-addr (or
// OPENSRO_METRICS_ADDR) says otherwise; loopback only, for the host's Alloy.
const defaultMetricsAddr = "127.0.0.1:9469"

// observeFlags are the logging and metrics flags.
type observeFlags struct {
	metricsAddr *string
	logFile     *string
	logMaxMB    *int
	logKeep     *int
	logCompress *bool
	logLevel    *string
}

func registerObserveFlags() observeFlags {
	metricsAddr := defaultMetricsAddr
	if v, ok := os.LookupEnv("OPENSRO_METRICS_ADDR"); ok {
		metricsAddr = v
	}
	maxMB, keep := 100, 10
	if v, err := strconv.Atoi(os.Getenv("OPENSRO_LOG_MAX_SIZE_MB")); err == nil {
		maxMB = v
	}
	if v, err := strconv.Atoi(os.Getenv("OPENSRO_LOG_MAX_FILES")); err == nil {
		keep = v
	}
	compress := os.Getenv("OPENSRO_LOG_COMPRESS") != "0" && os.Getenv("OPENSRO_LOG_COMPRESS") != "false"
	level := os.Getenv("OPENSRO_LOG_LEVEL")
	if level == "" {
		level = "info"
	}
	return observeFlags{
		metricsAddr: flag.String("metrics-addr", metricsAddr,
			"serve Prometheus metrics at http://<addr>/metrics (env OPENSRO_METRICS_ADDR). OURS, round 858. Default "+defaultMetricsAddr+
				" (loopback: the host's Grafana Alloy scrapes it); empty turns it off. See deploy/observability/README.md."),
		logFile: flag.String("log-file", os.Getenv("OPENSRO_LOG_FILE"),
			"write the log to this file instead of stdout, rotating it by size (env OPENSRO_LOG_FILE): past -log-max-size-mb it is "+
				"renamed <file>.1 (older ones shift up to -log-max-files, gzipped) and a new one is opened. OURS, round 858. "+
				"Empty (default): the log goes to stdout as before. A Go panic's stack still goes to stderr."),
		logMaxMB: flag.Int("log-max-size-mb", maxMB,
			"with -log-file, rotate once the file passes this many MB (env OPENSRO_LOG_MAX_SIZE_MB, default 100; 0 never rotates)"),
		logKeep: flag.Int("log-max-files", keep,
			"with -log-file, how many rotated files to keep (env OPENSRO_LOG_MAX_FILES, default 10)"),
		logCompress: flag.Bool("log-compress", compress,
			"with -log-file, gzip the rotated files (env OPENSRO_LOG_COMPRESS, default true)"),
		logLevel: flag.String("log-level", level,
			"the least level logged: debug, info, warn or error (env OPENSRO_LOG_LEVEL, default info). Every packet's "+
				"\"packet received\" line is DEBUG since round 858."),
	}
}

// metricsAddrExplicit reports whether the operator named the metrics address
// (the flag or OPENSRO_METRICS_ADDR) rather than taking the default.
func (f observeFlags) metricsAddrExplicit() bool {
	if _, ok := os.LookupEnv("OPENSRO_METRICS_ADDR"); ok {
		return true
	}
	set := false
	flag.Visit(func(fl *flag.Flag) {
		if fl.Name == "metrics-addr" {
			set = true
		}
	})
	return set
}

// parseLevel reads a -log-level value.
func parseLevel(s string) (slog.Level, error) {
	var l slog.Level
	if err := l.UnmarshalText([]byte(strings.TrimSpace(s))); err != nil {
		return slog.LevelInfo, fmt.Errorf("-log-level %q: want debug, info, warn or error", s)
	}
	return l, nil
}

// newLogger builds the server's logger from the flags: slog's text format
// (logfmt, which Alloy parses), counted by level (opensro_log_messages_total),
// to stdout or the rotating -log-file. It is also slog's default, so the
// packages that log through slog.Info and the standard log package land in
// the same place and format. closeLog closes the file (a no-op for stdout).
func newLogger(f observeFlags) (logger *slog.Logger, closeLog func(), err error) {
	level, err := parseLevel(*f.logLevel)
	if err != nil {
		return nil, nil, err
	}
	var w io.Writer = os.Stdout
	closeLog = func() {}
	if *f.logFile != "" {
		lf, err := logfile.Open(*f.logFile, int64(*f.logMaxMB)<<20, *f.logKeep, *f.logCompress)
		if err != nil {
			return nil, nil, fmt.Errorf("-log-file %s: %w", *f.logFile, err)
		}
		w = lf
		closeLog = func() { _ = lf.Close() }
	}
	h := slog.NewTextHandler(w, &slog.HandlerOptions{Level: level})
	logger = slog.New(metrics.NewCountingHandler(h))
	slog.SetDefault(logger)
	metrics.SetBuildInfo(version)
	return logger, closeLog, nil
}
