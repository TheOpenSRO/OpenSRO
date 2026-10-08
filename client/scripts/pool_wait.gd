extends RefCounted
class_name PoolWait

## Round 760: the main thread's way to wait for a WorkerThreadPool task (or
## group) that may call the RenderingServer, without the Godot 4.7.2 deadlock.
##
## **The deadlock (READ, Godot 4.7.2-stable).** With the default render thread
## model (the RenderingServer on the main thread), a RenderingServer call made
## on any other thread is queued for the main thread (servers/server_wrap_mt_
## common.h: `ASYNC_COND_PUSH_AND_RET` is `Thread::get_caller_id() !=
## server_thread`), and one that returns a value or must be synchronous waits
## for the main thread to run it (`command_queue.push_and_ret` / `push_and_sync`
## -- a ShaderMaterial's uniform list, a mesh's surface arrays, a texture's
## image, ...). The main thread runs that queue only at its own
## RenderingServer calls and sync points (`command_queue.flush_if_pending()`
## in the same macros, `RenderingServerDefault::sync`). But
## `WorkerThreadPool.wait_for_task_completion` from a thread outside the pool
## blocks on the task's semaphore (core/object/worker_thread_pool.cpp,
## `task->done_semaphore.wait()`): the worker waits for the main thread, the
## main thread for the worker, for ever. MEASURED round 754 (Forward+ hung 4
## of 4) and round 760 (tools/pool_wait_probe.gd). Godot 4.2.2 queued nothing
## (its pool-thread calls ran directly, or failed thread guards), so no 4.2.2
## run could show it.
##
## **The wait here** polls the task and, between polls, runs the queue
## (`RenderingServer.force_sync()`: `command_queue.flush_all()` on the main
## thread in the default model; with the separate render thread it waits for
## that thread, which serves the workers itself), so a worker's synchronous
## call is answered and the task can finish. The wait for the task itself is
## then immediate. Off the main thread it is the plain wait.
##
## Every main-thread wait in the client goes through here, or says on its line
## why it cannot meet the RenderingServer (`# pool-wait: resource-free`, a task
## that only reads data); pool_wait_lint_test.gd holds that.

## Round 760's review:
## - F5: with the separate render thread that thread serves the workers'
##   queued calls itself, and `force_sync` there is a whole round trip through
##   it (`command_queue.sync()`, a frame's draw included; READ
##   rendering_server_default.cpp l. 435-441) -- so PoolWait is the plain wait
##   there, as the engine's own ResourceLoader wait is ("Not needed",
##   resource_loader.cpp l. 1157-1163). MEASURED round 760: the deadlock
##   probe's plain wait finished 2 of 2 on the separate thread.
## - F4: an id already waited for is "Invalid Task ID" to is_task_completed,
##   which then returns false for ever (READ worker_thread_pool.cpp l.
##   393-398), so a double wait would spin. After LIMIT_MSEC of polling the
##   wait logs once and falls through to the plain wait, which returns at once
##   for an unknown id (ERR_INVALID_PARAMETER) and otherwise waits as before.
##   The poll slows to POLL_MAX_USEC after a second, so such a wait prints
##   about 13,000 engine errors, not 300,000 (rare by the lint's audit: every
##   site resets its id after the wait).

## The poll interval (OURS): short against a task's length, long enough not to
## spin a core; POLL_MAX_USEC after SLOW_AFTER_MSEC of waiting.
const POLL_USEC := 100
const POLL_MAX_USEC := 10000
const SLOW_AFTER_MSEC := 1000
## How long a wait polls before it falls through (OURS: far above any task's
## length -- the longest MEASURED blocking wait is a world entry's cell drain,
## a few seconds).
const LIMIT_MSEC := 30000
## The limit in force (tests shorten it).
static var limit_msec := LIMIT_MSEC

## Whether the RenderingServer has its own thread (asked once: the model is
## fixed for the process).
static var _threaded := -1

static func _serves_main() -> bool:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return false
	if _threaded < 0:
		_threaded = 1 if FrameSplit.render_threaded() else 0
	return _threaded == 0

static func task(id: int) -> void:
	if id < 0:
		return
	if _serves_main():
		var start := Time.get_ticks_msec()
		while not WorkerThreadPool.is_task_completed(id):
			if Time.get_ticks_msec() - start > limit_msec:
				push_warning("PoolWait: task %d not complete after %d ms (or already waited for) -- the plain wait now" % [id, limit_msec])
				break
			RenderingServer.force_sync()
			OS.delay_usec(POLL_USEC if Time.get_ticks_msec() - start < SLOW_AFTER_MSEC else POLL_MAX_USEC)
	WorkerThreadPool.wait_for_task_completion(id) # pool-wait: completed above, or the render thread serves the workers

static func group(id: int) -> void:
	if id < 0:
		return
	if _serves_main():
		var start := Time.get_ticks_msec()
		while not WorkerThreadPool.is_group_task_completed(id):
			if Time.get_ticks_msec() - start > limit_msec:
				push_warning("PoolWait: group %d not complete after %d ms (or already waited for) -- the plain wait now" % [id, limit_msec])
				break
			RenderingServer.force_sync()
			OS.delay_usec(POLL_USEC if Time.get_ticks_msec() - start < SLOW_AFTER_MSEC else POLL_MAX_USEC)
	WorkerThreadPool.wait_for_group_task_completion(id) # pool-wait: completed above, or the render thread serves the workers
