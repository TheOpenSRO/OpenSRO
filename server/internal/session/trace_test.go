package session

import (
	"bufio"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 832: 0xB074 is {u8 result, u8 depth} plus a u16 code for result 3
// (SendActionResult_B074 0x4ad270; the client's 0x880b60 reads the same).
func TestActionResultLayout(t *testing.T) {
	cases := []struct {
		a    ActionResult
		want []byte
	}{
		{ActionResult{Result: ActionResultStarted, Depth: 1}, []byte{1, 1}},
		{ActionResult{Result: ActionResultEnded}, []byte{2, 0}},
		{ActionResult{Result: ActionResultError, Code: ActionErrRefused}, []byte{3, 0, 0x04, 0x40}},
	}
	for _, c := range cases {
		got := c.a.Encode()
		if string(got) != string(c.want) {
			t.Errorf("%+v encodes % x, want % x", c.a, got, c.want)
		}
		back, ok := DecodeActionResult(got)
		if !ok || *back != c.a {
			t.Errorf("round trip of %+v: %+v ok %v", c.a, back, ok)
		}
	}
	if got := encodeTraceRequest(0x01020304); string(got) != string([]byte{1, 3, 1, 4, 3, 2, 1}) {
		t.Errorf("trace request % x, want 01 03 01 04 03 02 01 (0x793b00 case 1003)", got)
	}
	if OpCharacterActionRequest != 0x7074 || OpCharacterActionResponse != 0xB074 {
		t.Error("the opcodes are the retail 0x7074 / 0xB074")
	}
}

// FUN_00430ce0: the same world kind; in the field each region byte within one.
func TestTraceRegionsNear(t *testing.T) {
	cases := []struct {
		a, b uint16
		want bool
	}{
		{0x61a8, 0x61a8, true},
		{0x61a8, 0x62a9, true},
		{0x61a8, 0x60a7, true},
		{0x61a8, 0x63a8, false},
		{0x61a8, 0x61aa, false},
		{0x61a8, 0x80a8, false},
		{0x8001, 0x80ff, true},
	}
	for _, c := range cases {
		if got := regionsNear(c.a, c.b); got != c.want {
			t.Errorf("regionsNear(%#04x, %#04x) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

// actionResults reads conn until `n` 0xB074s arrived or `within` passed,
// stepping over anything else.
func actionResults(t *testing.T, conn net.Conn, r *bufio.Reader, n int, within time.Duration) []ActionResult {
	t.Helper()
	var out []ActionResult
	end := time.Now().Add(within)
	for len(out) < n && time.Now().Before(end) {
		conn.SetReadDeadline(end)
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			break
		}
		if p.Opcode != OpCharacterActionResponse {
			continue
		}
		a, ok := DecodeActionResult(p.Data)
		if !ok {
			t.Fatalf("malformed 0xB074 % x", p.Data)
		}
		out = append(out, *a)
	}
	return out
}

func traceFixture(t *testing.T) *deadWorldFixture {
	t.Helper()
	return startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return gateway.Chain(ActionHandler(hub), MotionHandler(hub))
	})
}

func expectResults(t *testing.T, what string, got []ActionResult, want ...ActionResult) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: got %+v, want %+v", what, got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%s: got %+v, want %+v", what, got, want)
		}
	}
}

var (
	started = ActionResult{Result: ActionResultStarted, Depth: 1}
	ended   = ActionResult{Result: ActionResultEnded}
)

// Aria traces Bram: started, and it runs (no end while he lives in reach);
// his death ends it on the next tick (PrepareAction's life state).
func TestTraceRunsUntilTheTargetDies(t *testing.T) {
	f := traceFixture(t)
	f.send(t, f.connA, OpCharacterActionRequest, encodeTraceRequest(uint32(f.bram)))
	expectResults(t, "the trace", actionResults(t, f.connA, f.rA, 1, time.Second), started)
	if got := actionResults(t, f.connA, f.rA, 1, 300*time.Millisecond); len(got) != 0 {
		t.Fatalf("a trace of a living player in reach ended: %+v", got)
	}
	if target, ok := traces.running(f.aria); !ok || target != f.bram {
		t.Fatalf("running trace %d %v, want Bram", target, ok)
	}
	f.kill(t, f.bram, time.Now())
	expectResults(t, "after the target's death", actionResults(t, f.connA, f.rA, 1, time.Second), ended)
	if _, ok := traces.running(f.aria); ok {
		t.Error("the trace still runs")
	}
}

// No one by that id (OpenSRO's client sends 0 for a selection that is not a
// player): started, then ended on the first tick -- retail's IsPC refusal.
func TestTraceOfNoOneEndsAtOnce(t *testing.T) {
	f := traceFixture(t)
	f.send(t, f.connA, OpCharacterActionRequest, encodeTraceRequest(0))
	expectResults(t, "a trace of id 0", actionResults(t, f.connA, f.rA, 2, time.Second), started, ended)
}

// The cancel: with a trace running 0x4ad320 answers {2, 0} and the handler
// again; with none, the handler's alone.
func TestTraceCancel(t *testing.T) {
	f := traceFixture(t)
	f.send(t, f.connA, OpCharacterActionRequest, encodeTraceRequest(uint32(f.bram)))
	expectResults(t, "the trace", actionResults(t, f.connA, f.rA, 1, time.Second), started)
	f.send(t, f.connA, OpCharacterActionRequest, []byte{actionCancel})
	expectResults(t, "the cancel", actionResults(t, f.connA, f.rA, 3, 500*time.Millisecond), ended, ended)
	f.send(t, f.connA, OpCharacterActionRequest, []byte{actionCancel})
	expectResults(t, "a cancel with nothing running", actionResults(t, f.connA, f.rA, 2, 500*time.Millisecond), ended)
}

// Sitting down ends it (FUN_004b1480 -> 0x4ad300(4) -> 0x4ad320(1)).
func TestTraceEndsOnSit(t *testing.T) {
	f := traceFixture(t)
	f.send(t, f.connA, OpCharacterActionRequest, encodeTraceRequest(uint32(f.bram)))
	expectResults(t, "the trace", actionResults(t, f.connA, f.rA, 1, time.Second), started)
	f.send(t, f.connA, OpMotionRequest, []byte{MotionSit})
	expectResults(t, "the sit", actionResults(t, f.connA, f.rA, 1, time.Second), ended)
}

// A new action drops it silently (Push), a move does not end it, and a kind
// other than the trace is refused 0x4004.
func TestTraceDropAndOtherKinds(t *testing.T) {
	f := traceFixture(t)
	f.send(t, f.connA, OpCharacterActionRequest, encodeTraceRequest(uint32(f.bram)))
	expectResults(t, "the trace", actionResults(t, f.connA, f.rA, 1, time.Second), started)
	moveCancelsActions(f.aria)
	if _, ok := traces.running(f.aria); !ok {
		t.Fatal("a move ended the trace")
	}
	dropTraceFor(f.aria)
	if _, ok := traces.running(f.aria); ok {
		t.Fatal("a new action left the trace running")
	}
	if got := actionResults(t, f.connA, f.rA, 1, 300*time.Millisecond); len(got) != 0 {
		t.Fatalf("Push's drop answered %+v; it is silent", got)
	}
	f.send(t, f.connA, OpCharacterActionRequest, []byte{actionStart, 1, 1, 0, 0, 0, 0})
	expectResults(t, "an attack on 0x7074", actionResults(t, f.connA, f.rA, 1, time.Second),
		ActionResult{Result: ActionResultError, Code: ActionErrRefused})
}

// encodeTraceRequest is the client's 0x7074 trace: {1, 3, 1, u32 target}
// (READ, sro_client.exe 0x793b00 case 1003).
func encodeTraceRequest(target uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{actionStart, actionTrace, 1}, target)
}
