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

## The poll interval (OURS): short against a task's length, long enough not to
## spin a core.
const POLL_USEC := 100

static func task(id: int) -> void:
	if id < 0:
		return
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		while not WorkerThreadPool.is_task_completed(id):
			RenderingServer.force_sync()
			OS.delay_usec(POLL_USEC)
	WorkerThreadPool.wait_for_task_completion(id) # pool-wait: completed above

static func group(id: int) -> void:
	if id < 0:
		return
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		while not WorkerThreadPool.is_group_task_completed(id):
			RenderingServer.force_sync()
			OS.delay_usec(POLL_USEC)
	WorkerThreadPool.wait_for_group_task_completion(id) # pool-wait: completed above
