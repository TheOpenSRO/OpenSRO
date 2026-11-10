package session

import (
	"log/slog"
	"sync"
	"time"
)

// Round 878 (OURS): every move the server corrects, refuses or cuts short is
// logged at INFO -- the rule, where the server has the character and what the
// client asked -- so a player's "I got teleported back" has its cause in
// prod's log (prod logs nothing about movement at INFO otherwise, and round
// 878's user report had only the client's side). The 0xB023 a client hears for
// itself is always one of: a correction (a refused claim), a wall the server's
// own walk met ("move: stopped at a wall"), a run past its limit, or a stop
// the server made for a state, a sit, the Up key or /unstuck; the first three
// are logged here.
//
// A session can send these at click rate, so each (character, rule) logs at
// most once per moveLogEvery; the next line it logs counts what it kept back.
const moveLogEvery = time.Second

type moveLogKey struct {
	characterID int64
	rule        string
}

type moveLogEntry struct {
	at         time.Time
	suppressed int
}

var (
	moveLogMu   sync.Mutex
	moveLogSeen = map[moveLogKey]*moveLogEntry{}
	// moveLogNow is the limiter's clock (tests).
	moveLogNow = time.Now
)

// moveLog writes msg at INFO for characterID under rule, with args (slog
// pairs), unless the same character's same rule logged within moveLogEvery.
func moveLog(msg string, characterID int64, rule string, args ...any) {
	now := moveLogNow()
	k := moveLogKey{characterID, rule}
	moveLogMu.Lock()
	e := moveLogSeen[k]
	if e != nil && now.Sub(e.at) < moveLogEvery {
		e.suppressed++
		moveLogMu.Unlock()
		return
	}
	suppressed := 0
	if e != nil {
		suppressed = e.suppressed
	}
	moveLogSeen[k] = &moveLogEntry{at: now}
	// The map holds one entry per character and rule seen; a sweep keeps it
	// to the recent ones.
	if len(moveLogSeen) > 4096 {
		for key, v := range moveLogSeen {
			if now.Sub(v.at) > time.Minute {
				delete(moveLogSeen, key)
			}
		}
	}
	moveLogMu.Unlock()
	out := append([]any{"character_id", characterID, "rule", rule}, args...)
	if suppressed > 0 {
		out = append(out, "suppressed_since", suppressed)
	}
	slog.Info(msg, out...)
}

// moveRefused logs a 0x7021 the server refused (silently, as retail's handler
// does: no reply on any path, GObjPC::FUN_004b0ea0) and why.
func moveRefused(characterID int64, rule string, args ...any) {
	moveLog("move: refused", characterID, rule, args...)
}
