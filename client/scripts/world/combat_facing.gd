extends RefCounted
class_name CombatFacing

## A body turning to face what it strikes (round 785).
##
## READ (sro_client.exe): a skill action's decoration, CIDecoSkill::vslot_014
## (0xa503f0), turns its caster toward its target EVERY FRAME while it runs:
## the direction from the caster (deco+0x58, position +0x90/+0x98) to the
## target (IDecoSkill::FUN_00a4d5d0) becomes a heading (FUN_009ed130, the
## same conversion RemoteFacing.heading_toward ports), and
## CIDecoSkill::FUN_00a56cd0(current +0x8c, desired, frame seconds x 10.0)
## steps the heading toward it -- both wrapped into [0, 2 pi), the shorter
## way round, landing on the target when it is within the step -- and
## FUN_009c4260 sets it. The step's scale is the float at 0xe1b840, 10.0, and
## the frame seconds DAT_0110fffc: TURN_RATE radians a second, whatever the
## frame rate. The caster is any object -- the deco is built for a player and
## a monster alike (FUN_008a5fd0 builds it for any caster in view).
##
## OPEN: vslot_014 skips the turn when the deco's skill object (deco+0x154,
## FUN_0093f250's record, whose skilldata row sits at +0x774) has a non-zero
## +0x78 -- a field of the client's skill object that was not identified.
## OpenSRO turns every plain swing and every monster swing (OURS: the user's
## ask that a fighter face what it fights), at the read rate.
const TURN_RATE := 10.0

## One frame of the turn: from `current` toward `target` (headings, radians),
## `delta` seconds of it. The new heading, in [0, 2 pi).
static func step(current: float, target: float, delta: float) -> float:
	var cur := fposmod(current, TAU)
	var want := fposmod(target, TAU)
	var d := want - cur
	if d > PI:
		d -= TAU
	elif d < -PI:
		d += TAU
	var s := maxf(delta, 0.0) * TURN_RATE
	if absf(d) <= s:
		return want
	return fposmod(cur + signf(d) * s, TAU)
