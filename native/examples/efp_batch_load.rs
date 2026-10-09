//! Round 763's review, L2: the effect batch's wall time per frame on an idle and on a busy machine,
//! at 1, 2 and 4 threads, with and without the inline threshold (core::efp_batch::POOL_MIN_WORK).
//! Synthetic effects, no game data:
//!   cargo run --release --no-default-features --example efp_batch_load
//! "swarm": 36 effects of ~65 particles each, each stepping every 50 ms, batches at 90 fps (the
//! swarm at 4,000 standing: 36 masters, ~2,300 particles); "big": 74 effects, ~4,000 particles,
//! batches at 20 fps (every effect steps every batch). "busy": as many spinning threads as cores.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use opensro_native::core::efp_batch::{self, SimBox};
use opensro_native::core::efp_sim::{Cmd, Quality, Sim, Template, Tpl, K_CONEPOS, LIFE_EXTINCT};
use opensro_native::core::gdmath::IDENTITY;
use opensro_native::core::pool::Pool;

fn template(per: f64, frames: i64) -> Arc<Template> {
    let cone = Cmd { kind: K_CONEPOS, space: 0, v: [1.0, 3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], f: 0.0, color: 0 };
    let mut root = Tpl { parent: -1, frames, life: LIFE_EXTINCT, has_emit: true, e_dur: 1 << 30, e_int: 1, e_max: 300, e_per: per, ..Default::default() };
    root.schedule = vec![Vec::new(); frames as usize];
    root.schedule[0].push(cone);
    let r = (per as i64 + 2).min(300);
    Arc::new(Template { tpls: vec![root], rate: vec![r], kids: vec![0], fan: vec![r], fan_child: 0, has_fan: true })
}

fn make(n: usize, per: f64, frames: i64) -> Vec<efp_batch::Shared> {
    (0..n)
        .map(|i| {
            let mut s = Sim::new(template(per, frames), 1000 + i as u64);
            s.keep = true;
            // Each effect's 50 ms frames at its own phase (EquipFx's golden-ratio phases).
            s.acc = 0.05 * ((i as f64 * 0.618_034) % 1.0);
            Arc::new(Mutex::new(SimBox::new(s)))
        })
        .collect()
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[((v.len() as f64 * p) as usize).min(v.len() - 1)]
}

fn main() {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let pool = Pool::new();
    println!("cores {cores}; ms a batch: p50 / p99 / max (mean work, particle-steps; pooled share)");
    for (label, n, per, frames, fps) in [("swarm", 36usize, 3.25f64, 20i64, 90.0f64), ("big", 74, 2.7, 20, 20.0)] {
        for busy in [false, true] {
            let stop = Arc::new(AtomicBool::new(false));
            let mut spinners = Vec::new();
            if busy {
                for _ in 0..cores {
                    let st = stop.clone();
                    spinners.push(std::thread::spawn(move || {
                        let mut x = 0u64;
                        while !st.load(Ordering::Relaxed) {
                            x = x.wrapping_mul(6364136223846793005).wrapping_add(1);
                            std::hint::black_box(x);
                        }
                    }));
                }
            }
            for threads in [1usize, 2, 4] {
                for min_work in [0i64, efp_batch::POOL_MIN_WORK] {
                    if threads == 1 && min_work != 0 {
                        continue;
                    }
                    pool.set_helpers(threads - 1);
                    let sims = make(n, per, frames);
                    let delta = 1.0 / fps;
                    // Warm up to the steady state.
                    for _ in 0..(fps as usize * 3) {
                        efp_batch::run(&pool, sims.clone(), delta, 0, vec![1 << 30; n], vec![true; n], vec![IDENTITY; n], Quality::default(), threads - 1, min_work).unwrap();
                    }
                    let mut ms = Vec::new();
                    let mut work = 0i64;
                    let mut pooled = 0;
                    let batches = (fps as usize) * 20;
                    for _ in 0..batches {
                        let t0 = Instant::now();
                        let r = efp_batch::run(&pool, sims.clone(), delta, 0, vec![1 << 30; n], vec![true; n], vec![IDENTITY; n], Quality::default(), threads - 1, min_work).unwrap();
                        ms.push(t0.elapsed().as_secs_f64() * 1000.0);
                        work += r.work;
                        pooled += r.pooled as usize;
                    }
                    let max = ms.iter().cloned().fold(0.0, f64::max);
                    let (p50, p99) = (pct(&mut ms.clone(), 0.5), pct(&mut ms, 0.99));
                    println!(
                        "{label:5} {:4} threads {threads} {:12}: {p50:.3} / {p99:.3} / {max:.3} ({} work; pooled {:.0} %)",
                        if busy { "busy" } else { "idle" },
                        if min_work == 0 { "always pool" } else { "threshold" },
                        work / batches as i64,
                        100.0 * pooled as f64 / batches as f64
                    );
                }
            }
            stop.store(true, Ordering::Relaxed);
            for s in spinners {
                let _ = s.join();
            }
        }
    }
    pool.set_helpers(0);
}
