package session

// Round 786 (part): the protection after a teleport -- held out of the world
// until the client's loading is done, then body mode 2 for the world's time.
//
// The retail sequence and every rule below are recorded with their addresses
// in docs/protocol/arrival_guard.md; the short form:
//
//   - READ (SR_GameServer.exe): a teleport takes the PC out of the world and
//     the client's 0x3012 (SR_READY_TO_PLAY) puts it back: CGame::EnterWorld
//     (0x417240) -> CGObj::EnterWorld, then CGObjPC::vslot_391 (0x4df9e0)
//     sets body mode 2 for the world's slot-0x70 time (CGameWorld 0x5eb2d0:
//     6.0 s, `.rdata 0xb45b78`; the fortress world 0x600c50: 11.0 s,
//     0xb45bb8) through CGObjChar::SetBodyMode (0x4a9fc0), which broadcasts
//     0x30BF kind 4 value 2.
//   - OURS: the mechanism. OpenSRO's arrival is its own message
//     (OpChangeZoneResult / OpEnterWorldResult) rather than 0x34B5 and the
//     character data, so the hold is the hub's (world.Entity.Held): the
//     character is filed out of every message block until its client sends
//     0x3012; a client that never sends it is closed after retail's 300 s.
//
// Every relocation across a load goes through holdArrival: warpTo (the gate,
// the walk-in portals, the scrolls, the return to the return point, the zone
// change and the GM /goto to a zone), the world entry (enterOwned), and the
// in-zone relocations, which are warps too (the GM /tp and /goto to a monster,
// /unstuck).

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// OpReadyToPlay is the client's loading-done report, retail's 0x3012
// (SR_READY_TO_PLAY: the server's handler Game__EnterWorld -> CGame::
// EnterWorld 0x417240, READ). No payload. OpenSRO's client sends it when its
// loading screen's work is done (World3D._report_ready_to_play).
const OpReadyToPlay uint16 = 0x3012

// arrivalGuardOn is cmd/server's -arrival-guard (ON by default). The test
// suite turns it off in TestMain, as it does -trust-client-positions, so the
// tests from before this round keep their immediate arrival; the round's own
// tests turn it on (arrival786_test.go).
var arrivalGuardOn atomic.Bool

func init() { arrivalGuardOn.Store(true) }

// SetArrivalGuard sets -arrival-guard.
func SetArrivalGuard(on bool) { arrivalGuardOn.Store(on) }

// arrivalHoldTimeout is how long a held character waits for its client's
// 0x3012: retail's CLobby_RemoveStalePlayers (0x437a50, on the main tick
// 0x414140) adds the elapsed time to every entry waiting for its 0x3012
// (state 2) and deletes one past 300.0 s (`.rdata 0xb45c40`, the test at
// 0x4370e0), logging "StalePlayer clear!" -- the character is never put into
// the world (READ). OpenSRO does the same: the session is closed
// (staleArrival), and the disconnect takes the character out. A variable so
// a test can shorten it.
var arrivalHoldTimeout = 300 * time.Second

// ProtectionAfterArrival is the protection's length in OpenSRO's one world:
// CGameWorld's slot 0x70 (0x5eb2d0) returns `.rdata 0xb45b78` = 6.0f (READ).
// The fortress-war world's 11.0 s (CGameWorld_Siege 0x600c50, 0xb45bb8) and a
// data-driven world's own value (CDataDrivenGameWorld 0x608330, +0x5c) are
// not modelled: OpenSRO has neither world.
const ProtectionAfterArrival = 6 * time.Second

// protectionTime is ProtectionAfterArrival, a variable so a test can shorten it.
var protectionTime = ProtectionAfterArrival

// bodyModeInvincible is the body mode the protection broadcasts and a spawn
// record carries while it lasts: CGObjPC::vslot_391's SetBodyMode(2, 0, t, 0)
// (READ, 0x4df9e0).
const bodyModeInvincible byte = 2

// arrivalEntry is one character's arrival: held (waiting for its 0x3012) or
// protected (body mode 2 until `until`).
type arrivalEntry struct {
	sess *gateway.Session
	// arrival is the hub's Arrival number of the held entity: a release for
	// an older arrival (a timer that fired after a second teleport) is
	// dropped.
	arrival uint64
	held    bool
	heldAt  time.Time
	why     string
	// then runs at the release, after the spawns both ways (arrivePlayer).
	then func(world.Entity)
	d    viewDeps
	// timer is the hold's timeout while held, the protection's end after.
	timer *time.Timer
	// until is when the protection ends; zero while held or once ended.
	until time.Time
	// gen numbers protections, so an old end timer stands down.
	gen uint64
}

var arrivals = struct {
	sync.Mutex
	byChar map[int64]*arrivalEntry
}{byChar: map[int64]*arrivalEntry{}}

// arrivalLog is where the hold and the protection report (cmd/server's
// logger). nil logs nothing.
var arrivalLog atomic.Pointer[slog.Logger]

// SetArrivalLogger sets arrivalLog.
func SetArrivalLogger(l *slog.Logger) { arrivalLog.Store(l) }

func arrivalInfo(msg string, args ...any) {
	if l := arrivalLog.Load(); l != nil {
		l.Info(msg, args...)
	}
}

// untouchableRefusal answers an attack, a skill or a duel blow refused for
// the arrival's protection: retail's 0x3020, which the client shows as
// UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_TEMPORARILY (0x7b99f3, READ; the
// client maps this text to it, CombatNet.REFUSED_UNTOUCHABLE). The wording is
// OURS.
const untouchableRefusal = "cannot attack while untouchable"

// attackerUntouchable reports whether characterID may not attack now: held,
// or in body mode 2 (GObjPC::FUN_005291d0, 0x529240, READ). With the guard
// off nothing is.
func attackerUntouchable(hub *world.Hub, characterID int64) bool {
	if !arrivalGuardOn.Load() {
		return false
	}
	return untouchable(hub, characterID, time.Now())
}

// untouchableSet refills into (allocated when nil) the characters held or
// protected at now, for the monster AI's pass (one lock for the whole pass).
func untouchableSet(into map[int64]struct{}, now time.Time) map[int64]struct{} {
	if into == nil {
		into = map[int64]struct{}{}
	}
	clear(into)
	arrivals.Lock()
	for id, e := range arrivals.byChar {
		if e.held || (!e.until.IsZero() && now.Before(e.until)) {
			into[id] = struct{}{}
		}
	}
	arrivals.Unlock()
	return into
}
