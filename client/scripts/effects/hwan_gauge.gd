extends RefCounted
class_name HwanGauge

## The berserk (hwan) count as the original keeps it on the player while
## violet orbs are in flight (round 860). READ from sro_client.exe; the
## player record is [0xeef5ec]:
##   +0x887  the real count (0..5), the last 0x304E kind 4's;
##   +0x886  the count the HUD shows (FUN_00778ae0's argument);
##   +0x888  violet orbs still to arrive.
##
## 0x304E kind 4 {u8 4, u8 the new count, u32 the source's uid} (c:0x8a70d0):
##  - the count ROSE and the source is a body in view: the rise is added to
##    the source's violet count (+0x75b, FUN_009c7550) and to +0x888; the
##    display is left alone -- the orbs fly with the kill's EXP / SP orbs
##    (ExpOrbs KIND_HWAN) and each arrival steps it (arrive);
##  - otherwise (no source, an unknown one, a fall): the violet orbs in
##    flight are deleted (FUN_009d8610), every object's violet count is
##    cleared, +0x888 = 0, and the display is the count (FUN_00778ae0(count,
##    0)); except a fall to 0 from 5 with 5 shown -- the activation's spend --
##    which only calls FUN_00778ae0(0, 0) (the running display keeps its own
##    timers; a count of 0 refreshes nothing, round 629).
## FUN_009d4ad0(n), each violet arrival with n = 1:
##  - +0x888 < n: display = real, +0x888 = 0;
##  - else +0x888 -= n; at 0 display = real, else display =
##    min(display + n, 5, real).
## With Effect Quality below 2 the orbs are not flown (FUN_009cb7c0) and the
## count goes to the gauge at once (arrive with everything pending).

const ORBS := 5

var real := 0
var display := 0
var pending := 0

## 0x304E kind 4. `source_in_view`: the source names a body this client
## draws. Returns {"fly": violet orbs to add to the source (0 for none),
## "reset": whether the violet orbs in flight and the sources' counts are
## dropped, "show": whether the display changed (call FUN_00778ae0)}.
func on_count(count: int, source_in_view: bool) -> Dictionary:
	var old := real
	var diff := count - old
	real = clampi(count, 0, ORBS)
	if diff > 0 and source_in_view:
		pending += diff
		return {"fly": diff, "reset": false, "show": false}
	if count == 0 and old == ORBS and display == ORBS:
		display = 0
		return {"fly": 0, "reset": false, "show": true}
	pending = 0
	display = real
	return {"fly": 0, "reset": true, "show": true}

## FUN_009d4ad0(n): n violet orbs arrived. Returns the display.
func arrive(n: int = 1) -> int:
	if pending < n:
		display = real
		pending = 0
		return display
	pending -= n
	if pending == 0:
		display = real
	else:
		display = mini(mini(display + n, ORBS), real)
	return display

## A count told another way (the stats, an attack result, a potion's reply):
## the display follows it only while no violet orb is on its way -- the
## original's display moves only through 0x304E and the arrivals.
func told(count: int) -> bool:
	real = clampi(count, 0, ORBS)
	if pending > 0:
		return false
	display = real
	return true

## The world went away (a teardown): nothing is in flight any more.
func reset() -> void:
	pending = 0
	display = real
