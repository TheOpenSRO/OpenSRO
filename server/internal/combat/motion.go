package combat

import "math"

// The monster motion core (round 536): the engine's per-tick mover, and the
// hub calls a monster AI uses to start, stop and advance a leg. Nothing calls
// SetMotion or StepAll yet -- the AI tick that will is a later change -- so a
// spawned monster stands where it was put, exactly as before.

// MoverMaxStep is the most a mover advances an object in one step, whatever
// the speed and the elapsed time: the .rdata float at 0x00b45ea8, 0x43200000
// = 160.0f, which CGObjMoverByDest::FUN_0048bff0 clamps |speed x dt| to
// (docs/protocol/monster_ai.md, "srrevamp's own monster protocol").
const MoverMaxStep = 160.0

// MoverStep is one step of the engine's destination mover, on the ground
// plane. It is the two functions together:
//
//   - CGObjMoverByDest::FUN_0048bff0 builds the step: the owner's unit
//     heading (+0x24/+0x2c) times min(|speed(+0x174) x dt|, 160.0f), y = 0;
//   - its caller, CGObjMoverByDest::vslot_003 (0x0048c4e0), takes dest -
//     position (FUN_00430ad0, called at 0x48c5a9: across regions, y = 0),
//     compares the two lengths (fcompp at 0x48c622, `test ah,0x41`) and, only
//     when the step is the LONGER, replaces it with dest - position
//     (0x48c62b..0x48c63c).
//
// So a mover never overshoots: a step that would reach or pass the
// destination lands on it, and arrived is true. speed is in world units per
// second and dt in seconds.
//
// Two simplifications, disclosed. The heading is taken as the direction from
// (x, z) toward the destination: the engine sets it that way at every
// destination move's start (CGObjMoverByDest 0x48c330 -> its slot 10,
// 0x48c660, SetHeading toward the destination) and a straight leg keeps it,
// so the two agree up to float rounding. And FUN_0048bff0's zeroing of a step
// component under 0.01f (0xb45df8) is not modelled.
func MoverStep(x, z, destX, destZ, speed, dt float64) (nx, nz float64, arrived bool) {
	s := math.Min(math.Abs(speed*dt), MoverMaxStep)
	dx, dz := destX-x, destZ-z
	remaining := math.Hypot(dx, dz)
	if s >= remaining {
		// vslot_003's clamp: the remainder replaces a longer step.
		return destX, destZ, true
	}
	return x + dx/remaining*s, z + dz/remaining*s, false
}

// SetMotion starts monster id walking to (destX, destZ) at speed (world units
// per second) with clip mode mode (0 walk, 1 run), and returns the updated
// copy -- whose X/Z are where the leg starts, the position an OpMonsterMoved
// push carries. ok is false when the monster is gone.
func (h *Hub) SetMotion(id int64, destX, destZ, speed float64, mode uint8) (Monster, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m, ok := h.byID[id]
	if !ok {
		return Monster{}, false
	}
	m.DestX, m.DestZ = destX, destZ
	m.MoveSpeed = speed
	m.MoveMode = mode
	m.Moving = true
	return *m, true
}

// StopMotion ends monster id's leg where it stands: its destination becomes
// its own position and Moving is cleared. The speed and mode are left as they
// were, so the stop push can carry them (docs/protocol/monster_ai.md,
// "srrevamp's own monster protocol", the stop). ok is false when the monster
// is gone.
func (h *Hub) StopMotion(id int64) (Monster, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m, ok := h.byID[id]
	if !ok {
		return Monster{}, false
	}
	m.DestX, m.DestZ = m.X, m.Z
	m.Moving = false
	return *m, true
}

// StepAll advances every moving monster by dt seconds with MoverStep and
// clears Moving on arrival. It holds h.mu for the whole pass, the lock
// ApplyDamage deletes a killed monster under, so a monster killed mid-leg is
// simply absent here: it is neither stepped nor brought back.
func (h *Hub) StepAll(dt float64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, m := range h.byID {
		if !m.Moving {
			continue
		}
		var arrived bool
		m.X, m.Z, arrived = MoverStep(m.X, m.Z, m.DestX, m.DestZ, m.MoveSpeed, dt)
		if arrived {
			m.Moving = false
		}
	}
}

// All returns a copy of every live monster, in every zone.
func (h *Hub) All() []Monster {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]Monster, 0, len(h.byID))
	for _, m := range h.byID {
		out = append(out, *m)
	}
	return out
}
