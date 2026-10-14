// Package worldclock is the game's clock: the in-game day, hour, minute and
// second the server tells a client at world entry (0x3020) and when an
// operator sets the hour (0x3027), and that the client turns into the sky's
// time of day (round 786, docs/protocol/game_clock.md).
//
// READ (SR_GameServer.exe, the box's decompile and objdump):
//
//   - The timer lives at +0x10 of the CMainProcess singleton (DAT_00d6a8e8):
//     [0] the rate, [1] the GetTickCount it started at, [3] the tick
//     counter's wraps, [6..7] the base in game seconds; the update writes the
//     day (u16) at +0x10, the hour at +0x12 and the minute at +0x13 of the
//     timer (singleton +0x20, +0x22, +0x23).
//   - CMainProcess::InitializeGame starts it through FUN_00427660 (0x427660):
//     rate 30 (`mov [esi],0x1e`, 0x427677), base 0 -- day 0, 00:00:00 at the
//     server's start.
//   - Every tick (FUN_004140b0 -> FUN_00427720, 0x427720) it computes
//     elapsed_ms / (rate * 1000 / 1440) + base, in integers, and splits the
//     result by 60, 3600 (mod 24) and 86400 into the second, the hour and the
//     day. 30 * 1000 / 1440 truncates to 20 (the magic 0x6c16c16d sequence,
//     evaluated: 20), so ONE GAME SECOND IS 20 REAL MILLISECONDS and a game
//     day is 86400 x 20 ms = 1728 s = 28 min 48 s of real time.
//   - The operator's "set hour" (FUN_004154d0 case 10 -> FUN_00412be0,
//     0x412be0) takes a byte, clamps it to 23, keeps the day and the minute,
//     re-bases the timer there (FUN_00427690: rate 30 again, second 0) and
//     broadcasts 0x3027 to the world (FUN_00530d60).
//
// The client's copy of the timer (sro_client.exe FUN_008b00f0 /
// FUN_008b01b0) is the same code with the same rate (0x8a6dc0 stores 0x1e
// before InitTimer), so both ends advance identically from the minute the
// server names.
package worldclock

import (
	"fmt"
	"sync"
	"time"
)

// RealMinutesPerDay is the timer's rate, READ in both binaries (0x1e).
const RealMinutesPerDay = 30

// MsPerGameSecond is the timer's divisor: RealMinutesPerDay * 1000 / 1440 in
// integer arithmetic, as both binaries compute it (READ; 20).
const MsPerGameSecond = RealMinutesPerDay * 1000 / 1440

// SecondsPerDay is a game day in game seconds.
const SecondsPerDay = 86400

// RealDay is a game day in real time: 86400 x 20 ms (MEASURED from the READ
// arithmetic: 28 min 48 s, not the 30 minutes the rate names).
const RealDay = time.Duration(SecondsPerDay*MsPerGameSecond) * time.Millisecond

// Time is the clock's reading, as the timer splits it.
type Time struct {
	Day    uint16
	Hour   uint8
	Minute uint8
	Second uint8
}

func (t Time) String() string {
	return fmt.Sprintf("day %d %02d:%02d:%02d", t.Day, t.Hour, t.Minute, t.Second)
}

// Clock is one server's game clock. Safe for concurrent use.
type Clock struct {
	mu    sync.Mutex
	start time.Time
	base  int64 // game seconds at start
}

// New starts a clock at start reading day/hour/minute:00. Retail starts at
// day 0, 00:00 (READ, 0x427660); a different start is the -world-clock-start
// flag's (OURS).
func New(start time.Time, day, hour, minute int) *Clock {
	return &Clock{start: start, base: baseSeconds(day, hour, minute, 0)}
}

func baseSeconds(day, hour, minute, second int) int64 {
	return ((int64(day)*24+int64(hour))*60+int64(minute))*60 + int64(second)
}

// Seconds is the game seconds since day 0 at now: whole 20 ms steps since the
// start, plus the base (READ: the integer division).
func (c *Clock) Seconds(now time.Time) int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.secondsLocked(now)
}

func (c *Clock) secondsLocked(now time.Time) int64 {
	elapsed := now.Sub(c.start).Milliseconds()
	if elapsed < 0 {
		elapsed = 0
	}
	return c.base + elapsed/MsPerGameSecond
}

// At is the clock's reading at now.
func (c *Clock) At(now time.Time) Time {
	return Split(c.Seconds(now))
}

// Split divides game seconds as the timer does: second = s % 60, minute =
// s / 60 % 60, hour = s / 3600 % 24, day = s / 86400 (a u16).
func Split(s int64) Time {
	return Time{
		Day:    uint16(s / SecondsPerDay),
		Hour:   uint8(s / 3600 % 24),
		Minute: uint8(s / 60 % 60),
		Second: uint8(s % 60),
	}
}

// SetHour is the operator's set-hour (READ, 0x412be0): hour above 22 becomes
// 23, the day and the minute are kept, the second goes to 0 and the clock
// runs on from there. Returns the new reading.
func (c *Clock) SetHour(now time.Time, hour int) Time {
	if hour > 22 {
		hour = 23
	}
	if hour < 0 {
		hour = 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	cur := Split(c.secondsLocked(now))
	c.start = now
	c.base = baseSeconds(int(cur.Day), hour, int(cur.Minute), 0)
	return Split(c.base)
}

// ParseStart reads -world-clock-start's "HH:MM" (OURS).
func ParseStart(s string) (hour, minute int, err error) {
	if s == "" {
		return 0, 0, nil
	}
	var h, m int
	if _, err := fmt.Sscanf(s, "%d:%d", &h, &m); err != nil {
		return 0, 0, fmt.Errorf("worldclock: %q is not HH:MM", s)
	}
	if h < 0 || h > 23 || m < 0 || m > 59 {
		return 0, 0, fmt.Errorf("worldclock: %q is out of range (00:00..23:59)", s)
	}
	return h, m, nil
}
