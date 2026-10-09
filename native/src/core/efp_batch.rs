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

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use super::efp_out::Outputs;
use super::efp_sim::{Gate, Quality, Sim};
use super::gdmath::B3;
use super::pool::{Pool, Task};

/// One effect as the batch holds it: its simulation and what it draws.
pub struct SimBox {
    pub sim: Sim,
    pub out: Outputs,
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

impl Job {
    /// EfpSimBatch.Job.admit: (limit - hi, limit - lo) once d is decided by them.
    fn admit(&self, i: usize, d: i64) -> (i64, i64) {
        let limit = self.limits[i];
        let mut t0: Option<Instant> = None;
        let mut st = self.st.lock().unwrap();
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
                st = self.cv.wait(st).unwrap();
            }
        }
    }

    fn step(&self, i: usize, helper: bool) {
        let mut bx = self.sims[i].lock().unwrap();
        let bx = &mut *bx;
        let t0 = Instant::now();
        let b = bx.sim.growth_bounds(self.delta);
        let t1 = Instant::now();
        {
            let mut st = self.st.lock().unwrap();
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
        {
            let mut st = self.st.lock().unwrap();
            st.fin[i] = true;
            st.change[i] = d;
            st.steps[i] = steps;
            if d < b.0 || d > b.1 {
                st.misses += 1;
            }
            while st.prefix_n < self.n && st.fin[st.prefix_n] {
                let k = st.prefix_n;
                st.prefix_base += st.change[k];
                st.prefix_n += 1;
            }
            st.done += 1;
            st.ver += 1;
            if helper {
                st.by_helpers += 1;
            }
            st.bounds_ns += (t1 - t0).as_nanos();
            st.sim_ns += (t2 - t1).as_nanos();
        }
        self.cv.notify_all();
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
            self.0.step(i, true);
        }
    }
}

/// Steps every effect in `sims` by `delta` (their order is the cap's order). `base` is live_total
/// when the batch starts, `limits[i]` effect i's cap (EfpSim.limit_for), `keeps[i]` its kept flag,
/// `cams[i]` its camera rotation for the draws. `helpers` pool threads join the calling thread.
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
) -> Report {
    let n = sims.len();
    let mut least = Vec::with_capacity(n);
    let mut most = Vec::with_capacity(n);
    for s in &sims {
        // Until an effect publishes its own: all of its particles may die, and it may fill up.
        let c = s.lock().unwrap().sim.count() as i64;
        least.push(-c);
        most.push(super::efp_sim::MAX_PARTICLES - c);
    }
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
        }),
        cv: Condvar::new(),
    });
    let helpers = if n > 1 { helpers.min(n - 1) } else { 0 };
    if helpers > 0 {
        let task: Arc<dyn Task> = Arc::new(Helper(job.clone()));
        // The calling thread takes effects as a helper would, but counted as itself.
        pool.run(task, helpers);
    }
    while let Some(i) = job.claim() {
        job.step(i, false);
    }
    let mut st = job.st.lock().unwrap();
    while st.done < n {
        st = job.cv.wait(st).unwrap();
    }
    let mut counters = Vec::with_capacity(5 * n);
    for s in &job.sims {
        let b = s.lock().unwrap();
        counters.extend_from_slice(&[b.sim.age, b.sim.dropped, b.sim.spawned, b.sim.revived, b.sim.count() as i64]);
    }
    Report {
        steps: st.steps.clone(),
        counters,
        change: st.change.clone(),
        waits: st.waits,
        wait_us: (st.wait_ns / 1000) as i64,
        misses: st.misses,
        by_helpers: st.by_helpers,
        bounds_us: (st.bounds_ns / 1000) as i64,
        sim_us: (st.sim_ns / 1000) as i64,
    }
}

#[cfg(test)]
mod tests {
    use super::super::efp_sim::{ExactGate, Template, Tpl, Cmd, K_CONEPOS, LIFE_EXTINCT, LIFE_LOOP};
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
        (0..n).map(|i| Arc::new(Mutex::new(SimBox { sim: Sim::new(tmpl(i), 1000 + i as u64), out: Outputs::default() }))).collect()
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
                    let r = run(&pool, par.clone(), delta, live, vec![cap; n], vec![true; n], vec![super::super::gdmath::IDENTITY; n], Quality::default(), helpers);
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
}
