//! The particle simulation of one playing .efp effect (round 763): `EfpSim`'s per-frame stepping
//! (client/scripts/efp/efp_sim.gd), ported rule for rule so that an effect stepped here holds the
//! particles the GDScript holds, bit for bit. The rules, their READ / INFERRED / OURS labels and
//! the addresses they come from are efp_sim.gd's header; this file follows that code, not the
//! binary, and names the GDScript function each part mirrors.
//!
//! What is exact, and how:
//! - Vector3 / Basis arithmetic is f32 operation for operation (core/gdmath.rs); what GDScript keeps
//!   in a `float` (an emitter's accumulator, the step clock, the cone's angles, the scale graph's
//!   time) is f64 here.
//! - The random stream is Godot's RandomPCG (`RandomNumberGenerator`, gdmath::Pcg), drawn in
//!   GDScript's order.
//! - A dead particle stays readable while a younger one refers to it (GDScript's RefCounted
//!   particles): its children keep its frozen position and rotation as their parent's. Particles
//!   live in an arena, counted by the list and by their children, and freed at zero. An emitter
//!   whose owner died is dropped; a particle that still names it finds a stale generation and writes
//!   nothing (GDScript writes to the orphaned object, which nothing reads again).
//! - The global particle cap: a spawn at own change d is taken iff `base + d < limit`, base being
//!   live_total had every effect before this one advanced (EfpSimBatch's rule, round 761). The
//!   gate passed to `advance` answers it -- exactly for one effect, ordered for a batch
//!   (efp_batch.rs).
//!
//! Plain data, no Godot types: `cargo test` runs it, and a batch steps many on worker threads.

use std::sync::Arc;

use super::gdmath::{gmax, gmin, lerp64, Pcg, B3, IDENTITY, ONE, V3, ZERO};

pub const FRAME_SEC: f64 = 0.05;
pub const MAX_STEPS_PER_ADVANCE: i64 = 10;
pub const MAX_PARTICLES: i64 = 300;
pub const FAN_MAX: i64 = 1 << 20;

pub const LIFE_EXTINCT: u8 = 0;
pub const LIFE_LOOP: u8 = 1;
pub const LIFE_NEVER: u8 = 2;

// The command families, EfpSim's enum (K_POS = 0 ...).
pub const K_POS: u8 = 0;
pub const K_CONEPOS: u8 = 1;
pub const K_BANPOS: u8 = 2;
pub const K_SPHERE: u8 = 3;
pub const K_VEL: u8 = 4;
pub const K_CONEVEL: u8 = 5;
pub const K_FORCE: u8 = 6;
pub const K_CONEFORCE: u8 = 7;
pub const K_ATTRACT: u8 = 8;
pub const K_ROT: u8 = 9;
pub const K_BANROT: u8 = 10;
pub const K_RVEL: u8 = 11;
pub const K_SHAPE: u8 = 12;
pub const K_SHAPEVEL: u8 = 13;
pub const K_SCALE: u8 = 14;
pub const K_DIFFUSE: u8 = 15;
pub const K_SLIDE: u8 = 16;
pub const K_RANDSCALE: u8 = 17;
pub const K_MAX: u8 = 17;

const NONE: u32 = u32::MAX;
const ROOT: u32 = 0;

/// One command key, its payload resolved at compile time (EfpSim._payload).
#[derive(Clone, Copy, Debug)]
pub struct Cmd {
    pub kind: u8,
    pub space: i64,
    /// A Vector3 (0..3), a Basis by rows (0..9) or a UV rectangle (0..4).
    pub v: [f32; 9],
    /// Attraction's value (a GDScript float).
    pub f: f64,
    /// SetGraphDiffuse's colour.
    pub color: i64,
}

impl Cmd {
    fn v3(&self) -> V3 {
        V3(self.v[0], self.v[1], self.v[2])
    }
    fn basis(&self) -> B3 {
        B3::from_rows(&self.v)
    }
}

/// A node's BlendScaleGraph (EfpSim.sample_scale_graph's {a, b, times, scales}).
#[derive(Clone, Debug, Default)]
pub struct ScaleGraph {
    pub a: f64,
    pub b: f64,
    pub times: Vec<f32>,
    pub scales: Vec<V3>,
}

/// EfpSim.Tpl: one node, compiled.
#[derive(Clone, Debug, Default)]
pub struct Tpl {
    pub parent: i32,
    pub children: Vec<u32>,
    pub frames: i64,
    pub life: u8,
    pub has_emit: bool,
    pub e_delay: i64,
    pub e_dur: i64,
    pub e_int: i64,
    pub e_max: i64,
    pub e_per: f64,
    pub lv_orbit: i64,
    pub lv_rot: i64,
    pub lv_vel: i64,
    pub lv_move: i64,
    pub keep_rot: bool,
    pub keep_pos: bool,
    pub follows_any: bool,
    /// frame -> its commands (`schedule`; its length is the node's frames).
    pub schedule: Vec<Vec<Cmd>>,
    pub scale_graph: Option<ScaleGraph>,
}

/// EfpSim.Template.
#[derive(Clone, Debug, Default)]
pub struct Template {
    pub tpls: Vec<Tpl>,
    /// growth_bounds' tables (Template.rate / kids / fan / fan_child); `has_fan` false when the
    /// GDScript Template had none (the loose bound).
    pub rate: Vec<i64>,
    pub kids: Vec<i64>,
    pub fan: Vec<i64>,
    pub fan_child: i64,
    pub has_fan: bool,
}

/// EfpSim.Particle.
#[derive(Clone, Debug)]
pub struct Particle {
    pub tpl: u32,
    emitter: u32,
    emitter_gen: u32,
    pub parent: u32,
    pub age: i64,
    pub alive: bool,
    pub dying: bool,
    pub pos: V3,
    pub vel: V3,
    pub rot: B3,
    pub rvel: B3,
    pub shape: B3,
    pub shape_vel: B3,
    pub has_rvel: bool,
    pub has_shape_vel: bool,
    pub scale: V3,
    pub color: i64,
    pub uv: [f32; 4],
    pub link: u32,
    pub next_link: u32,
    pub old_pos: V3,
    pub old_rot: B3,
    pub delta: B3,
    pub changed: bool,
    f_orbit: u32,
    f_rot: u32,
    f_vel: u32,
    f_move: u32,
    /// References: 1 while in the list, plus one per particle naming it as parent.
    rc: u32,
}

impl Particle {
    fn new() -> Particle {
        Particle {
            tpl: 0,
            emitter: NONE,
            emitter_gen: 0,
            parent: NONE,
            age: 0,
            alive: true,
            dying: false,
            pos: ZERO,
            vel: ZERO,
            rot: IDENTITY,
            rvel: IDENTITY,
            shape: IDENTITY,
            shape_vel: IDENTITY,
            has_rvel: false,
            has_shape_vel: false,
            scale: ONE,
            color: 0xFFFF_FFFF,
            uv: [0.0, 0.0, 1.0, 1.0],
            link: NONE,
            next_link: NONE,
            old_pos: ZERO,
            old_rot: IDENTITY,
            delta: IDENTITY,
            changed: false,
            f_orbit: NONE,
            f_rot: NONE,
            f_vel: NONE,
            f_move: NONE,
            rc: 0,
        }
    }
}

/// EfpSim.Emitter.
#[derive(Clone, Debug)]
pub struct Emitter {
    pub tpl: u32,
    pub owner: u32,
    pub acc: f64,
    pub done: bool,
    pub tail: u32,
    pub dying: i64,
    gen: u32,
    live: bool,
}

/// Answers a spawn at own change `d`: (a, r) such that a spawn at a change below a is surely taken
/// and one at r or above surely refused, with d decided.
pub trait Gate {
    fn admit(&mut self, d: i64) -> (i64, i64);
}

/// One effect alone: live_total is `base` (plus its own change), the cap `limit`.
pub struct ExactGate {
    pub below: i64,
}

impl Gate for ExactGate {
    fn admit(&mut self, _d: i64) -> (i64, i64) {
        (self.below, self.below)
    }
}

/// The emission quality globals (EfpSim.interval_mul / threshold).
#[derive(Clone, Copy, Debug, Default)]
pub struct Quality {
    pub interval_mul: i64,
    pub threshold: i64,
}

/// EfpReader.f32: a double through a float.
#[inline]
fn f32r(x: f64) -> f64 {
    x as f32 as f64
}

/// EfpReader.ftol: truncation, 0x80000000 for NaN or out of the int32 range.
#[inline]
pub fn ftol(x: f64) -> i64 {
    if x.is_nan() || x >= 2147483648.0 || x < -2147483648.0 {
        return -2147483648;
    }
    x as i64
}

/// EfpReader.i32.
#[inline]
pub fn i32w(v: i64) -> i64 {
    (((v as i128 + 0x8000_0000) & 0xFFFF_FFFF) - 0x8000_0000) as i64
}

/// EfpSim.kind_names_link.
pub fn kind_names_link(kind: u8, space: i64) -> bool {
    match kind {
        K_POS | K_CONEPOS | K_BANPOS => space % 3 == 2 || space / 3 == 3,
        K_SPHERE => space == 2,
        K_VEL | K_CONEVEL | K_FORCE | K_CONEFORCE | K_ROT | K_BANROT => space == 3,
        K_ATTRACT => space == 1,
        _ => false,
    }
}

/// EfpSim.sample_scale_graph.
pub fn sample_scale_graph(g: &ScaleGraph, t: f64) -> V3 {
    let n = g.times.len().min(g.scales.len());
    if n == 0 {
        return ONE;
    }
    if t < g.a || t <= g.times[0] as f64 {
        return g.scales[0];
    }
    if t > g.b || t >= g.times[n - 1] as f64 {
        return g.scales[n - 1];
    }
    for i in 1..n {
        if t <= g.times[i] as f64 {
            let span = g.times[i] as f64 - g.times[i - 1] as f64;
            let w = if span > 0.0 { (t - g.times[i - 1] as f64) / span } else { 1.0 };
            return g.scales[i - 1].lerp(g.scales[i], w as f32);
        }
    }
    g.scales[n - 1]
}

/// One playing effect (EfpSim's instance state).
#[derive(Clone)]
pub struct Sim {
    pub tmpl: Arc<Template>,
    parts: Vec<Particle>,
    free_parts: Vec<u32>,
    /// `particles`: arena slots in order.
    list: Vec<u32>,
    ems: Vec<Emitter>,
    free_ems: Vec<u32>,
    /// `emitters`: arena slots in order.
    elist: Vec<u32>,
    pub age: i64,
    pub dropped: i64,
    pub spawned: i64,
    pub reserved: bool,
    pub keep: bool,
    pub revived: i64,
    pub acc: f64,
    rng: Pcg,
    scratch: V3,
    dying_n: i64,
    pub quality: Quality,
    // The cap during an advance (begin_deferred's state).
    sure_below: i64,
    sure_from: i64,
    /// This advance's change of the particle count.
    pub live_delta: i64,
}

impl Sim {
    /// EfpSim._init(template, seed): the stream seeded as `RandomNumberGenerator.seed = seed`, and
    /// restart().
    pub fn new(tmpl: Arc<Template>, seed: u64) -> Sim {
        let mut root = Particle::new();
        root.rc = 1;
        let mut s = Sim {
            tmpl,
            parts: vec![root],
            free_parts: Vec::new(),
            list: Vec::new(),
            ems: Vec::new(),
            free_ems: Vec::new(),
            elist: Vec::new(),
            age: 0,
            dropped: 0,
            spawned: 0,
            reserved: false,
            keep: false,
            revived: 0,
            acc: 0.0,
            rng: Pcg::seeded(seed),
            scratch: ZERO,
            dying_n: 0,
            quality: Quality::default(),
            sure_below: -FAN_MAX,
            sure_from: FAN_MAX,
            live_delta: 0,
        };
        s.restart();
        s
    }

    pub fn count(&self) -> usize {
        self.list.len()
    }

    pub fn rng_state(&self) -> u64 {
        self.rng.state()
    }

    /// The particles in order (tests, the draws).
    pub fn particles(&self) -> impl Iterator<Item = &Particle> + '_ {
        self.list.iter().map(move |&s| &self.parts[s as usize])
    }

    /// The emitters in order (tests).
    pub fn emitters(&self) -> impl Iterator<Item = &Emitter> + '_ {
        self.elist.iter().map(move |&s| &self.ems[s as usize])
    }

    /// The list index of each particle's link (-1: none), in list order (tests, the links).
    pub fn link_indices(&self) -> Vec<i32> {
        let mut at = vec![-1i32; self.parts.len()];
        for (i, &s) in self.list.iter().enumerate() {
            at[s as usize] = i as i32;
        }
        self.list
            .iter()
            .map(|&s| {
                let l = self.parts[s as usize].link;
                if l == NONE {
                    -1
                } else {
                    at[l as usize]
                }
            })
            .collect()
    }

    pub fn particle(&self, slot: u32) -> &Particle {
        &self.parts[slot as usize]
    }

    pub fn list_slots(&self) -> &[u32] {
        &self.list
    }

    // ------------------------------------------------------------- arenas

    fn alloc_particle(&mut self, p: Particle) -> u32 {
        if let Some(s) = self.free_parts.pop() {
            self.parts[s as usize] = p;
            s
        } else {
            self.parts.push(p);
            (self.parts.len() - 1) as u32
        }
    }

    /// One reference to `s` gone; at zero the slot is freed and its parent loses one.
    fn release(&mut self, mut s: u32) {
        while s != ROOT && s != NONE {
            let p = &mut self.parts[s as usize];
            p.rc -= 1;
            if p.rc > 0 {
                return;
            }
            let parent = p.parent;
            self.free_parts.push(s);
            s = parent;
        }
    }

    fn alloc_emitter(&mut self, tpl: u32, owner: u32) -> u32 {
        let e = |gen: u32| Emitter { tpl, owner, acc: 0.0, done: false, tail: NONE, dying: 0, gen, live: true };
        if let Some(s) = self.free_ems.pop() {
            let gen = self.ems[s as usize].gen.wrapping_add(1);
            self.ems[s as usize] = e(gen);
            s
        } else {
            self.ems.push(e(0));
            (self.ems.len() - 1) as u32
        }
    }

    /// The emitter a particle names, while it is still in the list (else its writes go nowhere).
    #[inline]
    fn emitter_of(&self, p: &Particle) -> Option<u32> {
        if p.emitter == NONE {
            return None;
        }
        let e = &self.ems[p.emitter as usize];
        if e.live && e.gen == p.emitter_gen {
            Some(p.emitter)
        } else {
            None
        }
    }

    // ------------------------------------------------------------- lifecycle

    /// EfpSim.restart.
    pub fn restart(&mut self) -> i64 {
        let removed = self.clear();
        self.age = 0;
        self.dropped = 0;
        self.acc = 0.0;
        if !self.tmpl.tpls.is_empty() {
            let e = self.alloc_emitter(0, ROOT);
            self.elist.push(e);
        }
        removed
    }

    /// EfpSim.clear: every particle and emitter dropped. Returns how many particles were alive
    /// (GDScript's `_live_add(-1)` each).
    pub fn clear(&mut self) -> i64 {
        let removed = self.list.len() as i64;
        let root = self.parts[ROOT as usize].clone();
        self.parts.clear();
        self.parts.push(root);
        self.free_parts.clear();
        self.list.clear();
        for e in self.ems.iter_mut() {
            e.live = false;
        }
        // Slots are reused with a new generation: no particle survives a clear, so none can name one.
        self.free_ems = (0..self.ems.len() as u32).rev().collect();
        self.elist.clear();
        self.dying_n = 0;
        removed
    }

    /// EfpSim.finished.
    pub fn finished(&self) -> bool {
        if !self.list.is_empty() {
            return false;
        }
        self.elist.iter().all(|&e| self.ems[e as usize].done)
    }

    /// begin_deferred: the next advance's cap is asked of a gate, from nothing known.
    pub fn begin(&mut self) {
        self.live_delta = 0;
        self.sure_below = -FAN_MAX;
        self.sure_from = FAN_MAX;
    }

    /// EfpSim.advance(delta) with the cap answered by `gate`. Returns the frames stepped; the change
    /// of the count is `live_delta` (call begin() first).
    pub fn advance(&mut self, delta: f64, gate: &mut dyn Gate) -> i64 {
        self.acc += gmax(delta, 0.0);
        let mut n = 0;
        while self.acc >= FRAME_SEC && n < MAX_STEPS_PER_ADVANCE {
            self.acc -= FRAME_SEC;
            self.step(gate);
            n += 1;
        }
        if n == MAX_STEPS_PER_ADVANCE {
            self.acc = gmin(self.acc, FRAME_SEC);
        }
        n
    }

    /// How many frames advance(delta) will step, from the clock now (advance's own arithmetic).
    pub fn steps_for(&self, delta: f64) -> i64 {
        let mut steps = 0;
        let mut a = self.acc + gmax(delta, 0.0);
        while a >= FRAME_SEC && steps < MAX_STEPS_PER_ADVANCE {
            a -= FRAME_SEC;
            steps += 1;
        }
        steps
    }

    /// EfpSim.growth_bounds: (least, most) of the change advance(delta) can make, from the state
    /// now.
    pub fn growth_bounds(&self, delta: f64) -> (i64, i64) {
        let mut steps = 0;
        let mut a = self.acc + gmax(delta, 0.0);
        while a >= FRAME_SEC && steps < MAX_STEPS_PER_ADVANCE {
            a -= FRAME_SEC;
            steps += 1;
        }
        let t = &*self.tmpl;
        if steps == 0 || t.tpls.is_empty() {
            return (0, 0);
        }
        let c = self.list.len() as i64;
        let dying = self.dying_n;
        let least = if steps == 1 { -dying } else { -c };
        let most = MAX_PARTICLES - c;
        if !t.has_fan || t.fan.len() != t.tpls.len() {
            return (least, most);
        }
        let mut first: i64 = 0;
        let mut every: i64 = 0;
        for &es in &self.elist {
            let e = &self.ems[es as usize];
            let f = t.fan[e.tpl as usize];
            if f == 0 {
                continue;
            }
            let owner = e.owner;
            if owner != ROOT && self.parts[owner as usize].dying {
                continue;
            }
            every = (every + f).min(FAN_MAX);
            let tp = &t.tpls[e.tpl as usize];
            let oage = if owner == ROOT { self.age } else { self.parts[owner as usize].age };
            let tt = i32w(oage - tp.e_delay);
            if tt >= tp.e_dur || tt < 0 || tp.e_int <= 0 {
                continue;
            }
            let mut interval = tp.e_int;
            if self.quality.interval_mul > 1 {
                let m = i32w(interval * self.quality.interval_mul);
                if m < tp.e_dur {
                    interval = m;
                }
            }
            // Round 763's review, L4: the multiplied interval can wrap to 0 or below; no frame
            // fires then (efp_sim.gd mirrors it).
            if interval <= 0 || tt % interval != 0 {
                continue;
            }
            let mut r = t.rate[e.tpl as usize];
            if r < FAN_MAX && e.acc >= 0.0 && e.acc < 16777216.0 {
                r = r.min((tp.e_max - gmax(e.acc - e.dying as f64, 0.0) as i64).max(0));
            }
            first = (first + r * (1 + t.kids[e.tpl as usize])).min(FAN_MAX);
        }
        let mut spawns = first;
        for _ in 1..steps {
            spawns = (spawns + every + spawns * t.fan_child).min(FAN_MAX);
        }
        (least, most.min(spawns - dying))
    }

    // ------------------------------------------------------------- the frame

    /// EfpSim.step: one 50 ms frame.
    pub fn step(&mut self, gate: &mut dyn Gate) {
        let tmpl = self.tmpl.clone();
        // 0 last frame's queued deaths
        self.flush_deaths();
        // _place_root
        {
            let r = &mut self.parts[ROOT as usize];
            r.old_pos = r.pos;
            r.old_rot = r.rot;
            r.changed = false;
        }
        // 1-2 motion, follows, commands, the turn -- in spawn order
        for idx in 0..self.list.len() {
            let s = self.list[idx] as usize;
            let tp = &tmpl.tpls[self.parts[s].tpl as usize];
            {
                let p = &mut self.parts[s];
                if tp.keep_rot {
                    p.old_rot = p.rot;
                }
                if tp.keep_pos {
                    p.old_pos = p.pos;
                }
                p.changed = false;
            }
            if self.parts[s].has_rvel {
                if tp.follows_any {
                    self.follow_gated(s);
                }
                let p = &mut self.parts[s];
                p.rot = p.rvel.mul(&p.rot);
                p.changed = true;
                let m = p.f_move;
                if m != NONE && self.parts[m as usize].alive {
                    let (mp, mo) = (self.parts[m as usize].pos, self.parts[m as usize].old_pos);
                    let p = &mut self.parts[s];
                    p.pos = p.pos.add(mp.sub(mo));
                }
            } else if tp.follows_any {
                self.follow(s);
            }
            {
                let p = &mut self.parts[s];
                p.pos = p.pos.add(p.vel);
                if p.has_shape_vel {
                    p.shape = p.shape_vel.mul(&p.shape);
                }
            }
            let age = self.parts[s].age;
            if age >= 0 && (age as usize) < tp.schedule.len() {
                let cmds = &tp.schedule[age as usize];
                if !cmds.is_empty() {
                    self.run_list(s, tp, cmds);
                }
            }
            let p = &mut self.parts[s];
            if tp.keep_rot && p.changed {
                p.delta = p.rot.mul(&p.old_rot.inverse());
            }
        }
        // 3 emission (the list grows as particles spawn child emitters)
        let mut i = 0;
        while i < self.elist.len() {
            let e = self.elist[i];
            self.emit(e, &tmpl, gate);
            i += 1;
        }
        // 4 ages advance; a particle whose life is over is queued to die
        for idx in 0..self.list.len() {
            let s = self.list[idx] as usize;
            let tp = &tmpl.tpls[self.parts[s].tpl as usize];
            let mut dies = false;
            {
                let p = &mut self.parts[s];
                match tp.life {
                    LIFE_EXTINCT => {
                        p.age += 1;
                        if p.age >= tp.frames {
                            p.age = (tp.frames - 1).max(0);
                            dies = true;
                        }
                    }
                    LIFE_LOOP => {
                        p.age += 1;
                        if tp.frames > 0 {
                            p.age %= tp.frames;
                        }
                    }
                    LIFE_NEVER => {
                        if p.age != 1 {
                            p.age += 1;
                        }
                        if tp.frames == 0 {
                            dies = true;
                        }
                    }
                    _ => {}
                }
            }
            if !dies {
                continue;
            }
            if self.keep && self.parts[s].parent == ROOT {
                self.parts[s].age = 0;
                self.revived += 1;
            } else {
                self.parts[s].dying = true;
                self.dying_n += 1;
                if let Some(e) = self.emitter_of(&self.parts[s]) {
                    self.ems[e as usize].dying += 1;
                }
            }
        }
        self.age += 1;
    }

    /// EfpSim._flush_deaths.
    fn flush_deaths(&mut self) {
        if !self.list.iter().any(|&s| self.parts[s as usize].dying) {
            return;
        }
        let old = std::mem::take(&mut self.list);
        let mut kept = Vec::with_capacity(old.len());
        let mut gone = Vec::new();
        for &s in &old {
            if self.parts[s as usize].dying {
                self.parts[s as usize].alive = false;
                self.on_death(s);
                gone.push(s);
            } else {
                kept.push(s);
            }
        }
        self.list = kept;
        let olde = std::mem::take(&mut self.elist);
        let mut live = Vec::with_capacity(olde.len());
        for &es in &olde {
            let owner = self.ems[es as usize].owner;
            if owner == ROOT || self.parts[owner as usize].alive {
                self.ems[es as usize].dying = 0;
                live.push(es);
            } else {
                self.ems[es as usize].live = false;
                self.free_ems.push(es);
            }
        }
        self.elist = live;
        self.dying_n = 0;
        // The list's references go last: an emitter above still read its owner's `alive`.
        for s in gone {
            self.release(s);
        }
    }

    /// EfpSim._on_death: the count drops, the emitter gives back 1.0, the particle unlinks.
    fn on_death(&mut self, s: u32) {
        self.live_delta -= 1;
        if let Some(e) = self.emitter_of(&self.parts[s as usize]) {
            let em = &mut self.ems[e as usize];
            em.acc = gmax(em.acc - 1.0, 0.0);
        }
        self.unlink(s);
    }

    /// EfpSim._unlink.
    fn unlink(&mut self, s: u32) {
        let (link, next) = {
            let p = &self.parts[s as usize];
            (p.link, p.next_link)
        };
        if next != NONE {
            self.parts[next as usize].link = link;
        }
        if link != NONE {
            self.parts[link as usize].next_link = next;
        }
        if let Some(e) = self.emitter_of(&self.parts[s as usize]) {
            if self.ems[e as usize].tail == s {
                self.ems[e as usize].tail = link;
            }
        }
        let p = &mut self.parts[s as usize];
        p.link = NONE;
        p.next_link = NONE;
    }

    /// The u2 / u3 / u4 follows of the has_rvel branch of step (gated on the ancestor changing).
    fn follow_gated(&mut self, s: usize) {
        let (fo, fr, fv) = {
            let p = &self.parts[s];
            (p.f_orbit, p.f_rot, p.f_vel)
        };
        if let Some((d, op)) = self.changed_of(fo) {
            let p = &mut self.parts[s];
            p.pos = d.xform(p.pos.sub(op)).add(op);
        }
        if let Some((d, _)) = self.changed_of(fr) {
            let p = &mut self.parts[s];
            p.rot = d.mul(&p.rot);
            p.changed = true;
        }
        if let Some((d, _)) = self.changed_of(fv) {
            let p = &mut self.parts[s];
            p.vel = d.xform(p.vel);
        }
    }

    /// An ancestor's (delta, old position) when it changed and is alive.
    #[inline]
    fn changed_of(&self, f: u32) -> Option<(B3, V3)> {
        if f == NONE {
            return None;
        }
        let a = &self.parts[f as usize];
        if a.changed && a.alive {
            Some((a.delta, a.old_pos))
        } else {
            None
        }
    }

    /// EfpSim._follow: u2, u3, u4 gated, u6 every time.
    fn follow(&mut self, s: usize) {
        self.follow_gated(s);
        let m = self.parts[s].f_move;
        if m != NONE && self.parts[m as usize].alive {
            let (mp, mo) = (self.parts[m as usize].pos, self.parts[m as usize].old_pos);
            let p = &mut self.parts[s];
            p.pos = p.pos.add(mp.sub(mo));
        }
    }

    /// EfpSim._emit.
    fn emit(&mut self, es: u32, tmpl: &Arc<Template>, gate: &mut dyn Gate) {
        let (tpl, owner) = {
            let e = &self.ems[es as usize];
            (e.tpl, e.owner)
        };
        let tp = &tmpl.tpls[tpl as usize];
        if !tp.has_emit {
            self.ems[es as usize].done = true;
            return;
        }
        let oage = if owner == ROOT { self.age } else { self.parts[owner as usize].age };
        let n = self.emit_spawns(tp, oage, es);
        for k in 0..n {
            // Round 763's review, L3: once the effect holds MAX_PARTICLES every remaining spawn of
            // this emission is refused for that alone (no death comes in between), each giving
            // 1.0 back: all of them at once. Exact: acc is an f32 value in an f64, so
            // max(acc - rest, 0) is the repeated max(acc - 1, 0). efp_sim.gd does the same.
            if self.list.len() as i64 >= MAX_PARTICLES {
                let rest = n - k;
                self.dropped += rest;
                let e = &mut self.ems[es as usize];
                e.acc = gmax(e.acc - rest as f64, 0.0);
                break;
            }
            self.spawn(tpl, owner, es, tmpl, gate);
        }
    }

    /// EfpSim.emit_spawns.
    fn emit_spawns(&mut self, tp: &Tpl, owner_age: i64, es: u32) -> i64 {
        let q = self.quality;
        let e = &mut self.ems[es as usize];
        let t = i32w(owner_age - tp.e_delay);
        if t >= tp.e_dur {
            e.done = true;
            return 0;
        }
        e.done = false;
        let mut interval = tp.e_int;
        if interval <= 0 || t < 0 {
            return 0;
        }
        if q.interval_mul > 1 {
            let m = i32w(interval * q.interval_mul);
            if m < tp.e_dur {
                interval = m;
            }
        }
        // Round 763's review, L4 (efp_sim.gd mirrors it).
        if interval <= 0 || t % interval != 0 {
            return 0;
        }
        let mut cap = tp.e_max;
        if q.threshold > 0 && (q.threshold as f64) < tp.e_per && cap > 0 {
            cap = ftol(f32r(cap as f64 * 0.5)).max(1);
        }
        let old = ftol(e.acc);
        let mut nxt = f32r(tp.e_per + e.acc);
        let capf = f32r(cap as f64);
        if capf < nxt {
            nxt = capf;
        }
        e.acc = nxt;
        i32w(ftol(nxt) - old).max(0)
    }

    /// EfpSim.can_spawn (the deferred branch: every advance here is deferred).
    fn can_spawn(&mut self, gate: &mut dyn Gate) -> bool {
        if self.list.len() as i64 >= MAX_PARTICLES {
            return false;
        }
        if self.live_delta < self.sure_below {
            return true;
        }
        if self.live_delta >= self.sure_from {
            return false;
        }
        let (a, r) = gate.admit(self.live_delta);
        self.sure_below = a;
        self.sure_from = r;
        self.live_delta < a
    }

    /// EfpSim._ancestor: `level` owners up from a particle whose parent is `parent`.
    fn ancestor(&self, parent: u32, level: i64) -> u32 {
        if level == 0 {
            return NONE;
        }
        let mut a = parent;
        let mut k = level - 1;
        while k > 0 && a != NONE {
            a = self.parts[a as usize].parent;
            k -= 1;
        }
        a
    }

    /// EfpSim._spawn.
    fn spawn(&mut self, tpl: u32, owner: u32, from: u32, tmpl: &Arc<Template>, gate: &mut dyn Gate) {
        if !self.can_spawn(gate) {
            self.dropped += 1;
            let e = &mut self.ems[from as usize];
            e.acc = gmax(e.acc - 1.0, 0.0);
            return;
        }
        let tp = &tmpl.tpls[tpl as usize];
        let o = &self.parts[owner as usize];
        let mut p = Particle::new();
        p.tpl = tpl;
        p.emitter = from;
        p.emitter_gen = self.ems[from as usize].gen;
        p.parent = owner;
        p.pos = o.pos;
        p.old_pos = o.pos;
        p.vel = o.vel;
        p.rot = if tp.lv_rot < 0 { IDENTITY } else { o.rot };
        p.old_rot = p.rot;
        p.f_orbit = self.ancestor(owner, tp.lv_orbit);
        p.f_rot = self.ancestor(owner, if tp.lv_rot >= 1 { tp.lv_rot } else { 0 });
        p.f_vel = self.ancestor(owner, tp.lv_vel);
        p.f_move = self.ancestor(owner, tp.lv_move);
        if p.f_move != NONE {
            p.vel = p.vel.sub(self.parts[p.f_move as usize].vel);
        }
        p.rc = 1;
        let s = self.alloc_particle(p);
        if owner != ROOT {
            self.parts[owner as usize].rc += 1;
        }
        // _link_in
        let tail = self.ems[from as usize].tail;
        self.parts[s as usize].link = tail;
        if tail != NONE {
            self.parts[tail as usize].next_link = s;
        }
        self.ems[from as usize].tail = s;
        self.list.push(s);
        self.live_delta += 1;
        self.spawned += 1;
        if let Some(first) = tp.schedule.first() {
            if !first.is_empty() {
                self.run_list(s as usize, tp, first);
            }
        }
        for &k in &tp.children {
            let e = self.alloc_emitter(k, s);
            self.elist.push(e);
        }
    }

    // ------------------------------------------------------------- commands

    fn parent_of(&self, s: usize) -> usize {
        let p = self.parts[s].parent;
        if p != NONE {
            p as usize
        } else {
            ROOT as usize
        }
    }

    /// EfpSim._frame.
    fn frame(&self, s: usize, sel: i64) -> B3 {
        match sel {
            1 => self.parts[s].rot,
            2 => self.parts[self.parent_of(s)].rot,
            3 => {
                let l = self.parts[s].link;
                if l != NONE {
                    self.parts[l as usize].rot
                } else {
                    IDENTITY
                }
            }
            _ => IDENTITY,
        }
    }

    fn rand(&mut self) -> f64 {
        self.rng.randf() as f64
    }

    /// EfpSim._cone.
    fn cone(&mut self, b: V3) -> V3 {
        let r = lerp64(b.0 as f64, b.1 as f64, self.rand());
        let tilt = self.rand() * b.2 as f64;
        let spin = self.rand() * std::f64::consts::TAU;
        let x = -r * tilt.sin();
        let y = r * tilt.cos();
        V3((x * spin.cos()) as f32, y as f32, (x * spin.sin()) as f32)
    }

    /// EfpSim._ball.
    fn ball(&mut self) -> V3 {
        for _ in 0..64 {
            let x = (self.rand() - 0.5) * 2.0;
            let y = (self.rand() - 0.5) * 2.0;
            let z = (self.rand() - 0.5) * 2.0;
            let q = V3(x as f32, y as f32, z as f32);
            if q.length_squared() as f64 <= 1.0 {
                return q;
            }
        }
        ZERO
    }

    /// EfpSim._set_pos.
    fn set_pos(&mut self, s: usize, space: i64, v: V3, stack: bool) {
        let o = space % 3;
        let r = space / 3;
        let d = self.frame(s, r).xform(v);
        if o == 1 {
            let pp = self.parts[self.parent_of(s)].pos;
            self.parts[s].pos = pp;
        } else if o == 2 {
            let l = self.parts[s].link as usize;
            let lp = self.parts[l].pos;
            self.parts[s].pos = lp;
        } else if stack {
            self.scratch = d;
        }
        let p = &mut self.parts[s];
        p.pos = p.pos.add(d);
    }

    /// EfpSim._run_list.
    fn run_list(&mut self, s: usize, tp: &Tpl, list: &[Cmd]) {
        self.scratch = ZERO;
        for c in list {
            self.run(s, tp, c);
        }
    }

    /// EfpSim._run.
    fn run(&mut self, s: usize, tp: &Tpl, c: &Cmd) {
        let sp = c.space;
        if self.parts[s].link == NONE && kind_names_link(c.kind, sp) {
            return;
        }
        match c.kind {
            K_POS | K_BANPOS => self.set_pos(s, sp, c.v3(), false),
            K_CONEPOS => {
                let v = self.cone(c.v3());
                self.set_pos(s, sp, v, true);
            }
            K_SPHERE => {
                if sp == 0 {
                    let b = self.ball();
                    self.parts[s].pos = b;
                    self.scratch = c.v3().mul(self.scratch);
                    let sc = self.scratch;
                    let p = &mut self.parts[s];
                    p.pos = p.pos.add(sc);
                } else {
                    let o = if sp == 2 {
                        self.parts[self.parts[s].link as usize].pos
                    } else {
                        self.parts[self.parent_of(s)].pos
                    };
                    let b = self.ball();
                    self.parts[s].pos = o.add(b.mul(c.v3()));
                }
            }
            K_VEL => {
                let v = self.frame(s, sp).xform(c.v3());
                self.parts[s].vel = v;
            }
            K_CONEVEL => {
                let f = self.frame(s, sp);
                let cv = self.cone(c.v3());
                self.parts[s].vel = f.xform(cv);
            }
            K_FORCE => {
                let v = self.frame(s, sp).xform(c.v3());
                let p = &mut self.parts[s];
                p.vel = p.vel.add(v);
            }
            K_CONEFORCE => {
                let c1 = self.cone(c.v3());
                self.scratch = c1;
                let v = self.frame(s, sp).xform(c1);
                {
                    let p = &mut self.parts[s];
                    p.vel = p.vel.add(v);
                }
                if sp == 0 {
                    let rot = self.parts[s].rot;
                    let c2 = rot.xform(self.cone(c.v3()));
                    self.scratch = c2;
                    let p = &mut self.parts[s];
                    p.vel = p.vel.add(c2);
                }
            }
            K_ATTRACT => {
                let o = if sp == 1 {
                    self.parts[self.parts[s].link as usize].pos
                } else {
                    self.parts[self.parent_of(s)].pos
                };
                let d = self.parts[s].pos.sub(o);
                if d.length_squared() > 0.0 {
                    self.scratch = d.normalized().scale(c.f as f32);
                    let sc = self.scratch;
                    let p = &mut self.parts[s];
                    p.vel = p.vel.add(sc);
                }
            }
            K_ROT | K_BANROT => {
                let m = c.basis();
                self.parts[s].changed = true;
                if sp == 0 {
                    self.parts[s].rot = m;
                } else {
                    let f = self.frame(s, sp);
                    self.parts[s].rot = f.mul(&m);
                }
            }
            K_RVEL => {
                let p = &mut self.parts[s];
                p.rvel = c.basis();
                p.has_rvel = p.rvel != IDENTITY;
            }
            K_SHAPE => self.parts[s].shape = c.basis(),
            K_SHAPEVEL => {
                let p = &mut self.parts[s];
                p.shape_vel = c.basis();
                p.has_shape_vel = p.shape_vel != IDENTITY;
            }
            K_SCALE => self.parts[s].scale = c.v3(),
            K_DIFFUSE => self.parts[s].color = c.color,
            K_SLIDE => self.parts[s].uv = [c.v[0], c.v[1], c.v[2], c.v[3]],
            K_RANDSCALE => {
                if let Some(g) = &tp.scale_graph {
                    let t = self.rand();
                    self.parts[s].scale = sample_scale_graph(g, t);
                }
            }
            _ => {}
        }
    }

    // ------------------------------------------------------------- placement

    /// EfpSim.set_origin: places the effect and, when that moved or turned it, runs the follow
    /// pass at once. Returns whether anything moved.
    pub fn set_origin(&mut self, pos: V3, rot: B3) -> bool {
        {
            let r = &self.parts[ROOT as usize];
            if pos.is_equal_approx(r.pos) && rot.is_equal_approx(&r.rot) {
                return false;
            }
        }
        {
            let r = &mut self.parts[ROOT as usize];
            r.old_pos = r.pos;
            r.old_rot = r.rot;
            r.pos = pos;
            r.rot = rot;
            r.changed = true;
            r.delta = rot.mul(&r.old_rot.inverse());
        }
        if !self.list.is_empty() {
            let tmpl = self.tmpl.clone();
            for idx in 0..self.list.len() {
                let s = self.list[idx] as usize;
                let tp = &tmpl.tpls[self.parts[s].tpl as usize];
                {
                    let p = &mut self.parts[s];
                    if tp.keep_rot {
                        p.old_rot = p.rot;
                    }
                    if tp.keep_pos {
                        p.old_pos = p.pos;
                    }
                    p.changed = false;
                }
                if !tp.follows_any {
                    continue;
                }
                self.follow(s);
                let p = &mut self.parts[s];
                if tp.keep_rot && p.changed {
                    p.delta = p.rot.mul(&p.old_rot.inverse());
                }
            }
        }
        let r = &mut self.parts[ROOT as usize];
        r.old_pos = r.pos;
        r.old_rot = r.rot;
        r.changed = false;
        true
    }

    /// EfpSim.shift.
    pub fn shift(&mut self, v: V3) {
        for idx in 0..self.list.len() {
            let p = &mut self.parts[self.list[idx] as usize];
            p.pos = p.pos.sub(v);
            p.old_pos = p.old_pos.sub(v);
        }
        let r = &mut self.parts[ROOT as usize];
        r.pos = r.pos.sub(v);
        r.old_pos = r.old_pos.sub(v);
    }

    /// EfpSim.origin.
    pub fn origin(&self) -> V3 {
        self.parts[ROOT as usize].pos
    }

    /// Slots in use in the particle arena (tests: the list plus the dead still named as a parent).
    pub fn arena_in_use(&self) -> usize {
        self.parts.len() - self.free_parts.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(kind: u8, space: i64, v: [f32; 3]) -> Cmd {
        Cmd { kind, space, v: [v[0], v[1], v[2], 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], f: 0.0, color: 0 }
    }

    /// A stream of particles living `frames`, each with a cone velocity, and a child stream.
    fn template(frames: i64, per: f64, max_live: i64) -> Arc<Template> {
        let mut child = Tpl {
            parent: 0,
            frames: 10,
            life: LIFE_EXTINCT,
            has_emit: true,
            e_dur: 100000,
            e_int: 2,
            e_max: 5,
            e_per: 1.0,
            lv_move: 1,
            follows_any: true,
            keep_pos: true,
            ..Default::default()
        };
        child.schedule = vec![Vec::new(); 10];
        child.schedule[0].push(cmd(K_CONEVEL, 0, [0.1, 0.3, 1.0]));
        let mut root = Tpl {
            parent: -1,
            children: vec![1],
            frames,
            life: LIFE_EXTINCT,
            has_emit: true,
            e_dur: 100000,
            e_int: 1,
            e_max: max_live,
            e_per: per,
            ..Default::default()
        };
        root.schedule = vec![Vec::new(); frames as usize];
        root.schedule[0].push(cmd(K_CONEPOS, 0, [1.0, 2.0, 0.5]));
        root.schedule[0].push(cmd(K_VEL, 0, [0.0, 0.2, 0.0]));
        let t = Template {
            tpls: vec![root, child],
            rate: vec![(per as i64 + 2).min(max_live), 1 + 2],
            kids: vec![3, 0],
            fan: vec![(per as i64 + 2).min(max_live) * 4, 3],
            fan_child: 3,
            has_fan: true,
        };
        Arc::new(t)
    }

    #[test]
    fn deterministic_and_bounded() {
        let t = template(20, 2.5, 40);
        let mut a = Sim::new(t.clone(), 1234);
        let mut b = Sim::new(t, 1234);
        let mut total = 0i64;
        for f in 0..400 {
            let d = if f == 100 { 0.3 } else { 1.0 / 30.0 };
            let (lo, hi) = a.growth_bounds(d);
            a.begin();
            b.begin();
            let mut g = ExactGate { below: 1 << 30 };
            a.advance(d, &mut g);
            let mut g2 = ExactGate { below: 1 << 30 };
            b.advance(d, &mut g2);
            assert!(a.live_delta >= lo && a.live_delta <= hi, "frame {f}: {} not in [{lo}, {hi}]", a.live_delta);
            total += a.live_delta;
            assert_eq!(total, a.count() as i64);
            assert_eq!(a.count(), b.count());
            for (p, q) in a.particles().zip(b.particles()) {
                assert_eq!(p.pos, q.pos);
            }
        }
        assert!(a.count() > 0);
        // The arena holds the list and the dead still named as a parent, no more.
        assert!(a.arena_in_use() <= 1 + 2 * a.count() + 64);
    }

    #[test]
    fn cap_refuses() {
        let t = template(40, 6.0, 200);
        let mut a = Sim::new(t, 7);
        for _ in 0..200 {
            a.begin();
            let below = 50 - a.count() as i64;
            let mut g = ExactGate { below };
            a.advance(0.05, &mut g);
            assert!(a.count() <= 50);
        }
        assert!(a.dropped > 0);
        assert!(a.count() <= 50);
    }

    #[test]
    fn i32_and_ftol() {
        assert_eq!(i32w(0x8000_0000), -0x8000_0000);
        assert_eq!(i32w(-1), -1);
        assert_eq!(i32w(5 - 4294967295), 6);
        assert_eq!(ftol(f64::NAN), -2147483648);
        assert_eq!(ftol(-1.5), -1);
        assert_eq!(ftol(2147483648.0), -2147483648);
    }
}
