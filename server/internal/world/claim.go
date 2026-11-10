package world

import (
	"math"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// A client's claim about where its character is (round 749's review, F1).
//
// Since round 749 the server keeps the leg of every walk, but a client still
// reports where its walk stopped short (a wall, an approach in reach, a sit)
// and where it was put (a placement). Round 749 measured each claim from the
// character's previous claim with a fixed slack, so 300 claims of 5.5 moved a
// character 1,650 units in 8 ms (the review, MEASURED). This bound has a clock
// and an anchor (OURS, both):
//
//   - The ANCHOR is the server's own reference: the leg's travelled segment
//     while a leg runs, else Entity.Trusted -- a point the server itself fixed
//     (an arrival, its own placement, a leg's end, a correction). A claim
//     never moves the anchor by itself, so claims cannot creep.
//   - A claim within Bound.Slack of the anchor (horizontally) is free: the
//     client's stop distance, the wire's truncation and the no-slide wall
//     nudge live there.
//   - Beyond it, the claim draws the excess from the character's ALLOWANCE:
//     run banked at its run speed while it stands, at most AllowanceSeconds'
//     worth. A leg's own travel is charged against the accrual, so walking
//     banks nothing and a second's lead is shared across legs, not granted to
//     each. The anchor moves by what was paid, toward the claim.
//   - The height is bounded from the last height the client itself gave
//     (Entity.HeightAllows: Bound.Height plus the ground distance from where
//     it gave it, a 45-degree slope), never from a height the server guesses
//     (round 749's verification, FP1-FP3), and always by Bound.Sanity.
//
// So no chain of stops, placements or click-and-stop pairs moves a character
// faster than its run speed, beyond one slack and one banked second.

// AllowanceSeconds is how much standing run a character may bank (OURS: the
// one second round 749 granted every stop as a lead, now shared).
const AllowanceSeconds = 1.0

// Bound is one claim's limits: the character's run speed now, the free
// slack, the height bound, whether to trust it whatever it says (QA), and the
// named points it may also be taken at (an arrival, a GM's point; used up by
// the call when it answers true).
type Bound struct {
	Speed  float64
	Slack  float64
	Height float64
	Sanity float64
	Trust  bool
	Named  func(x, z float64) bool
	// Unreached (round 857): the server's own walk from where it has the
	// character does not reach the claim -- a wall lies between -- so only a
	// named point may take it. The original server takes no position from a
	// client at all (a stop report is OURS), and one past a wall put the
	// character inside whatever the client's walk had gone into.
	Unreached bool
}

// HeightAllows reports whether height y at ground point (x, z) may follow the
// last height the client gave (round 749's verification, FP1-FP3; OURS): within
// slack plus the ground distance from where it gave it (no steeper than 45
// degrees, plus slack), and always within +-sanity. With no height from the
// client yet -- after an arrival or a placement the server made, whose height
// is the server's guess -- only the sanity range applies.
func (e Entity) HeightAllows(x, y, z, slack, sanity float64) bool {
	if math.Abs(y) > sanity {
		return false
	}
	if !e.clientYKnown {
		return true
	}
	return math.Abs(y-e.clientY) <= slack+math.Hypot(x-e.clientYX, z-e.clientYZ)
}

// noteClientY records y at (x, z) as the last height the client gave.
func (e *Entity) noteClientY(x, y, z float64) {
	e.clientY, e.clientYX, e.clientYZ, e.clientYKnown = y, x, z, true
}

// accrueLocked brings e's allowance up to now: the run speed times the time
// since, less what the current leg travelled meanwhile, kept between 0 and
// AllowanceSeconds of run. Caller holds h.mu for writing.
func accrueLocked(e *Entity, now time.Time) {
	dt := now.Sub(e.allowAt).Seconds()
	if dt < 0 {
		dt = 0
	}
	legDelta := 0.0
	if m := e.Move; m != nil {
		tr := m.Travelled(now)
		legDelta = tr - e.allowLeg
		e.allowLeg = tr
	}
	e.allow += e.allowSpeed*dt - legDelta
	if limit := e.allowSpeed * AllowanceSeconds; e.allow > limit {
		e.allow = limit
	}
	if e.allow < 0 {
		e.allow = 0
	}
	e.allowAt = now
}

// pointAt is the leg's point `along` units from its source.
func (m *Mover) pointAt(along float64) Position {
	if m.Heading {
		return Position{X: m.Src.X + m.DirX*along, Y: m.Src.Y, Z: m.Src.Z + m.DirZ*along}
	}
	if m.dist <= 0 {
		return m.Src
	}
	f := along / m.dist
	return Position{
		X: m.Src.X + (m.Dest.X-m.Src.X)*f,
		Y: m.Src.Y + (m.Dest.Y-m.Src.Y)*f,
		Z: m.Src.Z + (m.Dest.Z-m.Src.Z)*f,
	}
}

// anchorLocked is the server's reference for a claim at (x, z) at now: the
// nearest point of the leg's travelled segment, or the trusted point.
func anchorLocked(e *Entity, x, z float64, now time.Time) Position {
	m := e.Move
	if m == nil {
		return e.Trusted
	}
	if _, arrived := m.At(now); arrived {
		return m.Dest
	}
	along, _ := m.Along(x, z)
	if tr := m.Travelled(now); along > tr {
		along = tr
	}
	return m.pointAt(along)
}

// Claim takes a client's claim that sess's character stands at pos (a stop,
// or a placement) when b admits it, measured from the anchor with the
// allowance (above). Taken, the leg ends there, the character stands at pos,
// turned as kind says, and the anchor moves by what was paid; refused,
// nothing changes (admitted false) and the caller corrects. ok is false when
// the session is not in the world.
func (h *Hub) Claim(sess *gateway.Session, pos Position, kind MoveKind, heading float64, b Bound) (r MoveResult, admitted, ok bool) {
	if o := h.routed(sess); o != nil {
		return o.Claim(sess, pos, kind, heading, b)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.clock()
	e, exists := h.bySession[sess.ID()]
	if !exists {
		return MoveResult{}, false, false
	}
	if e.allowSpeed == 0 {
		e.allowSpeed = b.Speed
	}
	accrueLocked(e, now)
	if b.Speed > 0 {
		e.allowSpeed = b.Speed
	}
	anchor := anchorLocked(e, pos.X, pos.Z, now)
	trusted, paid := anchor, 0.0
	d := math.Hypot(pos.X-anchor.X, pos.Z-anchor.Z)
	v := ClaimVerdict{Anchor: anchor, Distance: d, Slack: b.Slack, Allowance: e.allow}
	admitted = b.Trust
	switch {
	case admitted:
		trusted, v.Rule = pos, "trust"
	case b.Unreached:
		v.Rule = "unreached"
	case !outLocked(e, now).HeightAllows(pos.X, pos.Y, pos.Z, b.Height, b.Sanity):
		v.Rule = "height"
	default:
		switch need := d - b.Slack; {
		case need <= 0:
			admitted, v.Rule = true, "near"
		case need <= e.allow:
			admitted, paid, v.Rule = true, need, "allowance"
			trusted.X += (pos.X - anchor.X) / d * need
			trusted.Z += (pos.Z - anchor.Z) / d * need
		default:
			v.Rule = "distance"
		}
	}
	if !admitted && b.Named != nil && b.Named(pos.X, pos.Z) {
		admitted, trusted, v.Rule = true, pos, "named"
	}
	r.Claim = v
	if !admitted {
		r.Entity = outLocked(e, now)
		return r, false, true
	}
	h.placeLocked(e, now, pos, kind, heading, &r)
	e.allow -= paid
	// Round 822: the trusted point's height is the claim's own -- bounded
	// above (HeightAllows) from the client's last height -- not the anchor's,
	// which is the leg's straight-line guess: a stop on a bridge deck kept a
	// height under it, and the next leg started there.
	trusted.Y = pos.Y
	e.Trusted = trusted
	e.noteClientY(pos.X, pos.Y, pos.Z)
	r.Entity = *e
	return r, true, true
}
