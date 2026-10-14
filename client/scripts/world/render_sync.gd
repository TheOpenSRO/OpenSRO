extends RefCounted
class_name RenderSync

## Round 786 (MEASURED; the remedy is OURS): one wait for the render thread a
## frame, paid up front and known.
##
## With the separate render thread (project.godot's thread_model 2), a call
## that asks the rendering server for something -- a GeometryInstance3D's or
## a ShaderMaterial's property list (so every duplicate()), a Label3D's text
## box, a material copy -- waits for that thread to finish what it is doing,
## which mid-frame is drawing the last frame. The first such call of a frame
## waits for the rest of that draw (12-25 ms on the render box, `QA LAT
## build` laps: the duplicate, the name box, the lighting's copy, the fade's
## twins -- whichever came first); every later one in the same frame finds
## the thread idle and costs microseconds. A monster body makes several, so
## the first body of each frame paid the draw, and the network's 8 ms read
## budget (NetClient.NET_FRAME_BUDGET_USEC), counting that wait as its own
## work, stopped after it: a burst of N monsters entering the view took N
## frames, and whatever came after them on the wire -- an attack's result --
## waited those N frames too (round 786's table).
##
## `wait_once()` is called before a body is made: in the first call of a
## frame it waits for the render thread itself (RenderingServer.force_sync)
## and hands the time to NetClient and the build pump, whose budgets then
## count only their own work; later calls that frame return 0. The wait is
## the one the body's first call would have made anyway, so it costs nothing
## more; the frame's other bodies are then cheap.

static var _frame := -1
## The time the last wait took, in microseconds (tests and QA).
static var last_wait_usec := 0
## Off with OPENSRO_QA_NO_RENDER_SYNC=1 (round 786's A/B).
static var on := OS.get_environment("OPENSRO_QA_NO_RENDER_SYNC") != "1"

## Waits for the render thread the first time it is called in a process
## frame; returns the microseconds waited (0 when already done this frame).
static func wait_once() -> int:
	if not on:
		return 0
	var f := Engine.get_process_frames()
	if f == _frame:
		return 0
	_frame = f
	var t := Time.get_ticks_usec()
	RenderingServer.force_sync()
	last_wait_usec = Time.get_ticks_usec() - t
	return last_wait_usec

## Tests: forget the frame, so the next call waits again.
static func reset() -> void:
	_frame = -1
	last_wait_usec = 0
