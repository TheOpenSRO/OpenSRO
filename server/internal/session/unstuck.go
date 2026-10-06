package session

import (
	"encoding/binary"
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// The server's /unstuck (round 749's verification, FP6; OURS -- retail has no
// such command).
//
// Since round 749 a client's placement is taken only near where the server
// has the character or, once and within two minutes, at a point the server
// named. The client's own /unstuck -- a placement at the zone's landing spot --
// was therefore corrected back into the spot it was stuck at once an
// arrival's grace had passed, and the server has no navigation mesh to free a
// player wedged by its own walk. So /unstuck is the server's now: the client
// asks (OpUnstuck), and the server puts the character at its zone's landing
// spot -- the client's spawn spot in the zone's centre region
// (worldmap.LandingSpotFor), else the zone's arrival point -- itself, tells
// the window and the character with retail's 0xB023, and answers
// OpUnstuckResult. Once a unstuckCooldown, and never anywhere but the zone's
// landing: not the logout spot (round 749's review, F2).
const (
	OpUnstuck       uint16 = 0x00B8 // client -> server, empty
	OpUnstuckResult uint16 = 0x00B9 // server -> client: u8 ok, u16 seconds until it may be asked again
	// 0x00B8 and 0x00B9 were free in server/ and client/scripts (grep,
	// 2026-10-06), beside OpPlayerZoneNotice 0x00B7.

	// unstuckCooldown is how often a character may be put back (OURS).
	unstuckCooldown = 60 * time.Second
)

var unstuckLast sync.Map // int64 character id -> time.Time

// UnstuckResult is OpUnstuckResult's payload.
type UnstuckResult struct {
	OK   bool
	Wait uint16 // seconds until it may be asked again (0: now, or not at all)
}

func (r *UnstuckResult) Encode() []byte {
	out := []byte{0}
	if r.OK {
		out[0] = 1
	}
	return binary.LittleEndian.AppendUint16(out, r.Wait)
}

// DecodeUnstuckResult reads OpUnstuckResult.
func DecodeUnstuckResult(b []byte) (UnstuckResult, bool) {
	if len(b) < 3 {
		return UnstuckResult{}, false
	}
	return UnstuckResult{OK: b[0] == 1, Wait: binary.LittleEndian.Uint16(b[1:])}, true
}

// unstuckTarget is where /unstuck puts e: its zone's landing spot in e's
// bucket. ok is false when the zone (the label the character entered or last
// changed zone with) has none in that bucket.
func unstuckTarget(sess *gateway.Session, e world.Entity) (zone string, pos world.Position, ok bool) {
	p, known := placeOf(sess)
	if !known {
		return "", world.Position{}, false
	}
	bucket, at, _, _ := arrival(p.zone)
	if bucket != e.Zone {
		return "", world.Position{}, false
	}
	if x, z, spot := worldmap.LandingSpotFor(p.zone, at.X, at.Z); spot {
		at.X, at.Z = x, z
	}
	return p.zone, at, true
}

func handleUnstuck(sess *gateway.Session, hub *world.Hub, chars character.Store) error {
	answer := func(r UnstuckResult) error {
		return sess.Send(&proto.Packet{Opcode: OpUnstuckResult, Data: r.Encode()})
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok || e.Life == world.LifeDead || !statusFX.characterCanMove(e.CharacterID) || tradeEstablishedOn(hub, e.CharacterID) {
		return answer(UnstuckResult{})
	}
	now := time.Now()
	if v, seen := unstuckLast.Load(e.CharacterID); seen {
		if left := unstuckCooldown - now.Sub(v.(time.Time)); left > 0 {
			return answer(UnstuckResult{Wait: uint16(math.Ceil(left.Seconds()))})
		}
	}
	_, target, ok := unstuckTarget(sess, e)
	if !ok {
		return answer(UnstuckResult{})
	}
	r, ok := hub.Relocate(sess, target, world.MoveRelocate, 0)
	if !ok {
		return answer(UnstuckResult{})
	}
	unstuckLast.Store(e.CharacterID, now)
	keepUp.Cancel(e.CharacterID)
	motions.walking(e.CharacterID, now)
	savePosition(chars, sess, r.Entity)
	// The window and the character itself: its client is put there (the
	// correction path, FUN_008a4f80's snap), standing on its own ground.
	stopRelay(sess, r, true)
	return answer(UnstuckResult{OK: true, Wait: uint16(unstuckCooldown / time.Second)})
}
