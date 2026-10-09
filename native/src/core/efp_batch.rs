//! Many effects stepped at once (round 763): EfpSimBatch (client/scripts/efp/efp_sim_batch.gd) in
//! Rust, on the pool's threads (pool.rs) and the calling thread.
//!
//! **The global particle cap decides as the main thread did** (round 761's rule, unchanged): effect
//! i's spawn at its own change d is taken iff `base_i + d < limit_i`, base_i being live_total at the
//! batch's start plus the whole advance's change of every effect before it in the list. The job
//! answers that for effect i from what it knows of base_i (`admit`): the exact change of the
//! effects before it that finished, and for the rest the bounds each publishes when it starts
//! (Sim::growth_bounds), with base_(j+1) <= max(base_j, limit_j) since a spawn is only taken below
//! the limit. Decided, the spawn goes on; undecided, the thread waits on the job's condition
//! variable (woken by every bound published and every effect finished: round 761's review F1) until
//! it is. Effects are claimed in list order, so every effect before i is already being stepped and
//! the first unfinished one never waits: no deadlock with any number of helpers, none included.
//! Every decision is the sequential one, and so is every particle.
//!
//! After an effect's advance its outputs (efp_out.rs) are built on the same thread when it stepped.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use super::efp_out::Outputs;
use super::efp_sim::{Gate, Quality, Sim};
use super::gdmath::B3;
use super::pool::{lock, wait, Pool, Task};

/// One effect as the batch holds it: its simulation and what it draws.
pub struct SimBox {
    pub sim: Sim,
    pub out: Outputs,
    /// Round 763's review, M1: a panic while this effect was stepped. A broken effect is never
    /// stepped again (it holds still), and the client turns the native simulation off for the
    /// session (EfpSimNative.run_batch).
    pub broken: bool,
    /// QA (SrEfpSim.qa_panic_next_step): panic in this effect's next batch step, to prove a panic
    /// neither hangs the caller nor poisons anything for good (efp_native_test).
    pub panic_next: bool,
}

impl SimBox {
    pub fn new(sim: Sim) -> SimBox {
        SimBox { sim, out: Outputs::default(), broken: false, panic_next: false }
    }
}

pub type Shared = Arc<Mutex<SimBox>>;

struct JobState {
    least: Vec<i64>,
    most: Vec<i64>,
    fin: Vec<bool>,
    change: Vec<i64>,
    steps: Vec<i64>,
    prefix_n: usize,
    prefix_base: i64,
    done: usize,
    ver: u64,
    waits: i64,
    wait_ns: u128,
    misses: i64,
    by_helpers: i64,
    bounds_ns: u128,
    sim_ns: u128,
    /// The first panic of the batch (M1).
    failed: Option<String>,
}

pub struct Job {
    sims: Vec<Shared>,
    delta: f64,
    limits: Vec<i64>,
    keeps: Vec<bool>,
    cams: Vec<B3>,
    quality: Quality,
    n: usize,
    next: AtomicUsize,
    st: Mutex<JobState>,
    cv: Condvar,
}

/// What a batch did, per effect and in all.
#[derive(Debug, Default, Clone)]
pub struct Report {
    pub steps: Vec<i64>,
    /// Per effect after the batch: age, dropped, spawned, revived, particle count.
    pub counters: Vec<i64>,
    pub change: Vec<i64>,
    pub waits: i64,
    pub wait_us: i64,
    pub misses: i64,
    pub by_helpers: i64,
    pub bounds_us: i64,
    pub sim_us: i64,
    /// The work estimate (particle-steps) and whether the pool was used (L2).
    pub work: i64,
    pub pooled: bool,
}

struct JobGate<'a> {
    job: &'a Job,
    i: usize,
}

impl Gate for JobGate<'_> {
    fn admit(&mut self, d: i64) -> (i64, i64) {
        self.job.admit(self.i, d)
    }
}

/// A panic payload as text.
fn panic_text(e: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = e.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = e.downcast_ref::<String>() {
        s.clone()
    } else {
        "a panic".to_string()
    }
}

impl Job {
    /// EfpSimBatch.Job.admit: (limit - hi, limit - lo) once d is decided by them.
    fn admit(&self, i: usize, d: i64) -> (i64, i64) {
        let limit = self.limits[i];
        let mut t0: Option<Instant> = None;
        let mut st = lock(&self.st);
        loop {
            let mut lo = st.prefix_base;
            let mut hi = st.prefix_base;
            for j in st.prefix_n..i {
                if st.fin[j] {
                    lo += st.change[j];
                    hi += st.change[j];
                } else {
                    lo += st.least[j];
                    hi = (hi + st.most[j]).min(hi.max(self.limits[j]));
                }
            }
            let sure = (limit - hi, limit - lo);
            if d < sure.0 || d >= sure.1 {
                if let Some(t) = t0 {
                    st.waits += 1;
                    st.wait_ns += t.elapsed().as_nanos();
                }
                return sure;
            }
            if t0.is_none() {
                t0 = Some(Instant::now());
            }
            let seen = st.ver;
            while st.ver == seen {
                st = wait(&self.cv, st);
            }
        }
    }

    /// Effect i finished (or failed): its change recorded, the finished prefix walked forward,
    /// every waiter woken. A second call for the same effect changes nothing but `extra`'s.
    fn finish(&self, i: usize, d: i64, steps: i64, extra: impl FnOnce(&mut JobState)) {
        {
            let mut st = lock(&self.st);
            if !st.fin[i] {
                st.fin[i] = true;
                st.change[i] = d;
                st.steps[i] = steps;
                while st.prefix_n < self.n && st.fin[st.prefix_n] {
                    let k = st.prefix_n;
                    st.prefix_base += st.change[k];
                    st.prefix_n += 1;
                }
                st.done += 1;
            }
            st.ver += 1;
            extra(&mut st);
        }
        self.cv.notify_all();
    }

    fn step(&self, i: usize, helper: bool) {
        let mut bx = lock(&self.sims[i]);
        let bx = &mut *bx;
        if bx.broken {
            self.finish(i, 0, 0, |_| {});
            return;
        }
        if bx.panic_next {
            bx.panic_next = false;
            panic!("QA: a deliberate panic (SrEfpSim.qa_panic_next_step)");
        }
        let t0 = Instant::now();
        let b = bx.sim.growth_bounds(self.delta);
        let t1 = Instant::now();
        {
            let mut st = lock(&self.st);
            st.least[i] = b.0;
            st.most[i] = b.1;
            st.ver += 1;
        }
        self.cv.notify_all();
        bx.sim.keep = self.keeps[i];
        bx.sim.quality = self.quality;
        bx.sim.begin();
        let steps = bx.sim.advance(self.delta, &mut JobGate { job: self, i });
        let d = bx.sim.live_delta;
        let t2 = Instant::now();
        if steps > 0 {
            bx.out.build(&bx.sim, &self.cams[i]);
        }
        self.finish(i, d, steps, |st| {
            if d < b.0 || d > b.1 {
                st.misses += 1;
            }
            if helper {
                st.by_helpers += 1;
            }
            st.bounds_ns += (t1 - t0).as_nanos();
            st.sim_ns += (t2 - t1).as_nanos();
        });
    }

    /// Round 763's review, M1: `step` with its panic caught. The effect is marked broken (its
    /// mutex, poisoned by the panic, is recovered), it counts as finished with no change so
    /// nothing waits on it, and the batch reports the failure.
    fn step_guarded(&self, i: usize, helper: bool) {
        if let Err(e) = catch_unwind(AssertUnwindSafe(|| self.step(i, helper))) {
            let msg = format!("effect {i}: {}", panic_text(&*e));
            lock(&self.sims[i]).broken = true;
            self.finish(i, 0, 0, |st| {
                if st.failed.is_none() {
                    st.failed = Some(msg);
                }
            });
        }
    }

    fn claim(&self) -> Option<usize> {
        let i = self.next.fetch_add(1, Ordering::SeqCst);
        if i < self.n {
            Some(i)
        } else {
            None
        }
    }
}

/// A pool thread's share: effects until none is left.
struct Helper(Arc<Job>);

impl Task for Helper {
    fn help(&self) {
        while let Some(i) = self.0.claim() {
            self.0.step_guarded(i, true);
        }
    }
}

/// Round 763's review, L2: below this many particle-steps (`work_of`) a batch runs on the calling
/// thread alone. A helper descheduled on a busy machine holds the caller up for a time slice,
/// which a small batch cannot win back (MEASURED: docs/rounds/r763.md section 9). The client
/// passes it (EfpSimNative.POOL_MIN_WORK, OPENSRO_EFP_POOL_MIN_WORK).
pub const POOL_MIN_WORK: i64 = 4000;

/// The batch's work estimate: per effect (particles + 1) x the frames it will step.
pub fn work_of(sims: &[Shared], delta: f64) -> i64 {
    sims.iter()
        .map(|s| {
            let b = lock(s);
            (b.sim.count() as i64 + 1) * b.sim.steps_for(delta)
        })
        .sum()
}

/// Steps every effect in `sims` by `delta` (their order is the cap's order). `base` is live_total
/// when the batch starts, `limits[i]` effect i's cap (EfpSim.limit_for), `keeps[i]` its kept flag,
/// `cams[i]` its camera rotation for the draws. Up to `helpers` pool threads join the calling
/// thread when the work is at least `min_work` particle-steps. Err when a sim is listed twice
/// (L1: the ordered admission could deadlock on its mutex) or when a step panicked (M1; the
/// batch still returns, every effect counted finished).
#[allow(clippy::too_many_arguments)]
pub fn run(
    pool: &Pool,
    sims: Vec<Shared>,
    delta: f64,
    base: i64,
    limits: Vec<i64>,
    keeps: Vec<bool>,
    cams: Vec<B3>,
    quality: Quality,
    helpers: usize,
    min_work: i64,
) -> Result<Report, String> {
    let n = sims.len();
    for i in 0..n {
        for j in 0..i {
            if Arc::ptr_eq(&sims[i], &sims[j]) {
                return Err(format!("effect {j} is listed again at {i}"));
            }
        }
    }
    let mut least = Vec::with_capacity(n);
    let mut most = Vec::with_capacity(n);
    for s in &sims {
        // Until an effect publishes its own: all of its particles may die, and it may fill up.
        let c = lock(s).sim.count() as i64;
        least.push(-c);
        most.push(super::efp_sim::MAX_PARTICLES - c);
    }
    let work = work_of(&sims, delta);
    let job = Arc::new(Job {
        sims,
        delta,
        limits,
        keeps,
        cams,
        quality,
        n,
        next: AtomicUsize::new(0),
        st: Mutex::new(JobState {
            least,
            most,
            fin: vec![false; n],
            change: vec![0; n],
            steps: vec![0; n],
            prefix_n: 0,
            prefix_base: base,
            done: 0,
            ver: 0,
            waits: 0,
            wait_ns: 0,
            misses: 0,
            by_helpers: 0,
            bounds_ns: 0,
            sim_ns: 0,
            failed: None,
        }),
        cv: Condvar::new(),
    });
    let helpers = if n > 1 && work >= min_work { helpers.min(n - 1) } else { 0 };
    if helpers > 0 {
        let task: Arc<dyn Task> = Arc::new(Helper(job.clone()));
        pool.post(task, helpers);
    }
    while let Some(i) = job.claim() {
        job.step_guarded(i, false);
    }
    {
        let mut st = lock(&job.st);
        while st.done < n {
            st = wait(&job.cv, st);
        }
    }
    if helpers > 0 {
        pool.finish();
    }
    let st = lock(&job.st);
    if let Some(e) = &st.failed {
        return Err(e.clone());
    }
    let mut counters = Vec::with_capacity(5 * n);
    for s in &job.sims {
        let b = lock(s);
        counters.extend_from_slice(&[b.sim.age, b.sim.dropped, b.sim.spawned, b.sim.revived, b.sim.count() as i64]);
    }
    Ok(Report {
        steps: st.steps.clone(),
        counters,
        change: st.change.clone(),
        waits: st.waits,
        wait_us: (st.wait_ns / 1000) as i64,
        misses: st.misses,
        by_helpers: st.by_helpers,
        bounds_us: (st.bounds_ns / 1000) as i64,
        sim_us: (st.sim_ns / 1000) as i64,
        work,
        pooled: helpers > 0,
    })
}

#[cfg(test)]
mod tests {
    use super::super::efp_sim::{Cmd, ExactGate, Template, Tpl, K_CONEPOS, LIFE_EXTINCT, LIFE_LOOP};
    use super::*;

    fn tmpl(k: usize) -> Arc<Template> {
        let cone = Cmd { kind: K_CONEPOS, space: 0, v: [1.0, 3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], f: 0.0, color: 0 };
        let frames = 20 + (k % 7) as i64 * 5;
        let (int, max, per) = match k % 3 {
            0 => (20, 200, 60.0),
            1 => (1, 40, 2.0),
            _ => (3, 30, 5.5),
        };
        let mut root = Tpl {
            parent: -1,
            frames,
            life: if k % 4 == 3 { LIFE_LOOP } else { LIFE_EXTINCT },
            has_emit: true,
            e_dur: 100000,
            e_int: int,
            e_max: max,
            e_per: per,
            ..Default::default()
        };
        root.schedule = vec![Vec::new(); frames as usize];
        root.schedule[0].push(cone);
        let r = (per as i64 + 2).min(max);
        Arc::new(Template { tpls: vec![root], rate: vec![r], kids: vec![0], fan: vec![r], fan_child: 0, has_fan: true })
    }

    fn make(n: usize) -> Vec<Shared> {
        (0..n).map(|i| Arc::new(Mutex::new(SimBox::new(Sim::new(tmpl(i), 1000 + i as u64))))).collect()
    }

    /// The batch at every pool size gives what stepping the effects one after another gives, with
    /// the cap binding.
    #[test]
    fn batch_equals_sequential_with_the_cap_binding() {
        let pool = Pool::new();
        for &(n, fps, cap) in &[(8usize, 37.0, 200i64), (33, 15.0, 1400), (60, 30.0, 1400)] {
            // sequential reference
            let seq = make(n);
            let mut live = 0i64;
            let mut hist = Vec::new();
            for f in 0..300 {
                let delta = if f == 77 { 0.3 } else { 1.0 / fps };
                let mut row = Vec::new();
                for s in &seq {
                    let mut b = s.lock().unwrap();
                    b.sim.keep = true;
                    b.sim.begin();
                    let mut g = ExactGate { below: cap - live };
                    b.sim.advance(delta, &mut g);
                    live += b.sim.live_delta;
                    row.push((b.sim.count(), b.sim.spawned, b.sim.dropped));
                }
                hist.push(row);
            }
            assert!(live >= cap - 40, "the cap should bind: {live}");
            for helpers in [0usize, 1, 3, 7] {
                pool.set_helpers(helpers);
                let par = make(n);
                let mut live = 0i64;
                for (f, want) in hist.iter().enumerate() {
                    let delta = if f == 77 { 0.3 } else { 1.0 / fps };
                    // min_work 0: the pool is used whenever helpers are given (the threshold is
                    // tested below).
                    let r = run(&pool, par.clone(), delta, live, vec![cap; n], vec![true; n], vec![super::super::gdmath::IDENTITY; n], Quality::default(), helpers, 0)
                        .unwrap();
                    assert_eq!(r.misses, 0);
                    live += r.change.iter().sum::<i64>();
                    for (i, s) in par.iter().enumerate() {
                        let b = s.lock().unwrap();
                        assert_eq!((b.sim.count(), b.sim.spawned, b.sim.dropped), want[i], "n {n} helpers {helpers} frame {f} sim {i}");
                    }
                }
            }
        }
    }

    fn run_all(pool: &Pool, sims: &[Shared], helpers: usize, min_work: i64) -> Result<Report, String> {
        let n = sims.len();
        run(pool, sims.to_vec(), 1.0 / 20.0, 0, vec![1 << 30; n], vec![true; n], vec![super::super::gdmath::IDENTITY; n], Quality::default(), helpers, min_work)
    }

    /// Round 763's review, M1: a panic in a step -- on the caller or on a pool thread, its effect's
    /// mutex poisoned -- never hangs the caller: the batch returns Err, the effect is broken, every
    /// other effect still steps, and the next batch (the broken one held still) runs as usual.
    #[test]
    fn a_panic_returns_an_error_and_never_hangs() {
        let pool = Arc::new(Pool::new());
        pool.set_helpers(3);
        for (victim, helpers) in [(0usize, 0usize), (5, 3), (15, 3), (9, 1)] {
            let sims = make(16);
            for _ in 0..5 {
                run_all(&pool, &sims, helpers, 0).unwrap();
            }
            lock(&sims[victim]).panic_next = true;
            let (tx, rx) = std::sync::mpsc::channel();
            let (p2, s2) = (pool.clone(), sims.clone());
            std::thread::spawn(move || {
                let r = run_all(&p2, &s2, helpers, 0);
                let _ = tx.send(r);
            });
            let r = rx.recv_timeout(std::time::Duration::from_secs(10)).expect("the batch hung after a panic");
            let e = r.expect_err("a panic must be reported");
            assert!(e.contains("deliberate panic"), "{e}");
            assert!(lock(&sims[victim]).broken);
            // The next batch runs (no poisoned lock panics again) and the broken effect holds still.
            let before = lock(&sims[victim]).sim.age;
            let r = run_all(&pool, &sims, helpers, 0).unwrap();
            assert_eq!(r.steps[victim], 0);
            assert_eq!(lock(&sims[victim]).sim.age, before);
            assert!(r.steps.iter().enumerate().any(|(i, &s)| i != victim && s > 0));
        }
        // The pool's threads all survived: a job still gets every helper.
        let sims = make(32);
        let r = run_all(&pool, &sims, 3, 0).unwrap();
        assert!(r.pooled);
    }

    /// Round 763's review, L1: a sim listed twice is refused (its mutex would deadlock the
    /// ordered admission under a binding limit).
    #[test]
    fn a_sim_listed_twice_is_refused() {
        let pool = Pool::new();
        let mut sims = make(4);
        sims.push(sims[1].clone());
        assert!(run_all(&pool, &sims, 0, 0).is_err());
    }

    /// Round 763's review, L2: a batch whose work is under the threshold runs on the caller alone;
    /// over it, on the pool. Both step the same.
    #[test]
    fn small_batches_run_inline() {
        let pool = Pool::new();
        pool.set_helpers(3);
        let a = make(8);
        let b = make(8);
        for _ in 0..40 {
            let ra = run_all(&pool, &a, 3, i64::MAX).unwrap();
            let rb = run_all(&pool, &b, 3, 0).unwrap();
            assert!(!ra.pooled && ra.by_helpers == 0);
            assert!(rb.pooled);
            assert_eq!(ra.counters, rb.counters);
        }
    }

    /// Round 763's review, L3: a huge emission count is refused all at once past MAX_PARTICLES,
    /// fast, with the same dropped count and accumulator as one by one.
    #[test]
    fn a_huge_emission_is_refused_at_once() {
        let mut root = Tpl { parent: -1, frames: 40, life: LIFE_EXTINCT, has_emit: true, e_dur: 100000, e_int: 1, e_max: 1 << 30, e_per: 5.0e8, ..Default::default() };
        root.schedule = vec![Vec::new(); 40];
        let t = Arc::new(Template { tpls: vec![root], ..Default::default() });
        let mut s = Sim::new(t, 3);
        let t0 = Instant::now();
        for _ in 0..10 {
            s.begin();
            s.advance(0.05, &mut ExactGate { below: 1 << 40 });
        }
        assert!(t0.elapsed().as_secs_f64() < 1.0, "the refusals were not folded");
        assert_eq!(s.count() as i64, super::super::efp_sim::MAX_PARTICLES);
        assert!(s.dropped > 1_000_000_000);
    }

    /// Round 763's review, L4: a multiplied interval that wraps to 0 fires nothing, no panic.
    #[test]
    fn a_wrapped_interval_fires_nothing() {
        let mut root = Tpl { parent: -1, frames: 10, life: LIFE_EXTINCT, has_emit: true, e_dur: i32::MAX as i64, e_int: 1 << 30, e_max: 10, e_per: 1.0, ..Default::default() };
        root.schedule = vec![Vec::new(); 10];
        let t = Arc::new(Template { tpls: vec![root], rate: vec![3], kids: vec![0], fan: vec![3], fan_child: 0, has_fan: true });
        let mut s = Sim::new(t, 3);
        s.quality = Quality { interval_mul: 4, threshold: 0 };
        for _ in 0..20 {
            let _ = s.growth_bounds(0.05);
            s.begin();
            s.advance(0.05, &mut ExactGate { below: 1 << 40 });
        }
        assert_eq!(s.count(), 0);
    }
}
