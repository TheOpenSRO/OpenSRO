//! A small persistent worker pool (round 763) for the effect batch (efp_batch.rs): `helpers`
//! threads that sleep on a condition variable between batches and join the caller's job when it is
//! posted. The caller always works on the job itself, so a pool of 0 helpers (one core) runs
//! everything on the calling thread, and a helper that wakes late finds nothing left and returns.
//!
//! Sizing is the client's (EfpSimNative.configure): the batch runs while Godot's main thread waits
//! for it, so the pool is bounded by Godot's own WorkerThreadPool size and the machine's cores, and
//! never takes more threads than those leave (native/README.md, "The effect simulation").

use std::sync::{Arc, Condvar, Mutex};
use std::thread;

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
        self.inner.m.lock().unwrap().target
    }

    /// Sets the number of helper threads: starts the missing ones; the extra ones (index >= n)
    /// end at once and are joined, so the pool never runs more than `n`.
    pub fn set_helpers(&self, n: usize) {
        let mut threads = self.threads.lock().unwrap();
        {
            let mut st = self.inner.m.lock().unwrap();
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
            self.inner.m.lock().unwrap().target = threads.len();
        }
    }

    /// Posts `job` to up to `helpers` threads and works on it on this thread too. Returns when this
    /// thread's `help` returns; the job itself says when it is finished (efp_batch waits for that).
    pub fn run(&self, job: Arc<dyn Task>, helpers: usize) {
        let want = {
            let mut st = self.inner.m.lock().unwrap();
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
        job.help();
    }
}

fn worker(inner: Arc<Inner>, idx: usize) {
    let mut seen = { inner.m.lock().unwrap().epoch };
    loop {
        let job = {
            let mut st = inner.m.lock().unwrap();
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
                st = inner.cv.wait(st).unwrap();
            }
            seen = st.epoch;
            st.taken += 1;
            st.job.clone()
        };
        if let Some(j) = job {
            j.help();
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
                pool.run(job.clone(), helpers);
                // The caller's help returns when every item is claimed; claimed items may still be
                // in flight on a helper, so spin until the sum is complete.
                while job.sum.load(Ordering::SeqCst) != 1000 * 999 / 2 {
                    std::hint::spin_loop();
                }
            }
        }
    }
}
