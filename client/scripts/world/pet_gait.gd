class_name PetGait
extends RefCounted

## Round 852: a growth or ability pet's walk or run and the rate its clip
## plays at, from the speed it moves at. Pure and static so a headless test
## holds it to account; World3D._cos_step applies it every frame.
##
## READ (sro_client.exe, CICCos slot 9 = c:0x9c59c0, the COS's per-frame tick;
## constants read as stored):
##   - Only for a COS whose type word ([+0x660]) is TypeID 1/2/3 with TypeID4
##     3 or 4 (c:0x9c59d0..0x9c5a07): the growth and ability pets. A horse, a
##     trade transport (TypeID4 1, 2), a soldier, a player, a monster or an
##     NPC never takes this path: its clip rate is 1.0 but for the abnormal
##     states (StateLook), and a ride's walk or run is its rider's (round 798).
##   - The speed s = the mover's run speed (+0x670, which 0x30D0 sets) x its
##     speed factor (+0x6f4, the mover's +0x8c: round 846's catch-up factor,
##     FUN_009e0550, 1.0 on a leg it is not behind on), stored as its walk
##     speed (+0x66c) too (c:0x9c5a09..0x9c5a1d) -- so a pet walking moves at s
##     as well (the mover's speed is +0x66c/+0x670 by its index +0x678 x +0x6f4,
##     c:0xa59724).
##   - Then (c:0x9c5a85..0x9c5aee) against 20.0 (float 0xd88108): s <= 20 with
##     the speed index on run -> FUN_009ca430(2), walk (+0x25d 0, +0x678 0,
##     and the moving state 9 restarted, so a moving pet changes clip); s > 20
##     -> FUN_009ca430(3), run, when not already on it.
##   - The rate (+0xc0) starts at 1.0; s > 20 while the moving state is on
##     (+0x65c bit 9) makes it s / 50.0 (double 0xd8f0b0); frostbite on the pet
##     (+0x2c4 bit 1, StatusNet's FB) halves it (double 0.5 at 0xe1b7d0); it is
##     at most 1.5 (float 0xd819ec); there is no lower bound (a run is > 20, so
##     > 0.4). Walking, the clip plays at 1.0 whatever s is.
##   - +0xc0 is the body's clip speed: the tick advances the body's animation
##     by ROUND(+0xc0 x the frame's ms) (GlobalDataManager::FUN_009c4180,
##     c:0x9c41c1 -> FUN_00a5acb0 -> the renderer's slot 0x38), with a flag
##     beside it that +0xbd (frozen, StateLook) turns off (its effect not read).
##   - It runs every frame, before the base tick (FUN_009d1d60) steps the
##     mover: a 0x30D0 or a new leg's factor changes the gait and the rate on
##     the next frame, mid-leg too. It writes +0xc0 every frame, so on a pet
##     it overrides the abnormal-state setter's own +0xc0 (FUN_009cd5e0:
##     frostbite 0.5, slowness 0.75): a slowed pet's clip plays at its gait's
##     rate (the original's behaviour, built as it is).

## READ (float 0xd88108): a pet runs above this speed and walks at or below it.
const RUN_ABOVE := 20.0
## READ (double 0xd8f0b0): a running pet's clip rate is its speed over this.
const RATE_SPEED := 50.0
## READ (float 0xd819ec): the most a pet's clip rate is.
const RATE_MAX := 1.5
## READ (double 0xe1b7d0): frostbite's share of the rate.
const FROSTBITE_SHARE := 0.5

## Whether a pet at speed `s` (run speed x factor) runs.
static func runs(s: float) -> bool:
	return s > RUN_ABOVE

## The pet's clip rate at speed `s`: s / 50 while it moves and runs, else 1.0;
## halved under frostbite; at most 1.5.
static func rate(s: float, moving: bool, frostbite: bool) -> float:
	var r := 1.0
	if moving and s > RUN_ABOVE:
		r = s / RATE_SPEED
	if frostbite:
		r *= FROSTBITE_SHARE
	return minf(r, RATE_MAX)
