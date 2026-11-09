extends RefCounted
class_name WalkClock

## Round 878: the own player's walk on the wall clock, as the original's mover
## steps it and as the server's leg runs.
##
## READ (c:FUN_009e0e60, docs/protocol/opcodes/movement.md "How the client
## steps a mover"): the mover's step is speed x the frame's elapsed seconds
## (the global 0x0110f7fc), so a slow or stalled frame takes one longer step
## and the mover is where its time has it. The server's leg is a clock too
## (world.Mover.At: Src + speed x the time since Start). OpenSRO's walk steps
## in Godot's physics ticks (1/60 s each), and Godot runs at most
## max_physics_steps_per_frame (8) ticks a frame and drops the rest of a longer
## frame's time: a frame of 724 ms ran 6 ticks, the walk lost 0.6 s (30 units
## at the run speed of 50) and the server's leg did not (MEASURED, round 878's
## lane run j1: the client 27 units behind the server from then on, then a
## correction when the server's leg from its own point met a wall the
## client's did not).
##
## While the walk is in effect this keeps the time its ticks walked against
## the wall clock, read once a frame after the frame's ticks (`frame`, from
## _process: within a frame the ticks run back to back, so a reading between
## them is a frame off). What the ticks fell behind by more than SLACK is owed
## and walked on the next tick (`tick`), in extra steps of at most one tick
## each (World3D). Without a drop the lag is the physics accumulator's
## fraction, under one tick, so nothing is owed; a stall's drop is walked back
## to within SLACK. OURS: SLACK and MAX_CATCH_UP.

## The part of the lag never walked: three ticks.
const SLACK := 0.05
## The most walked back for one gap (a longer one -- a loading screen, the
## process stopped -- is not walked: OURS).
const MAX_CATCH_UP := 2.0

## Seconds the wall clock was ahead of the walk at the last frame.
var lag := 0.0
var _walking := false
## Seconds walked since the walk began (its ticks and what they were owed).
var _sim := 0.0
## The wall clock (usec) at which _sim was 0; -1 until the walk's first frame.
var _base_usec := -1
var _owed := 0.0

## One physics tick of `delta` seconds; `walking` whether the own walk (an
## order, a heading run) is in effect. Returns how many seconds of walk this
## tick owes beyond its own delta (0 while standing: the time stood is no
## walk).
func tick(delta: float, walking: bool) -> float:
	if not walking:
		_walking = false
		lag = 0.0
		_owed = 0.0
		return 0.0
	if not _walking:
		# The walk's first tick: the time before it was stood, not walked.
		_walking = true
		_sim = 0.0
		_base_usec = -1
		_owed = 0.0
	var owed := _owed
	_owed = 0.0
	_sim += delta + owed
	return owed

## The frame's reading of the wall clock (`now_usec`, Time.get_ticks_usec),
## after its ticks.
func frame(now_usec: int) -> void:
	if not _walking:
		return
	if _base_usec < 0:
		_base_usec = now_usec - int(_sim * 1000000.0)
		lag = 0.0
		return
	lag = float(now_usec - _base_usec) / 1000000.0 - _sim
	if lag > MAX_CATCH_UP + SLACK:
		# Past what is walked back: dropped (OURS).
		_base_usec = now_usec - int((_sim + SLACK) * 1000000.0)
		lag = SLACK
		return
	_owed = maxf(0.0, lag - SLACK)
