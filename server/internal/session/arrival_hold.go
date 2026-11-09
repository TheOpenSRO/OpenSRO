package session

import (
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// holdArrival registers the character just filed held by the hub (EnterHeld,
// ChangeZoneHeld) as waiting for its client's 0x3012: the
// release (releaseArrival) then spawns it both ways (arrivePlayer), runs then
// and starts the protection. via names the path for the log. The hold's
// timeout (arrivalHoldTimeout, OURS) releases it if no 0x3012 comes.
func holdArrival(d viewDeps, held world.Entity, via string, then func(world.Entity)) {
	now := time.Now()
	arrivals.Lock()
	if old := arrivals.byChar[held.CharacterID]; old != nil && old.timer != nil {
		old.timer.Stop()
	}
	e := &arrivalEntry{sess: held.Session, arrival: held.Arrival, held: true, heldAt: now, why: via, then: then, d: d}
	sess, arrival := held.Session, held.Arrival
	e.timer = time.AfterFunc(arrivalHoldTimeout, func() { staleArrival(sess, held.CharacterID, arrival) })
	arrivals.byChar[held.CharacterID] = e
	arrivals.Unlock()
	arrivalInfo("arrival held", "character_id", held.CharacterID, "name", held.Name, "via", via,
		"zone", held.Zone, "x", held.Pos.X, "z", held.Pos.Z)
}

// staleArrival is the hold's timeout (arrivalHoldTimeout): a character still
// held at the same arrival is cleared as retail's stale player is -- its
// session closed, never put into the world (READ, CLobby_RemoveStalePlayers
// 0x437a50).
func staleArrival(sess *gateway.Session, characterID int64, arrival uint64) {
	arrivals.Lock()
	e := arrivals.byChar[characterID]
	stale := e != nil && e.held && e.sess == sess && e.arrival == arrival
	if stale {
		e.timer = nil
	}
	arrivals.Unlock()
	if !stale {
		return
	}
	arrivalInfo("arrival stale: no 0x3012, session closed (StalePlayer clear)", "character_id", characterID,
		"waited_s", arrivalHoldTimeout.Seconds())
	_ = sess.Close()
}

// releaseArrival puts the held character on sess back into the world: its
// client reported loading done (0x3012) or the hold timed out. arrival 0
// takes whatever arrival is held (the 0x3012); a timer passes its own and
// stands down when the character has arrived anew since.
func releaseArrival(sess *gateway.Session, arrival uint64, why string) bool {
	if sess == nil {
		return false
	}
	arrivals.Lock()
	var ent *arrivalEntry
	var id int64
	for cid, e := range arrivals.byChar {
		if e.sess == sess && e.held && (arrival == 0 || e.arrival == arrival) {
			ent, id = e, cid
			break
		}
	}
	if ent == nil || ent.d.hub == nil {
		arrivals.Unlock()
		return false
	}
	hub := ent.d.hub
	cur, ok := hub.EntityBySession(sess.ID())
	if !ok || cur.CharacterID != id || cur.Arrival != ent.arrival || !cur.Held {
		if !ok {
			delete(arrivals.byChar, id) // gone: nothing to release
		}
		arrivals.Unlock()
		return false
	}
	ent.held = false
	if ent.timer != nil {
		ent.timer.Stop()
		ent.timer = nil
	}
	then, d, via, heldAt := ent.then, ent.d, ent.why, ent.heldAt
	arrivals.Unlock()

	released, others, ok := hub.Release(sess)
	if !ok {
		return false
	}
	arrivalInfo("arrival released", "character_id", id, "name", released.Name, "via", via, "why", why,
		"held_ms", time.Since(heldAt).Milliseconds(), "zone", released.Zone, "x", released.Pos.X, "z", released.Pos.Z,
		"players_in_view", len(others))
	// CGame::EnterWorld's order (READ, docs/protocol/arrival_guard.md):
	// CGObj::EnterWorld puts the object into its block -- the spawns both
	// ways -- and then vslot_391 sets body mode 2, which SetBodyMode
	// broadcasts to the block as 0x30BF kind 4.
	released.Session = sess
	arrivePlayer(d, released)
	// Round 869 lane W3: what waited for the arrival (an instance's entry
	// notices, its re-entry icon -- sendAfterArrival). An instance's own
	// goroutine runs the entry's triggers: it is caught up first, so their
	// notices are queued before the flush.
	if w := instanceOf(hub); w != nil {
		w.Sync()
	}
	flushArrivalSends(id, sess, false)
	// Round 870: what follows the early sends (a new re-entry limit's first
	// 0x320C, MEASURED right after the entry notice pair).
	flushAfterEarly(id, sess)
	if then != nil {
		then(released)
	}
	startProtection(hub, id, sess, why)
	flushArrivalSends(id, sess, true)
	return true
}

// arrivalSends are packets for a held character that go out with its
// arrival (round 869 lane W3). MEASURED: an instance's entry notice pair
// (0x300C 0x0C1C, banner then system line) comes right after the client's
// 0x3012, and the re-entry icon (0x320C) after the arrival state.
var arrivalSends = struct {
	sync.Mutex
	early, late map[int64][]*proto.Packet
	// afterEarly (round 870) goes between the two.
	afterEarly map[int64][]*proto.Packet
}{early: map[int64][]*proto.Packet{}, late: map[int64][]*proto.Packet{}, afterEarly: map[int64][]*proto.Packet{}}

// sendAfterArrival sends pkt to characterID's sess now, or with its arrival
// when it is held (late: after the arrival state).
func sendAfterArrival(characterID int64, sess *gateway.Session, pkt *proto.Packet, late bool) {
	if sess == nil {
		return
	}
	arrivalSends.Lock()
	if arrivalHeld(characterID) {
		m := arrivalSends.early
		if late {
			m = arrivalSends.late
		}
		m[characterID] = append(m[characterID], pkt)
		arrivalSends.Unlock()
		return
	}
	arrivalSends.Unlock()
	_ = sess.Send(pkt)
}

// queueForArrival files pkt for characterID's next arrival whether or not
// it is held yet (a warp about to hold it).
func queueForArrival(characterID int64, pkt *proto.Packet, late bool) {
	arrivalSends.Lock()
	defer arrivalSends.Unlock()
	m := arrivalSends.early
	if late {
		m = arrivalSends.late
	}
	m[characterID] = append(m[characterID], pkt)
}

// dropArrivalSends forgets what waited for characterID's arrival.
func dropArrivalSends(characterID int64) {
	arrivalSends.Lock()
	delete(arrivalSends.early, characterID)
	delete(arrivalSends.late, characterID)
	delete(arrivalSends.afterEarly, characterID)
	arrivalSends.Unlock()
}

// queueAfterEarly files pkt for characterID's next arrival, after its early
// sends (the entry notices) and before the arrival state (round 870).
func queueAfterEarly(characterID int64, pkt *proto.Packet) {
	arrivalSends.Lock()
	arrivalSends.afterEarly[characterID] = append(arrivalSends.afterEarly[characterID], pkt)
	arrivalSends.Unlock()
}

// flushAfterEarly sends what queueAfterEarly filed for characterID.
func flushAfterEarly(characterID int64, sess *gateway.Session) {
	arrivalSends.Lock()
	pkts := arrivalSends.afterEarly[characterID]
	delete(arrivalSends.afterEarly, characterID)
	arrivalSends.Unlock()
	for _, p := range pkts {
		_ = sess.Send(p)
	}
}

// flushArrivalSends sends what waited for characterID's arrival.
func flushArrivalSends(characterID int64, sess *gateway.Session, late bool) {
	arrivalSends.Lock()
	m := arrivalSends.early
	if late {
		m = arrivalSends.late
	}
	pkts := m[characterID]
	delete(m, characterID)
	arrivalSends.Unlock()
	for _, p := range pkts {
		_ = sess.Send(p)
	}
}

// startProtection is CGObjPC::vslot_391's SetBodyMode(2, 0, t, 0) (READ,
// 0x4df9e0): body mode 2 for protectionTime, broadcast to the players in view
// and to the character itself (broadcastBodyMode), and body mode 0 at the
// time's end unless something ended it first (endProtection).
func startProtection(hub *world.Hub, characterID int64, sess *gateway.Session, why string) {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	arrivals.Lock()
	e := arrivals.byChar[characterID]
	if e == nil {
		e = &arrivalEntry{sess: sess}
		arrivals.byChar[characterID] = e
	}
	if e.timer != nil {
		e.timer.Stop()
	}
	e.gen++
	gen := e.gen
	e.until = time.Now().Add(protectionTime)
	e.timer = time.AfterFunc(protectionTime, func() { endProtectionGen(hub, characterID, gen, "expired") })
	arrivals.Unlock()
	broadcastBodyMode(hub, characterID, bodyModeInvincible)
	arrivalInfo("protection started", "character_id", characterID, "after", why, "seconds", protectionTime.Seconds())
}

// endProtectionGen ends characterID's protection gen (0: whichever runs), if
// it is still the running one, and reports whether it was: body mode 0 to the
// players in view and to the character. Only the time's end calls it --
// nothing a player does ends it early (READ: none of SetBodyMode's 28 call
// sites is on a move, an attack, a cast, an item use or a pick-up; the
// attack is refused instead, 0x529240).
func endProtectionGen(hub *world.Hub, characterID int64, gen uint64, why string) bool {
	arrivals.Lock()
	e := arrivals.byChar[characterID]
	if e == nil || e.held || e.until.IsZero() || (gen != 0 && e.gen != gen) {
		arrivals.Unlock()
		return false
	}
	if e.timer != nil {
		e.timer.Stop()
	}
	delete(arrivals.byChar, characterID)
	arrivals.Unlock()
	broadcastBodyMode(hub, characterID, 0)
	arrivalInfo("protection ended", "character_id", characterID, "why", why)
	return true
}

// arrivalHeld reports whether characterID is held out of the world.
func arrivalHeld(characterID int64) bool {
	arrivals.Lock()
	defer arrivals.Unlock()
	e := arrivals.byChar[characterID]
	return e != nil && e.held
}

// protectedNow reports whether characterID's protection is running.
func protectedNow(characterID int64, now time.Time) bool {
	arrivals.Lock()
	defer arrivals.Unlock()
	e := arrivals.byChar[characterID]
	return e != nil && !e.held && !e.until.IsZero() && now.Before(e.until)
}

// untouchable reports whether characterID may be neither hit nor targeted
// now: held out of the world, or protected (body mode 2).
func untouchable(hub *world.Hub, characterID int64, now time.Time) bool {
	if hub != nil {
		if e, ok := hub.EntityByCharacterID(characterID); ok && e.Held {
			return true
		}
	}
	return arrivalHeld(characterID) || protectedNow(characterID, now)
}

// forgetArrival drops characterID's arrival state (a disconnect): no timer
// outlives the session.
func forgetArrival(characterID int64) {
	dropArrivalSends(characterID)
	arrivals.Lock()
	if e := arrivals.byChar[characterID]; e != nil {
		if e.timer != nil {
			e.timer.Stop()
		}
		delete(arrivals.byChar, characterID)
	}
	arrivals.Unlock()
}

// handleReadyToPlay is 0x3012: the client's loading is done. A held
// character is released (releaseArrival); any other 0x3012 (the guard off, a
// repeat) does nothing (OURS: CGame::EnterWorld's answer to an object already
// in the world was not read).
func handleReadyToPlay(sess *gateway.Session) error {
	releaseArrival(sess, 0, "ready")
	return nil
}
