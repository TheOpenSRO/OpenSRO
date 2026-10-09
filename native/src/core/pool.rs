//! A small persistent worker pool (round 763) for the effect batch (efp_batch.rs): `helpers`
//! threads that sleep on a condition variable between batches and join the caller's job when it is
//! posted. The caller always works on the job itself, so a pool of 0 helpers (one core) runs
//! everything on the calling thread, and a helper that wakes late finds nothing left and returns.
//!
//! Round 763's review: a panic in a job never kills a pool thread (`worker` catches it; the job
//! itself records it, efp_batch.rs), every lock survives a poisoned mutex (`lock` / `wait`), and
//! the posted job is dropped once the batch ends (`finish`), so it keeps no effect alive (L6).
//!
//! Sizing is the client's (EfpSimNative.configure): the batch runs while Godot's main thread waits
//! for it, so the pool is bounded by Godot's own WorkerThreadPool size and the machine's cores, and
//! never takes more threads than those leave (native/README.md, "The effect simulation").

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;

/// A mutex's lock that survives a panic of an earlier holder (the data is plain and each user
/// re-checks it; a poisoned lock must never turn one bug into a hang or a panic every frame).
pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Condvar::wait with the same tolerance.
pub fn wait<'a, T>(cv: &Condvar, g: MutexGuard<'a, T>) -> MutexGuard<'a, T> {
    cv.wait(g).unwrap_or_else(PoisonError::into_inner)
}

/// A job the pool's threads help with: `help` takes work until none is left.
pub trait Task: Send + Sync {
    fn help(&self);
}

struct State {
    job: Option<Arc<dyn Task>>,
    epoch: u64,
    /// Helpers wanted for the current job, and how many took it.
    want: usize,
    taken: usize,
    /// Threads that should exist; one with a higher index exits.
    target: usize,
}

struct Inner {
    m: Mutex<State>,
    cv: Condvar,
}

pub struct Pool {
    inner: Arc<Inner>,
    threads: Mutex<Vec<thread::JoinHandle<()>>>,
}

impl Default for Pool {
    fn default() -> Self {
        Pool::new()
    }
}

impl Pool {
    pub fn new() -> Pool {
        Pool {
            inner: Arc::new(Inner {
                m: Mutex::new(State { job: None, epoch: 0, want: 0, taken: 0, target: 0 }),
                cv: Condvar::new(),
            }),
            threads: Mutex::new(Vec::new()),
        }
    }

    /// Helper threads (the caller of `run` is one more participant).
    pub fn helpers(&self) -> usize {
        lock(&self.inner.m).target
    }

    /// Sets the number of helper threads: starts the missing ones; the extra ones (index >= n)
    /// end at once and are joined, so the pool never runs more than `n`.
    pub fn set_helpers(&self, n: usize) {
        let mut threads = lock(&self.threads);
        {
            let mut st = lock(&self.inner.m);
            st.target = n;
        }
        self.inner.cv.notify_all();
        while threads.len() > n {
            if let Some(h) = threads.pop() {
                let _ = h.join();
            }
        }
        while threads.len() < n {
            let idx = threads.len();
            let inner = self.inner.clone();
            match thread::Builder::new().name(format!("opensro-efp-{idx}")).spawn(move || worker(inner, idx)) {
                Ok(h) => threads.push(h),
                Err(_) => break,
            }
        }
        if threads.len() < n {
            // The system refused a thread: run with what started.
            lock(&self.inner.m).target = threads.len();
        }
    }

    /// Posts `job` to up to `helpers` threads and returns at once: the caller works on the job
    /// itself (efp_batch's claim loop), and the job says when it is finished. Call `finish` after.
    pub fn post(&self, job: Arc<dyn Task>, helpers: usize) {
        let want = {
            let mut st = lock(&self.inner.m);
            let want = helpers.min(st.target);
            if want > 0 {
                st.job = Some(job.clone());
                st.epoch = st.epoch.wrapping_add(1);
                st.want = want;
                st.taken = 0;
            }
            want
        };
        for _ in 0..want {
            self.inner.cv.notify_one();
        }
    }

    /// The batch is over: the pool drops its reference to the job (round 763's review, L6). A
    /// helper that wakes late finds no job and goes back to sleep.
    pub fn finish(&self) {
        lock(&self.inner.m).job = None;
    }
}

fn worker(inner: Arc<Inner>, idx: usize) {
    let mut seen = { lock(&inner.m).epoch };
    loop {
        let job = {
            let mut st = lock(&inner.m);
            loop {
                if idx >= st.target {
                    return;
                }
                if st.epoch != seen && st.taken < st.want {
                    break;
                }
                if st.epoch != seen {
                    // This job has its helpers; wait for the next one.
                    seen = st.epoch;
                }
                st = wait(&inner.cv, st);
            }
            seen = st.epoch;
            st.taken += 1;
            st.job.clone()
        };
        if let Some(j) = job {
            // Round 763's review, M1: a panic must not end this thread while `target` still
            // counts it; the job records its own failure (efp_batch.rs).
            let _ = catch_unwind(AssertUnwindSafe(|| j.help()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Count {
        next: AtomicUsize,
        n: usize,
        sum: AtomicUsize,
    }
    impl Task for Count {
        fn help(&self) {
            loop {
                let i = self.next.fetch_add(1, Ordering::SeqCst);
                if i >= self.n {
                    return;
                }
                self.sum.fetch_add(i, Ordering::SeqCst);
            }
        }
    }

    #[test]
    fn every_item_once_any_size() {
        let pool = Pool::new();
        for helpers in [0usize, 1, 3, 7, 2, 0, 5] {
            pool.set_helpers(helpers);
            for _ in 0..50 {
                let job = Arc::new(Count { next: AtomicUsize::new(0), n: 1000, sum: AtomicUsize::new(0) });
                pool.post(job.clone(), helpers);
                job.help();
                pool.finish();
                // The caller's help returns when every item is claimed; claimed items may still be
                // in flight on a helper, so spin until the sum is complete.
                while job.sum.load(Ordering::SeqCst) != 1000 * 999 / 2 {
                    std::hint::spin_loop();
                }
            }
        }
    }

    struct Boom;
    impl Task for Boom {
        fn help(&self) {
            panic!("a job that panics on every thread");
        }
    }

    struct Who(Arc<Count>, Arc<Mutex<std::collections::HashSet<String>>>);
    impl Task for Who {
        fn help(&self) {
            lock(&self.1).insert(std::thread::current().name().unwrap_or("").to_string());
            std::thread::sleep(std::time::Duration::from_millis(20));
            self.0.help();
        }
    }

    /// Round 763's review, M1: a job that panics on a pool thread does not end that thread; the
    /// next job still gets every helper.
    #[test]
    fn a_panicking_job_keeps_the_threads() {
        let pool = Pool::new();
        pool.set_helpers(3);
        let boom: Arc<dyn Task> = Arc::new(Boom);
        pool.post(boom, 3);
        std::thread::sleep(std::time::Duration::from_millis(100));
        pool.finish();
        let job = Arc::new(Count { next: AtomicUsize::new(0), n: 100_000, sum: AtomicUsize::new(0) });
        let seen = Arc::new(Mutex::new(std::collections::HashSet::new()));
        let t: Arc<dyn Task> = Arc::new(Who(job.clone(), seen.clone()));
        pool.post(t.clone(), 3);
        t.help();
        while job.sum.load(Ordering::SeqCst) != 100_000 * 99_999 / 2 {
            std::hint::spin_loop();
        }
        pool.finish();
        assert_eq!(pool.helpers(), 3);
        assert!(lock(&seen).iter().filter(|n| n.starts_with("opensro-efp-")).count() >= 2, "{:?}", lock(&seen));
    }
}
