package metrics

import (
	"context"
	"log/slog"

	"github.com/prometheus/client_golang/prometheus"
)

var levelCounters = map[slog.Level]prometheus.Counter{
	slog.LevelDebug: logLines.WithLabelValues("DEBUG"),
	slog.LevelInfo:  logLines.WithLabelValues("INFO"),
	slog.LevelWarn:  logLines.WithLabelValues("WARN"),
	slog.LevelError: logLines.WithLabelValues("ERROR"),
}

// CountingHandler counts every record its inner handler is asked to write
// (opensro_log_messages_total by level), so an error rate can be alerted on
// from Prometheus alone.
type CountingHandler struct{ slog.Handler }

// NewCountingHandler wraps h.
func NewCountingHandler(h slog.Handler) *CountingHandler { return &CountingHandler{h} }

func (h *CountingHandler) Handle(ctx context.Context, r slog.Record) error {
	lvl := slog.LevelError
	switch {
	case r.Level < slog.LevelInfo:
		lvl = slog.LevelDebug
	case r.Level < slog.LevelWarn:
		lvl = slog.LevelInfo
	case r.Level < slog.LevelError:
		lvl = slog.LevelWarn
	}
	levelCounters[lvl].Inc()
	return h.Handler.Handle(ctx, r)
}

func (h *CountingHandler) WithAttrs(as []slog.Attr) slog.Handler {
	return &CountingHandler{h.Handler.WithAttrs(as)}
}

func (h *CountingHandler) WithGroup(name string) slog.Handler {
	return &CountingHandler{h.Handler.WithGroup(name)}
}
