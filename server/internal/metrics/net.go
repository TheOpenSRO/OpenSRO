package metrics

import (
	"fmt"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// The gateway's families (internal/gateway): every connection, packet and
// byte on every listener (OpenSRO's own and the retail agent's).
var (
	ConnectionsAccepted = factory.counter("gateway_connections_accepted_total",
		"Client TCP connections accepted, every listener.")
	ConnectionsActive = factory.gauge("gateway_connections_active",
		"Client TCP connections open now, every listener (status pings and theme questions included while they last).")
	disconnects = factory.counterVec("gateway_disconnects_total",
		"Sessions ended, by reason: client_closed (EOF), read_error, handler_error, handler_panic, ended (the handler finished it), send_stalled, shutdown, codec_start.",
		"reason")
	sendStalls = factory.counterVec("gateway_send_stalls_total",
		"Sessions given up for their sends, by the bound they hit: timeout, budget or queue (gateway.SendTimeout, SendBlockBudget, SendQueueLimit).",
		"reason")
	bytesTotal = factory.counterVec("gateway_bytes_total",
		"Bytes read from (in) and written to (out) client sockets.", "dir")
	packets = factory.counterVec("gateway_packets_total",
		"Packets read (in) and queued (out), by opcode (the hex of an opcode the server's code names, or \"other\") and its group (login, world, combat, item, economy, guild, social, quest, cos, lobby, gm, other): group=\"guild\" dir=\"in\" is the guild operations requested, and so on.",
		"dir", "opcode", "group")
	handlerSeconds = factory.histogramVec("gateway_handler_seconds",
		"Time the handler chain took over one inbound packet, by opcode group (the source file's area: login, world, combat, item, ...).",
		LatencyBuckets, "group")
	handlerErrors = factory.counterVec("gateway_handler_errors_total",
		"Inbound packets whose handler returned an error (the session closes) or panicked, by opcode group.",
		"group", "kind")
	broadcasts = factory.counter("world_broadcasts_total",
		"Broadcast frames encoded once for many recipients (gateway.NewFrame: area-of-interest spawns, moves, casts, ...).")
	broadcastDeliveries = factory.counter("world_broadcast_deliveries_total",
		"Shared broadcast frames queued to a recipient session (gateway.SendFrames); divided by world_broadcasts_total it is the mean fan-out.")
)

// Disconnect reasons.
const (
	DisconnectClientClosed = "client_closed"
	DisconnectReadError    = "read_error"
	DisconnectHandlerError = "handler_error"
	DisconnectPanic        = "handler_panic"
	DisconnectEnded        = "ended"
	DisconnectStalled      = "send_stalled"
	DisconnectShutdown     = "shutdown"
	DisconnectCodecStart   = "codec_start"
)

var (
	bytesIn  = bytesTotal.WithLabelValues("in")
	bytesOut = bytesTotal.WithLabelValues("out")
)

// Disconnect counts one ended session.
func Disconnect(reason string) { disconnects.WithLabelValues(reason).Inc() }

// SendStall counts one session given up for its sends.
func SendStall(reason string) { sendStalls.WithLabelValues(reason).Inc() }

// BytesIn and BytesOut count socket bytes.
func BytesIn(n int) {
	if n > 0 {
		bytesIn.Add(float64(n))
	}
}

func BytesOut(n int) {
	if n > 0 {
		bytesOut.Add(float64(n))
	}
}

// Broadcast counts one frame encoded for many; BroadcastDeliveries n of them
// queued to one session.
func Broadcast()                { broadcasts.Inc() }
func BroadcastDeliveries(n int) { broadcastDeliveries.Add(float64(n)) }

// opcodeTable resolves an opcode to its counters without a map lookup or a
// label hash on the hot path: each known opcode's children are created on
// first use and kept.
type opcodeCounters struct {
	in, out atomic.Pointer[prometheus.Counter]
}

var (
	opTable      [1 << 16]*opcodeCounters
	otherIn      = packets.WithLabelValues("in", "other", "other")
	otherOut     = packets.WithLabelValues("out", "other", "other")
	groupSeconds = map[string]prometheus.Observer{}
	groupErrors  = map[string]prometheus.Counter{}
	groupPanics  = map[string]prometheus.Counter{}
	opGroup      [1 << 16]string
)

func init() {
	for op, g := range knownOpcodes {
		opTable[op] = &opcodeCounters{}
		opGroup[op] = g
		if _, ok := groupSeconds[g]; !ok {
			groupSeconds[g] = handlerSeconds.WithLabelValues(g)
			groupErrors[g] = handlerErrors.WithLabelValues(g, "error")
			groupPanics[g] = handlerErrors.WithLabelValues(g, "panic")
		}
	}
	groupSeconds["other"] = handlerSeconds.WithLabelValues("other")
	groupErrors["other"] = handlerErrors.WithLabelValues("other", "error")
	groupPanics["other"] = handlerErrors.WithLabelValues("other", "panic")
}

// OpcodeLabel is the opcode label the families use for op: "0x7021" for a
// known opcode, "other" for any the code does not name.
func OpcodeLabel(op uint16) string {
	if opTable[op] == nil {
		return "other"
	}
	return fmt.Sprintf("0x%04x", op)
}

// OpcodeGroup is op's handler group ("other" when unknown).
func OpcodeGroup(op uint16) string {
	if g := opGroup[op]; g != "" {
		return g
	}
	return "other"
}

func opCounter(op uint16, out bool) prometheus.Counter {
	t := opTable[op]
	if t == nil {
		if out {
			return otherOut
		}
		return otherIn
	}
	slot, dir := &t.in, "in"
	if out {
		slot, dir = &t.out, "out"
	}
	if c := slot.Load(); c != nil {
		return *c
	}
	c := packets.WithLabelValues(dir, OpcodeLabel(op), opGroup[op])
	slot.Store(&c)
	return c
}

// PacketIn counts one packet read; PacketOut one queued.
func PacketIn(op uint16)  { opCounter(op, false).Inc() }
func PacketOut(op uint16) { opCounter(op, true).Inc() }

// HandlerDone observes one handler run over op that started at start, and
// counts its failure: err != nil and not a clean end, or a panic.
func HandlerDone(op uint16, start time.Time, failed, panicked bool) {
	g := OpcodeGroup(op)
	groupSeconds[g].Observe(time.Since(start).Seconds())
	switch {
	case panicked:
		groupPanics[g].Inc()
	case failed:
		groupErrors[g].Inc()
	}
}
