package session

// Trace (round 832): one player following another. The request, its answers
// and its end are the retail ones; the walking is the client's.
//
// READ, SR_GameServer.exe (docs/protocol/trace.md has the whole reading):
//
//   - 0x7074 is the character action request. GObjPC::
//     HandleCharacterActionRequest_7074 (0x4acc40): byte 1 starts, 2
//     cancels, 3 clears and then starts (0x4ad320(0) at 0x4acd23); the next
//     byte is the kind, refused 0x4004 above 5; kind 3 is the trace, its
//     context a target-type byte (1) and the target's u32 id.
//   - CGCharAutoCommandActor::Push (0x4ad630) takes the action into an empty
//     queue, and drops a front trace for any new action (0x4b03f0 stops its
//     walk, 0x4af4a0 empties the queue, no 0xB074). The reply is 0xB074
//     {u8 result, u8 queue depth} plus a u16 code for result 3
//     (SendActionResult_B074, 0x4ad270): result 1 when it was taken.
//   - The actor ticks every 30 ms (GObjPC::Update, 0x4ad7a0). The trace's
//     handler (0x4ae3d0) never finishes on its own; each tick runs
//     PrepareAction (0x4ad030 case 3): the target resolves, IsPC (IGObj slot
//     7), GetLifeState (slot 62) is neither 2 nor 3, and FUN_00430ce0: the
//     same world kind, each field region byte within one. A failed test
//     returns 0 and FinishFront (0x4ad390) pops it, stops the walk and sends
//     0xB074 {2, depth}.
//   - The cancel (byte 2): 0x4ad320(1) empties the queue -- 0xB074 {2, 0}
//     when it held an action -- and stops the walk; the handler then sends
//     0xB074 {2, 0} itself. A cancel with a trace running answers twice.
//   - The client (sro_client.exe 0x880b60) keeps only the depth byte and
//     prints a system line for result 3; 0x4004 is silent.
//
// OURS, disclosed:
//
//   - The server's walker (CGCharAutoNavigator, 0x4b0490) posts 0x7021 moves
//     into the player's own queue; OpenSRO's server does not move players
//     (keepup.go), so the client runs the same walker (client
//     world/trace_follow.gd) and sends the moves. Those moves do not end the
//     trace: moveCancelsActions is cancelActions without it. The retail
//     client ends it with a cancel (byte 2) before a click walk, as this
//     client does.
//   - Only the trace is served on 0x7074: OpenSRO's attacks, skills and
//     pick-ups have their own requests. Another kind is refused 0x4004, as a
//     duplicate is. Those requests drop a running trace silently, as Push
//     does (dropTraceFor).
//   - Push queues a trace behind an attack in its execute or keep-up phase
//     (depth 2) and the keep-up then ends itself; here the auto-attack run
//     ends at once (cancelActions' other parts) and the depth is 1.
//   - OpenSRO's monster ids overlap its character ids, so the client sends 0
//     for a selection that is not a player; it resolves to no one, and the
//     trace starts and ends at once -- what retail's IsPC test does.
//   - The walker refuses to start under a `stns` stun (pc+0xc44); the client
//     walks, and this server does not end the trace for it.
//   - A dead tracer's request is dropped, as every OpenSRO handler drops a
//     dead character's (the engine's 0x7074 handler tests no life state).

import (
	"context"
	"encoding/binary"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	// OpCharacterActionRequest is the retail 0x7074.
	OpCharacterActionRequest uint16 = 0x7074
	// OpCharacterActionResponse is the retail 0xB074.
	OpCharacterActionResponse uint16 = 0xB074
)

// The 0x7074 command bytes and the trace's kind (READ, 0x4acc40).
const (
	actionStart   byte = 1
	actionCancel  byte = 2
	actionRestart byte = 3
	actionKindMax byte = 5
	actionTrace   byte = 3
)

// The 0xB074 results (READ, 0x4ad270 and its callers).
const (
	ActionResultStarted byte = 1
	ActionResultEnded   byte = 2
	ActionResultError   byte = 3
)

// ActionErrRefused is the code the handler answers a refused request with
// (0x4004; the client shows no line for it, 0x7baf0d).
const ActionErrRefused uint16 = 0x4004

// queueClearingStates are the abnormal bits whose appliers empty a PC's
// action queue through slot 348 (READ: freezing 0x1, AbnormalState_Apply00
// 0x4a4570; sleep 0x40, _Apply06 0x4a49f0; stun 0x4000, _Apply14 0x4a4ec0).
// The other move-blocking bit, 0x80, has no such call.
const queueClearingStates uint32 = 0x1 | 0x40 | 0x4000

// traceTick is the actor's period (READ, 0x4ad7a0: `< 0x1e` ms returns).
const traceTick = 30 * time.Millisecond

// ActionResult is the 0xB074 payload.
type ActionResult struct {
	Result byte
	Depth  byte
	Code   uint16 // on the wire for ActionResultError only
}

func (a *ActionResult) Encode() []byte {
	out := []byte{a.Result, a.Depth}
	if a.Result == ActionResultError {
		out = binary.LittleEndian.AppendUint16(out, a.Code)
	}
	return out
}

// DecodeActionResult decodes a 0xB074; false when it is short.
func DecodeActionResult(data []byte) (*ActionResult, bool) {
	if len(data) < 2 {
		return nil, false
	}
	a := &ActionResult{Result: data[0], Depth: data[1]}
	if a.Result == ActionResultError {
		if len(data) < 4 {
			return nil, false
		}
		a.Code = binary.LittleEndian.Uint16(data[2:4])
	}
	return a, true
}

func sendActionResult(sess *gateway.Session, result, depth byte, code uint16) {
	if sess == nil {
		return
	}
	sendToPeer(sess, &proto.Packet{Opcode: OpCharacterActionResponse,
		Data: (&ActionResult{Result: result, Depth: depth, Code: code}).Encode()})
}

type traceRun struct {
	target int64
	sess   *gateway.Session
	done   chan struct{}
}

type traceBook struct {
	mu   sync.Mutex
	runs map[int64]*traceRun
}

var traces = &traceBook{runs: map[int64]*traceRun{}}

// take removes the character's trace; nil when it has none.
func (b *traceBook) take(characterID int64) *traceRun {
	b.mu.Lock()
	defer b.mu.Unlock()
	r := b.runs[characterID]
	if r != nil {
		delete(b.runs, characterID)
		close(r.done)
	}
	return r
}

// end ends the character's trace as 0x4ad320 empties the queue: 0xB074
// {2, 0} when one was running. Reports whether one was.
func (b *traceBook) end(characterID int64) bool {
	r := b.take(characterID)
	if r == nil {
		return false
	}
	sendActionResult(r.sess, ActionResultEnded, 0, 0)
	return true
}

// running reports the character's trace target.
func (b *traceBook) running(characterID int64) (int64, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	r := b.runs[characterID]
	if r == nil {
		return 0, false
	}
	return r.target, true
}

// dropTraceFor is Push's drop of a front trace for a new action: silent.
func dropTraceFor(characterID int64) {
	traces.take(characterID)
}

// traceTargetValid is PrepareAction's case 3 (READ, 0x4ad030) on OpenSRO's
// state: the target is a character in the world, not dead, and within the
// tracer's 3 x 3 regions (FUN_00430ce0).
func traceTargetValid(hub *world.Hub, tracer world.Entity, target int64) bool {
	t, ok := hub.EntityByCharacterID(target)
	if !ok || t.Life == world.LifeDead {
		return false
	}
	a, _, _ := regionLocalOf(tracer.Zone, tracer.Pos)
	b, _, _ := regionLocalOf(t.Zone, t.Pos)
	return regionsNear(a, b)
}

// regionsNear is FUN_00430ce0 (READ): the same world kind (bit 15 of the
// region word), and in the field each region byte within one.
func regionsNear(a, b uint16) bool {
	if a>>15 != b>>15 {
		return false
	}
	if a&0x8000 != 0 {
		return true
	}
	near := func(x, y uint16) bool {
		d := int(x) - int(y)
		return d > -2 && d < 2
	}
	return near(a&0xff, b&0xff) && near(a>>8&0xff, b>>8&0xff)
}

// tick runs the trace's PrepareAction every traceTick until it fails or the
// trace is taken away.
func (b *traceBook) tick(hub *world.Hub, characterID int64, r *traceRun) {
	t := time.NewTicker(traceTick)
	defer t.Stop()
	for {
		select {
		case <-r.done:
			return
		case <-t.C:
		}
		tracer, ok := hub.EntityByCharacterID(characterID)
		if ok && tracer.Session == r.sess && traceTargetValid(hub, tracer, r.target) {
			continue
		}
		b.mu.Lock()
		if b.runs[characterID] != r {
			b.mu.Unlock()
			return
		}
		delete(b.runs, characterID)
		close(r.done)
		b.mu.Unlock()
		// FinishFront: popped, the walk stopped, 0xB074 {2, depth 0}.
		if ok && tracer.Session == r.sess {
			sendActionResult(r.sess, ActionResultEnded, 0, 0)
		}
		return
	}
}

// ActionHandler answers 0x7074 (see the header).
func ActionHandler(hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		if p.Opcode != OpCharacterActionRequest || hub == nil || len(p.Data) < 1 {
			return nil
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok || e.Life != world.LifeAlive {
			return nil
		}
		// Round 860 (scrollhold.go, READ): the scroll state 1 refuses every
		// 0x7074 -- s:0x4ecbc0 runs the handler with its refused flag, which
		// answers {3, 0x4004} (0x4acc40).
		if scrollHolds(sess) {
			sendActionResult(sess, ActionResultError, 0, ActionErrRefused)
			return nil
		}
		switch p.Data[0] {
		case actionCancel:
			traces.end(e.CharacterID)
			sendActionResult(sess, ActionResultEnded, 0, 0)
			return nil
		case actionRestart:
			traces.end(e.CharacterID)
		}
		if len(p.Data) < 2 {
			return nil
		}
		kind := p.Data[1]
		if kind > actionKindMax || kind != actionTrace {
			sendActionResult(sess, ActionResultError, 0, ActionErrRefused)
			return nil
		}
		if len(p.Data) < 7 {
			return nil
		}
		target := int64(binary.LittleEndian.Uint32(p.Data[3:7]))
		// Push: a front trace is dropped for the new one; the character's
		// other actions end (see the header).
		dropTraceFor(e.CharacterID)
		moveCancelsActions(e.CharacterID)
		r := &traceRun{target: target, sess: sess, done: make(chan struct{})}
		traces.mu.Lock()
		traces.runs[e.CharacterID] = r
		traces.mu.Unlock()
		sendActionResult(sess, ActionResultStarted, 1, 0)
		go traces.tick(hub, e.CharacterID, r)
		return nil
	}
}
