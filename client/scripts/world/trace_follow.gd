extends RefCounted
class_name TraceFollow

## Trace (round 832): one player following another, as the original server
## runs it. Pure, so a headless test holds every rule; World3D drives it.
##
## READ (SR_GameServer.exe, the dump at /var/tmp/decomp_server):
##
## The 0x7074 request [01 03 01 <u32 uid>] pushes a kind-3 action on the
## character's CGCharAutoCommandActor (`0x4acc40` -> Push `0x4ad630`); the
## actor ticks every 30 ms (`0x4ad7a0`) and runs the trace handler `0x4ae3d0`:
##
##   phase 0  PrepareAction (`0x4ad030` case 3) must pass, then
##            stop    = own BCRadius + target BCRadius + 50.0 (.rdata 0xb46288)
##            restart = target BCRadius + own BCRadius + 80.0 (0xb45c58)
##            (IGObj slot 344 `0x560`, CGObjChar::GetBCRadius = characterdata
##            column 50; both cut to u16 with the chop rounding mode, fldcw
##            |0xc00, at 0x4ae41b..0x4ae45b), and phase 1.
##   phase 1  PrepareAction again; when the walker (pc+0x1bf4,
##            CGCharAutoNavigator) holds no target (pc+0x1bfc == 0),
##            GObjPC::MoveTowardObject(target, stop, restart) `0x4b0350`
##            arms it -- refused (the trace ends) when the tracer is held by a
##            `stns` stun (pc+0xc44) or the target is gone.
##   The handler never finishes on its own: the trace lasts until
##   PrepareAction fails, the walker cannot be armed, the player cancels
##   (0x7074 [02]) or another action takes its place (Push drops a front
##   trace for any new action).
##
## PrepareAction's case 3 (the target test, `0x4ad0e8..`): the target id
## resolves (`0x485d90`), IGObj slot 7 `CGObj::IsPC` (`0x482560`) -- only a
## player can be traced --, slot 62 `CGObj::GetLifeState` is neither 2 (dead)
## nor 3, and FUN_00430ce0: both in the same world kind (field / dungeon,
## bit 15 of the region word), and in the field each region byte within one
## of the tracer's (the 3 x 3 regions around it). See `target_valid`.
##
## The walker's tick (`0x4b0490`, at most every 100 ms -- `GetTickCount() -
## +0x14 < 100` returns) is `step` below. Its walks are not sent by the
## client: the server builds a 0x7021 destination request (or 0x70C5 riding,
## slot 336 `0x4ddca0`) and posts it to the player's own message queue, then
## a 0x704f [03] -- run -- unless the motion state (slot 63) is already 3.
## OpenSRO's server does not move players (session/keepup.go), so here the
## client runs the same tick and issues the same two requests itself (OURS:
## the place, not the rules).

## The stop distance's pad, added to both radii (READ, .rdata 0xb46288 = 50.0).
const STOP_PAD := 50
## The walk-again distance's pad (READ, .rdata 0xb45c58 = 80.0).
const RESTART_PAD := 80
## The walker's period (READ, 0x4b04c7: `< 100` ms returns).
const TICK_MS := 100
## Farther than this (3-D) the walker lets go (READ, .rdata 0xb45c68 = 1000.0;
## `fcomp; test ah,0x41; je` at 0x4b05df: strictly greater).
const MAX_DISTANCE := 1000.0
## A walk already heading within this angle of the target is left alone
## (READ, .rdata float 0xb462b8 = 0.2617994 rad = 15 degrees; the angle is a
## CRT call on the dot product, FUN_009fbe30 -- INFERRED acos, since its
## result is compared with an angle).
const HEADING_KEEP := 0.2617993950843811
## Overlap slack: closer than the two radii less this, the tracer steps back
## (READ, `lea eax,[esi-0x4]` at 0x4b0626).
const OVERLAP_SLACK := 4
## The region size of the field (READ, .rdata 0xb45ad0 = 1920.0).
const REGION_SIZE := 1920.0

## The two distances phase 0 stores: x = stop, y = restart (READ, above).
static func bands(own_bc: int, target_bc: int) -> Vector2i:
	return Vector2i((own_bc + target_bc + STOP_PAD) & 0xffff, (target_bc + own_bc + RESTART_PAD) & 0xffff)

## PrepareAction's case 3 (READ): `life_state` is the target's (1 alive,
## 2 dead); `own_region` / `target_region` are the wire region words (bit 15
## set in a dungeon, else x in the low byte and z in the high byte).
static func target_valid(is_player: bool, life_state: int, own_region: int, target_region: int) -> bool:
	if not is_player or life_state == 2 or life_state == 3:
		return false
	return regions_near(own_region, target_region)

## FUN_00430ce0 (READ): the same world kind, and in the field each region byte
## within one.
static func regions_near(a: int, b: int) -> bool:
	if (a >> 15) != (b >> 15):
		return false
	if (a & 0x8000) != 0:
		return true
	return absi((b & 0xff) - (a & 0xff)) < 2 and absi(((b >> 8) & 0xff) - ((a >> 8) & 0xff)) < 2

## One walker tick (READ, `0x4b0490`). `own` and `target` are the two
## positions (3-D, one frame); `moving_dir` is the tracer's unit heading
## while it walks, Vector3.ZERO standing (slot 304 `0x4c0` asks whether it
## moves; the heading is pc+0x24..+0x2c -- that these are the walk's unit
## direction is INFERRED from the dot product they enter). `target_is_char`
## is IGObj slot 6 (`CGObj::IsChar`) on the target -- always true for a
## traced player. Returns:
##   {"do": "end"}                    the walker lets go (0x4b03f0: the walk
##                                    stops where it is)
##   {"do": "none"}                   nothing this tick
##   {"do": "walk", "point": Vector3} a 0x7021 destination, then run
##   {"do": "back", "point": Vector3} a 0x7021 destination, no run request
static func step(own: Vector3, target: Vector3, moving_dir: Vector3, own_bc: int, target_bc: int,
		stop: int, restart: int, target_is_char: bool = true) -> Dictionary:
	var delta := target - own
	var dist := delta.length()
	if dist > MAX_DISTANCE:
		return {"do": "end"}
	var r := own_bc + (target_bc if target_is_char else 0)
	var dir := delta / dist if dist > 0.0 else Vector3.ZERO
	if float(r - OVERLAP_SLACK) <= dist or stop <= r:
		# Within the walk-again distance nothing is sent (`fild [ebx+0xe];
		# fcomp; test ah,1; je` at 0x4b0852: only dist > restart walks).
		if dist <= float(restart):
			return {"do": "none"}
		if moving_dir != Vector3.ZERO:
			# The dot product takes the y term times 0.0 (.rdata 0xb45ab0).
			var dot := moving_dir.x * dir.x + moving_dir.y * 0.0 + moving_dir.z * dir.z
			if acos(clampf(dot, -1.0, 1.0)) < HEADING_KEEP:
				return {"do": "none"}
		var d := dist - float(stop) if float(stop) < dist else dist
		return {"do": "walk", "point": own + Vector3(dir.x * d, 0.0, dir.z * d)}
	# Inside the other body: a step straight back by the two radii, with no
	# run request (0x4b0653..0x4b081d).
	return {"do": "back", "point": own - Vector3(dir.x * float(r), 0.0, dir.z * float(r))}
