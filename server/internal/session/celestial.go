package session

import (
	"encoding/binary"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldclock"
)

// The game clock's two messages (round 786, docs/protocol/game_clock.md).
// READ from both binaries:
//
//   - 0x3020, built by SR_GameServer's FUN_004e3eb0 (0x4e3eb0) and sent once
//     from CMainProcess::EnterGame (0x403020, after the character data): the
//     character's unique id (u32, the object's +0x8), then the clock's day
//     (u16), hour (u8) and minute (u8) from the timer at the CMainProcess
//     singleton's +0x20..+0x23. 8 bytes. The client's handler, FUN_008a6dc0
//     (registered for 0x3020 in FUN_0086fbb0), reads the same four fields,
//     hands the id to the player object (vtable +0x48) and starts its own
//     timer there: `Fun_GetCfgGame()->m_LocalTime.InitTimer(pM->dwRealTime,
//     pM->m_wDay, pM->m_byHour, pM->m_byMin, 0)` -- the assert text at
//     NetProcessInObject.cpp line 0x46e names the fields -- with dwRealTime
//     set to 0x1e just before.
//   - 0x3027, built by FUN_00530d60 through FUN_004f8240 (day u16, hour u8,
//     minute u8: 4 bytes) and broadcast to the world when an operator sets the
//     hour (FUN_004154d0 case 10 -> FUN_00412be0). Nothing else builds it:
//     the server does not re-send the clock periodically, because both ends
//     run the same integer timer from the same minute. The client's handler
//     FUN_008a6e80 (registered for 0x3027) re-starts its timer with the three
//     fields unless its console has locked the time (CGInterface +0x7cd, the
//     "TimeOff" command).
//
// 0x34be (the server's wall-clock time every 600 s, game_clock.md's first
// section) is a separate clock that feeds the client's ServerTime display,
// not the sky; it is not sent here.
const (
	OpCelestialPosition uint16 = 0x3020
	OpCelestialUpdate   uint16 = 0x3027
)

// gameClock is the server's clock. Retail starts it at day 0, 00:00 when the
// server starts (READ, 0x427660); cmd/server replaces it with one started at
// -world-clock-start (SetGameClock). The package default, for tests and tools,
// starts when the package loads.
var gameClock atomic.Pointer[worldclock.Clock]

func init() {
	gameClock.Store(worldclock.New(time.Now(), 0, 0, 0))
	clockAtEntry.Store(true)
}

// clockAtEntry is -world-clock (default on): 0x3020 at every world entry.
// Off is the kill switch -- the client then keeps the fixed midday it drew
// before round 786.
var clockAtEntry atomic.Bool

// SetClockAtEntry sets -world-clock.
func SetClockAtEntry(on bool) { clockAtEntry.Store(on) }

// SetGameClock installs the server's game clock.
func SetGameClock(c *worldclock.Clock) {
	if c != nil {
		gameClock.Store(c)
	}
}

// GameClock is the server's game clock.
func GameClock() *worldclock.Clock { return gameClock.Load() }

// EncodeCelestialPosition is 0x3020's payload: u32 uid, u16 day, u8 hour,
// u8 minute (READ, 0x4e3eb0).
func EncodeCelestialPosition(uid uint32, t worldclock.Time) []byte {
	out := binary.LittleEndian.AppendUint32(make([]byte, 0, 8), uid)
	out = binary.LittleEndian.AppendUint16(out, t.Day)
	return append(out, t.Hour, t.Minute)
}

// EncodeCelestialUpdate is 0x3027's payload: u16 day, u8 hour, u8 minute
// (READ, 0x4f8240).
func EncodeCelestialUpdate(t worldclock.Time) []byte {
	out := binary.LittleEndian.AppendUint16(make([]byte, 0, 4), t.Day)
	return append(out, t.Hour, t.Minute)
}

// sendCelestialPosition tells an entering character the game clock (0x3020).
// The uid is the low 32 bits of the character id, as every retail message
// OpenSRO sends (round 710).
func sendCelestialPosition(sess *gateway.Session, characterID int64, now time.Time) error {
	if !clockAtEntry.Load() {
		return nil
	}
	t := GameClock().At(now)
	return sess.Send(&proto.Packet{Opcode: OpCelestialPosition, Data: EncodeCelestialPosition(uint32(characterID), t)})
}

// SetWorldHour is the operator's set-hour (READ, 0x412be0 -> 0x530d60): the
// clock re-based at hour (the day and the minute kept), then 0x3027 to every
// character in the world. Returns the new reading and how many were told.
func SetWorldHour(hub *world.Hub, hour int, now time.Time) (worldclock.Time, int) {
	t := GameClock().SetHour(now, hour)
	return t, broadcastCelestialUpdate(hub, t)
}

func broadcastCelestialUpdate(hub *world.Hub, t worldclock.Time) int {
	if hub == nil {
		return 0
	}
	data := EncodeCelestialUpdate(t)
	n := 0
	for _, e := range hub.AllEntities() {
		if e.Session == nil {
			continue
		}
		if e.Session.Send(&proto.Packet{Opcode: OpCelestialUpdate, Data: data}) == nil {
			n++
		}
	}
	return n
}

// gmClock is /hour's hook (gm.ClockControl): SetWorldHour now.
type gmClock struct{ hub *world.Hub }

func (g gmClock) SetHour(hour int) (day, newHour, minute, told int) {
	t, n := SetWorldHour(g.hub, hour, time.Now())
	return int(t.Day), int(t.Hour), int(t.Minute), n
}
