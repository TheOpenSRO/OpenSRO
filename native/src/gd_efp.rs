//! The effect simulation's gdext binding (round 763): `SrEfpTemplate` (a compiled EfpSim.Template,
//! packed by EfpSimNative.pack_template), `SrEfpSim` (one playing effect, core/efp_sim.rs, with
//! what it draws, core/efp_out.rs) and `SrEfpBatch` (EfpSimBatch's ordered batch on the pool,
//! core/efp_batch.rs). Plain data in and out: packed arrays and one Dictionary per call, never a
//! Variant per particle. GDScript reaches them by name (client/scripts/efp/efp_sim_native.gd), so
//! the client compiles and runs without the library, in GDScript.
//!
//! Threading: called from the main thread. A batch steps the effects on the pool's threads and the
//! main thread while the main thread waits for it; each effect sits behind its own mutex, held by
//! one thread at a time.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use godot::prelude::*;

use crate::core::efp_batch::{self, SimBox};
use crate::core::efp_out::{DrawNode, LinkNode, STRIDE};
use crate::core::efp_sim::{self, Cmd, ExactGate, Quality, ScaleGraph, Sim, Template, Tpl};
use crate::core::gdmath::{B3, V3};
use crate::core::pool::{lock, Pool};

/// The effect interface's own number (EfpSimNative.EFP_API): additive classes, so the readers'
/// API number (core::API) is unchanged and an older library keeps them.
const EFP_API: i64 = 1;

static POOL: OnceLock<Pool> = OnceLock::new();

fn pool() -> &'static Pool {
    POOL.get_or_init(Pool::new)
}

/// The pool's threads ended and joined (the library's deinit, gd.rs).
pub fn shutdown_pool() {
    if let Some(p) = POOL.get() {
        p.set_helpers(0);
    }
}

fn v3(v: Vector3) -> V3 {
    V3(v.x, v.y, v.z)
}

fn gv3(v: V3) -> Vector3 {
    Vector3::new(v.0, v.1, v.2)
}

fn b3(b: &Basis) -> B3 {
    let r = &b.rows;
    B3 { r: [[r[0].x, r[0].y, r[0].z], [r[1].x, r[1].y, r[1].z], [r[2].x, r[2].y, r[2].z]] }
}

/// Nine floats by rows; nine zeros (or too few) stand for the identity (a camera rotation the
/// effect does not draw with, EfpSimNative.run_batch).
fn b3_from(f: &[f32]) -> B3 {
    if f.len() >= 9 && f[..9].iter().any(|&x| x != 0.0) {
        B3::from_rows(&f[..9])
    } else {
        crate::core::gdmath::IDENTITY
    }
}

fn quality(interval_mul: i64, threshold: i64) -> Quality {
    Quality { interval_mul, threshold }
}

// ---------------------------------------------------------------- the template

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrEfpTemplate {
    t: Option<Arc<Template>>,
}

fn get<T: FromGodot>(d: &VarDictionary, k: &str) -> Result<T, String> {
    d.get(k).ok_or_else(|| format!("missing {k}"))?.try_to::<T>().map_err(|e| format!("{k}: {e}"))
}

/// The packed Template (EfpSimNative.pack_template's keys) as core::Template.
fn unpack(d: &VarDictionary) -> Result<Template, String> {
    let n = get::<i64>(d, "n")? as usize;
    let parent = get::<PackedInt32Array>(d, "parent")?;
    let child_start = get::<PackedInt32Array>(d, "child_start")?;
    let children = get::<PackedInt32Array>(d, "children")?;
    let frames = get::<PackedInt64Array>(d, "frames")?;
    let life = get::<PackedInt32Array>(d, "life")?;
    let has_emit = get::<PackedByteArray>(d, "has_emit")?;
    let emit_i = get::<PackedInt64Array>(d, "emit_i")?; // delay, dur, int, max per node
    let e_per = get::<PackedFloat64Array>(d, "e_per")?;
    let lv = get::<PackedInt64Array>(d, "lv")?; // orbit, rot, vel, move per node
    let flags = get::<PackedByteArray>(d, "flags")?; // keep_rot, keep_pos, follows_any per node
    let frame_start = get::<PackedInt32Array>(d, "frame_start")?; // per node: first frame index (n + 1)
    let cmd_start = get::<PackedInt32Array>(d, "cmd_start")?; // per frame: first command (frames + 1)
    let cmd_kind = get::<PackedInt32Array>(d, "cmd_kind")?;
    let cmd_space = get::<PackedInt64Array>(d, "cmd_space")?;
    let cmd_f = get::<PackedFloat64Array>(d, "cmd_f")?; // 9 per command
    let cmd_c = get::<PackedInt64Array>(d, "cmd_c")?;
    let sg_has = get::<PackedByteArray>(d, "sg_has")?;
    let sg_ab = get::<PackedFloat64Array>(d, "sg_ab")?;
    let sg_start = get::<PackedInt32Array>(d, "sg_start")?;
    let sg_times = get::<PackedFloat32Array>(d, "sg_times")?;
    let sg_scales = get::<PackedFloat32Array>(d, "sg_scales")?;
    let fan_i = get::<PackedInt64Array>(d, "fan")?; // rate, kids, fan per node
    let fan_child = get::<i64>(d, "fan_child")?;
    let has_fan = get::<bool>(d, "has_fan")?;
    let need = |len: usize, want: usize, what: &str| if len < want { Err(format!("{what} short")) } else { Ok(()) };
    need(parent.len(), n, "parent")?;
    need(child_start.len(), n + 1, "child_start")?;
    need(frames.len(), n, "frames")?;
    need(life.len(), n, "life")?;
    need(has_emit.len(), n, "has_emit")?;
    need(emit_i.len(), 4 * n, "emit_i")?;
    need(e_per.len(), n, "e_per")?;
    need(lv.len(), 4 * n, "lv")?;
    need(flags.len(), 3 * n, "flags")?;
    need(frame_start.len(), n + 1, "frame_start")?;
    need(sg_has.len(), n, "sg_has")?;
    need(sg_ab.len(), 2 * n, "sg_ab")?;
    need(sg_start.len(), n + 1, "sg_start")?;
    let nf = *frame_start.as_slice().get(n).unwrap_or(&0) as usize;
    need(cmd_start.len(), nf + 1, "cmd_start")?;
    let nc = *cmd_start.as_slice().get(nf).unwrap_or(&0) as usize;
    need(cmd_kind.len(), nc, "cmd_kind")?;
    need(cmd_space.len(), nc, "cmd_space")?;
    need(cmd_f.len(), 9 * nc, "cmd_f")?;
    need(cmd_c.len(), nc, "cmd_c")?;
    if has_fan {
        need(fan_i.len(), 3 * n, "fan")?;
    }
    let (cs, ch) = (child_start.as_slice(), children.as_slice());
    let mut t = Template { fan_child, has_fan, ..Default::default() };
    for i in 0..n {
        let (c0, c1) = (cs[i] as usize, cs[i + 1] as usize);
        if c0 > c1 || c1 > ch.len() {
            return Err("children range".into());
        }
        let kids: Vec<u32> = ch[c0..c1].iter().map(|&k| k as u32).collect();
        if kids.iter().any(|&k| k as usize >= n) || (parent[i] >= n as i32) {
            return Err("node index".into());
        }
        let (f0, f1) = (frame_start[i] as usize, frame_start[i + 1] as usize);
        if f0 > f1 || f1 > nf {
            return Err("frame range".into());
        }
        let mut schedule = Vec::with_capacity(f1 - f0);
        for f in f0..f1 {
            let (k0, k1) = (cmd_start[f] as usize, cmd_start[f + 1] as usize);
            if k0 > k1 || k1 > nc {
                return Err("command range".into());
            }
            let mut list = Vec::with_capacity(k1 - k0);
            for k in k0..k1 {
                let kind = cmd_kind[k];
                if !(0..=efp_sim::K_MAX as i32).contains(&kind) {
                    return Err(format!("command kind {kind}"));
                }
                let mut v = [0.0f32; 9];
                for (j, slot) in v.iter_mut().enumerate() {
                    *slot = cmd_f[9 * k + j] as f32;
                }
                list.push(Cmd { kind: kind as u8, space: cmd_space[k], v, f: cmd_f[9 * k], color: cmd_c[k] });
            }
            schedule.push(list);
        }
        if schedule.len() as i64 != frames[i].max(0) {
            return Err("schedule length".into());
        }
        let scale_graph = if sg_has[i] != 0 {
            let (g0, g1) = (sg_start[i] as usize, sg_start[i + 1] as usize);
            if g0 > g1 || g1 > sg_times.len() || 3 * g1 > sg_scales.len() {
                return Err("scale graph range".into());
            }
            Some(ScaleGraph {
                a: sg_ab[2 * i],
                b: sg_ab[2 * i + 1],
                times: sg_times.as_slice()[g0..g1].to_vec(),
                scales: (g0..g1).map(|k| V3(sg_scales[3 * k], sg_scales[3 * k + 1], sg_scales[3 * k + 2])).collect(),
            })
        } else {
            None
        };
        let life_v = life[i];
        if !(0..=2).contains(&life_v) {
            return Err("life".into());
        }
        t.tpls.push(Tpl {
            parent: parent[i],
            children: kids,
            frames: frames[i],
            life: life_v as u8,
            has_emit: has_emit[i] != 0,
            e_delay: emit_i[4 * i],
            e_dur: emit_i[4 * i + 1],
            e_int: emit_i[4 * i + 2],
            e_max: emit_i[4 * i + 3],
            e_per: e_per[i],
            lv_orbit: lv[4 * i],
            lv_rot: lv[4 * i + 1],
            lv_vel: lv[4 * i + 2],
            lv_move: lv[4 * i + 3],
            keep_rot: flags[3 * i] != 0,
            keep_pos: flags[3 * i + 1] != 0,
            follows_any: flags[3 * i + 2] != 0,
            schedule,
            scale_graph,
        });
        if has_fan {
            t.rate.push(fan_i[3 * i]);
            t.kids.push(fan_i[3 * i + 1]);
            t.fan.push(fan_i[3 * i + 2]);
        }
    }
    Ok(t)
}

#[godot_api]
impl SrEfpTemplate {
    /// Builds from EfpSimNative.pack_template's Dictionary. "" on success, else why not (the client
    /// then simulates the effect in GDScript).
    #[func]
    fn build(&mut self, d: VarDictionary) -> GString {
        match unpack(&d) {
            Ok(t) => {
                self.t = Some(Arc::new(t));
                GString::new()
            }
            Err(e) => GString::from(e.as_str()),
        }
    }

    #[func]
    fn node_count(&self) -> i64 {
        self.t.as_ref().map_or(0, |t| t.tpls.len() as i64)
    }
}

// ---------------------------------------------------------------- one effect

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrEfpSim {
    b: Option<Arc<Mutex<SimBox>>>,
    /// Main thread only: each draw node's MultiMesh RID, the instance count GDScript last gave
    /// its MultiMesh, and the visible count last sent (-2: not known).
    rids: Vec<Rid>,
    told_cap: Vec<usize>,
    shown: Vec<i64>,
}

impl SrEfpSim {
    /// Runs `f` on the effect. Round 763's review, M1: the lock survives a poisoned mutex, a
    /// broken effect (one that panicked) is left alone, and a panic in `f` marks it broken instead
    /// of escaping: None in all three cases, and `broken()` tells GDScript, which then simulates
    /// the effect in GDScript (EfpSimNative._fall_back).
    fn with<R>(&self, f: impl FnOnce(&mut SimBox) -> R) -> Option<R> {
        let b = self.b.as_ref()?;
        let mut g = lock(b);
        if g.broken {
            return None;
        }
        match catch_unwind(AssertUnwindSafe(|| f(&mut g))) {
            Ok(r) => Some(r),
            Err(_) => {
                g.broken = true;
                None
            }
        }
    }
}

#[godot_api]
impl SrEfpSim {
    /// EfpSim._init(template, seed): a fresh effect whose stream is `RandomNumberGenerator.seed =
    /// seed`'s. False when the template did not build.
    #[func]
    fn setup(&mut self, tmpl: Gd<SrEfpTemplate>, seed: i64) -> bool {
        let Some(t) = tmpl.bind().t.clone() else { return false };
        self.b = Some(Arc::new(Mutex::new(SimBox::new(Sim::new(t, seed as u64)))));
        true
    }

    /// The plate / mesh nodes drawn (EfpEffect._draws): template index, view (0 rotation, 1
    /// billboard, 2 Y billboard, 3 velocity billboard) and whether the node is shared-turn.
    #[func]
    fn set_draws(&self, tpls: PackedInt32Array, views: PackedInt32Array, turns: PackedByteArray) {
        self.with(|b| {
            b.out.draws = (0..tpls.len())
                .map(|i| DrawNode {
                    tpl: tpls[i].max(0) as u32,
                    view: views.as_slice().get(i).copied().unwrap_or(0).clamp(0, 3) as u8,
                    turn: turns.as_slice().get(i).copied().unwrap_or(0) != 0,
                    cap: 0,
                })
                .collect();
            b.out.bufs.clear();
            b.out.counts.clear();
        });
    }

    /// Each draw node's MultiMesh RID, for apply_draws (EfpEffect.use_native_sim).
    #[func]
    fn set_draw_rids(&mut self, rids: VarArray) {
        self.rids = rids.iter_shared().map(|v| v.try_to::<Rid>().unwrap_or(Rid::Invalid)).collect();
        self.told_cap = vec![0; self.rids.len()];
        self.shown = vec![-2; self.rids.len()];
    }

    /// The draw nodes whose MultiMesh must grow before apply_draws: [node, instance count]...
    /// (EfpEffect sets `instance_count` on the MultiMesh, which reallocates it; rare: a node's count
    /// only doubles).
    #[func]
    fn draw_growth(&mut self) -> PackedInt32Array {
        let mut out = Vec::new();
        let caps: Vec<usize> = self.with(|b| b.out.draws.iter().map(|d| d.cap).collect()).unwrap_or_default();
        for (i, &cap) in caps.iter().enumerate() {
            if i < self.told_cap.len() && self.told_cap[i] != cap {
                self.told_cap[i] = cap;
                self.shown[i] = -2;
                out.push(i as i32);
                out.push(cap as i32);
            }
        }
        PackedInt32Array::from(out)
    }

    /// The built buffers into the MultiMeshes through the RenderingServer, from here (one call a
    /// node with particles, and its visible count when it changed): what EfpEffect._update_draws
    /// leaves in them. Call draw_growth (and grow) first. Returns the buffers sent.
    #[func]
    fn apply_draws(&mut self) -> i64 {
        let Some(b) = self.b.clone() else { return 0 };
        let mut bx = lock(&b);
        if bx.broken {
            return 0;
        }
        bx.out.fresh = false;
        let mut rs = godot::classes::RenderingServer::singleton();
        let mut sent = 0;
        let n = bx.out.draws.len().min(self.rids.len()).min(bx.out.counts.len()).min(bx.out.bufs.len());
        for i in 0..n {
            let c = bx.out.counts[i];
            let cap = bx.out.draws[i].cap;
            if c == 0 && self.shown[i] == 0 {
                continue;
            }
            if self.told_cap[i] != cap {
                // draw_growth was not called: never send a buffer the MultiMesh cannot hold.
                continue;
            }
            let rid = self.rids[i];
            if c > 0 {
                let buf = &bx.out.bufs[i];
                rs.multimesh_set_buffer(rid, &PackedFloat32Array::from(&buf[..cap * STRIDE]));
                sent += 1;
            }
            if self.shown[i] != c as i64 {
                rs.multimesh_set_visible_instances(rid, c as i32);
                self.shown[i] = c as i64;
            }
        }
        sent
    }

    /// Round 764 (EquipFxBatch): draw node `i`'s built buffer, its first `counts[i]` instances
    /// (STRIDE floats each, Godot's MultiMesh layout) -- what apply_draws sends its MultiMesh. Empty
    /// for a node out of range or a broken effect.
    #[func]
    fn draw_buffer(&self, i: i64) -> PackedFloat32Array {
        self.with(|b| {
            let i = i as usize;
            if i < b.out.bufs.len() && i < b.out.counts.len() {
                let n = (b.out.counts[i] * STRIDE).min(b.out.bufs[i].len());
                PackedFloat32Array::from(&b.out.bufs[i][..n])
            } else {
                PackedFloat32Array::new()
            }
        })
        .unwrap_or_default()
    }

    /// Each draw node's particle count after the last build (what its MultiMesh shows).
    #[func]
    fn draw_counts(&self) -> PackedInt32Array {
        let v: Vec<i32> = self.with(|b| b.out.counts.iter().map(|&c| c as i32).collect()).unwrap_or_default();
        PackedInt32Array::from(v)
    }

    /// The Link nodes (EfpEffect._links): template index, kind (0 LinkDPipe, 1 LinkPipe, 2
    /// LinkObj) and whether its pipes are shared-turn (their strips are then built natively).
    #[func]
    fn set_links(&self, tpls: PackedInt32Array, kinds: PackedByteArray, turns: PackedByteArray) {
        self.with(|b| {
            b.out.links = (0..tpls.len())
                .map(|i| LinkNode {
                    tpl: tpls[i].max(0) as u32,
                    kind: kinds.as_slice().get(i).copied().unwrap_or(0).min(2),
                    turn: turns.as_slice().get(i).copied().unwrap_or(0) != 0,
                })
                .collect();
            b.out.strips.clear();
        });
    }

    /// Per Link node its strip when built natively: [vertex count, verts (PackedVector3Array),
    /// colours (PackedColorArray), uvs (PackedVector2Array), custom0, custom1 (PackedFloat32Array,
    /// empty unless shared-turn)], or null for a node GDScript builds from the chains.
    #[func]
    fn take_strips(&self) -> VarArray {
        let mut out = VarArray::new();
        self.with(|b| {
            for (l, o) in b.out.links.iter().zip(b.out.strips.iter()) {
                if !l.native() {
                    out.push(&Variant::nil());
                    continue;
                }
                let mut a = VarArray::new();
                a.push(&(o.nv() as i64).to_variant());
                a.push(&PackedVector3Array::from(o.verts.iter().map(|&v| gv3(v)).collect::<Vec<_>>()).to_variant());
                a.push(&PackedColorArray::from(o.colors.iter().map(|c| Color::from_rgba(c[0], c[1], c[2], c[3])).collect::<Vec<_>>()).to_variant());
                a.push(&PackedVector2Array::from(o.uvs.iter().map(|u| Vector2::new(u[0], u[1])).collect::<Vec<_>>()).to_variant());
                a.push(&PackedFloat32Array::from(o.c0.as_slice()).to_variant());
                a.push(&PackedFloat32Array::from(o.c1.as_slice()).to_variant());
                out.push(&a.to_variant());
            }
        });
        out
    }

    /// EfpSim.restart. Returns the particles dropped (live_total's share).
    #[func]
    fn restart(&self) -> i64 {
        self.with(|b| b.sim.restart()).unwrap_or(0)
    }

    /// EfpSim.clear. Returns the particles dropped.
    #[func]
    fn clear(&self) -> i64 {
        self.with(|b| b.sim.clear()).unwrap_or(0)
    }

    #[func]
    fn finished(&self) -> bool {
        self.with(|b| b.sim.finished()).unwrap_or(true)
    }

    /// Whether the effect is broken: a panic stepped it (round 763's review, M1). Every call on it
    /// then does nothing.
    #[func]
    fn broken(&self) -> bool {
        self.b.as_ref().is_some_and(|b| lock(b).broken)
    }

    /// QA (efp_native_test): the effect's next batch step panics on purpose, to prove the batch
    /// returns an error instead of hanging, and that the client falls back to GDScript.
    #[func]
    fn qa_panic_next_step(&self) {
        if let Some(b) = self.b.as_ref() {
            lock(b).panic_next = true;
        }
    }

    /// EfpSim.advance on its own: live_total is `base`, the cap `limit`. [frames stepped, change],
    /// or empty when the effect is broken.
    #[func]
    fn advance(&self, delta: f64, base: i64, limit: i64, keep: bool, interval_mul: i64, threshold: i64) -> PackedInt64Array {
        let r = self
            .with(|b| {
                b.sim.keep = keep;
                b.sim.quality = quality(interval_mul, threshold);
                b.sim.begin();
                let n = b.sim.advance(delta, &mut ExactGate { below: limit - base });
                [n, b.sim.live_delta]
            })
            ;
        match r {
            Some(r) => PackedInt64Array::from(&r[..]),
            None => PackedInt64Array::new(),
        }
    }

    /// EfpSim.step on its own. Returns the change.
    #[func]
    fn step(&self, base: i64, limit: i64, keep: bool, interval_mul: i64, threshold: i64) -> i64 {
        self.with(|b| {
            b.sim.keep = keep;
            b.sim.quality = quality(interval_mul, threshold);
            b.sim.begin();
            b.sim.step(&mut ExactGate { below: limit - base });
            b.sim.live_delta
        })
        .unwrap_or(0)
    }

    #[func]
    fn growth_bounds(&self, delta: f64, interval_mul: i64, threshold: i64) -> Vector2i {
        self.with(|b| {
            b.sim.quality = quality(interval_mul, threshold);
            let (lo, hi) = b.sim.growth_bounds(delta);
            Vector2i::new(lo as i32, hi as i32)
        })
        .unwrap_or(Vector2i::ZERO)
    }

    #[func]
    fn set_origin(&self, pos: Vector3, rot: Basis) -> bool {
        self.with(|b| b.sim.set_origin(v3(pos), b3(&rot))).unwrap_or(false)
    }

    #[func]
    fn shift(&self, v: Vector3) {
        self.with(|b| b.sim.shift(v3(v)));
    }

    #[func]
    fn origin(&self) -> Vector3 {
        self.with(|b| gv3(b.sim.origin())).unwrap_or(Vector3::ZERO)
    }

    /// [age, dropped, spawned, revived, particle count].
    #[func]
    fn counters(&self) -> PackedInt64Array {
        let r = self.with(|b| [b.sim.age, b.sim.dropped, b.sim.spawned, b.sim.revived, b.sim.count() as i64]).unwrap_or([0; 5]);
        PackedInt64Array::from(&r[..])
    }

    #[func]
    fn count(&self) -> i64 {
        self.with(|b| b.sim.count() as i64).unwrap_or(0)
    }

    /// The step clock (EfpSim._acc).
    #[func]
    fn acc(&self) -> f64 {
        self.with(|b| b.sim.acc).unwrap_or(0.0)
    }

    #[func]
    fn set_acc(&self, acc: f64) {
        self.with(|b| b.sim.acc = acc);
    }

    /// The draws built now from `cam` (EfpEffect._update_draws' cam_rot).
    #[func]
    fn build_outputs(&self, cam: Basis) {
        self.with(|b| {
            let SimBox { sim, out, .. } = b;
            out.build(sim, &b3(&cam));
        });
    }

    /// Whether outputs were built after the last step and not yet taken.
    #[func]
    fn has_fresh(&self) -> bool {
        self.with(|b| b.out.fresh).unwrap_or(false)
    }

    /// The draw buffers: [counts (PackedInt32Array), then one PackedFloat32Array per draw node of
    /// its instance count x 20 floats]. Marks them taken.
    #[func]
    fn take_draws(&self) -> VarArray {
        let mut out = VarArray::new();
        self.with(|b| {
            b.out.fresh = false;
            let counts: Vec<i32> = b.out.counts.iter().map(|&c| c as i32).collect();
            out.push(&PackedInt32Array::from(counts).to_variant());
            for buf in &b.out.bufs {
                out.push(&PackedFloat32Array::from(buf.as_slice()).to_variant());
            }
        });
        out
    }

    /// The Link chains (core::efp_out::Chains): {meta: [link index, points]..., pos, col, w, y}.
    #[func]
    fn take_chains(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        self.with(|b| {
            let c = &b.out.chains;
            d.set("meta", &PackedInt32Array::from(c.meta.as_slice()));
            d.set("pos", &PackedVector3Array::from(c.pos.iter().map(|&v| gv3(v)).collect::<Vec<_>>()));
            d.set("col", &PackedInt64Array::from(c.col.as_slice()));
            d.set("w", &PackedFloat32Array::from(c.w.as_slice()));
            d.set("y", &PackedVector3Array::from(c.y.iter().map(|&v| gv3(v)).collect::<Vec<_>>()));
        });
        d
    }

    /// How many particles have a template index in `tpls`.
    #[func]
    fn count_tpls(&self, tpls: PackedInt32Array) -> i64 {
        self.with(|b| b.sim.particles().filter(|p| tpls.as_slice().contains(&(p.tpl as i32))).count() as i64).unwrap_or(0)
    }

    /// Every particle and emitter, for the parity checks and the QA log (EfpSimNative.snapshot):
    /// per particle tpl, age, flags (alive 1, dying 2, changed 4, has_rvel 8, has_shape_vel 16),
    /// color, link (list index or -1); f32s pos 3, vel 3, rot 9, rvel 9, shape 9, shape_vel 9,
    /// scale 3, uv 4, old_pos 3, old_rot 9, delta 9 (70 a particle); per emitter tpl, done, dying,
    /// acc; and the effect's counters, step clock and random state.
    #[func]
    fn dump(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        self.with(|b| {
            let s = &b.sim;
            let mut ints = Vec::new();
            let mut fl: Vec<f32> = Vec::new();
            let links = s.link_indices();
            for (i, p) in s.particles().enumerate() {
                let flags = (p.alive as i64) | (p.dying as i64) << 1 | (p.changed as i64) << 2 | (p.has_rvel as i64) << 3 | (p.has_shape_vel as i64) << 4;
                ints.extend_from_slice(&[p.tpl as i64, p.age, flags, p.color, links[i] as i64]);
                let v = |fl: &mut Vec<f32>, v: V3| fl.extend_from_slice(&[v.0, v.1, v.2]);
                let m = |fl: &mut Vec<f32>, m: &B3| {
                    for r in &m.r {
                        fl.extend_from_slice(r);
                    }
                };
                v(&mut fl, p.pos);
                v(&mut fl, p.vel);
                m(&mut fl, &p.rot);
                m(&mut fl, &p.rvel);
                m(&mut fl, &p.shape);
                m(&mut fl, &p.shape_vel);
                v(&mut fl, p.scale);
                fl.extend_from_slice(&p.uv);
                v(&mut fl, p.old_pos);
                m(&mut fl, &p.old_rot);
                m(&mut fl, &p.delta);
            }
            let mut eint = Vec::new();
            let mut eacc = Vec::new();
            for e in s.emitters() {
                eint.extend_from_slice(&[e.tpl as i64, e.done as i64, e.dying]);
                eacc.push(e.acc);
            }
            d.set("p_int", &PackedInt64Array::from(ints));
            d.set("p_f32", &PackedFloat32Array::from(fl));
            d.set("e_int", &PackedInt64Array::from(eint));
            d.set("e_acc", &PackedFloat64Array::from(eacc));
            d.set("counters", &PackedInt64Array::from(&[s.age, s.dropped, s.spawned, s.revived, s.count() as i64][..]));
            d.set("acc", s.acc);
            d.set("rng_state", s.rng_state() as i64);
            d.set("origin", gv3(s.origin()));
            d.set("arena", s.arena_in_use() as i64);
        });
        d
    }
}

// ---------------------------------------------------------------- the batch

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrEfpBatch {}

#[godot_api]
impl SrEfpBatch {
    #[func]
    fn efp_api(&self) -> i64 {
        EFP_API
    }

    /// The pool's helper threads (the main thread is one more participant).
    #[func]
    fn set_helpers(&self, n: i64) {
        pool().set_helpers(n.clamp(0, 256) as usize);
    }

    #[func]
    fn helpers(&self) -> i64 {
        pool().helpers() as i64
    }

    /// EfpSimBatch.run natively: every SrEfpSim in `sims` advanced by `delta`, the cap in their
    /// order from live_total `base` with each one's `limits[i]`, `keeps[i]` its kept flag, `cams`
    /// nine floats (rows) a sim for its draws, on up to `helpers` pool threads and this one.
    /// {steps, change, counters (age, dropped, spawned, revived, count a sim) (PackedInt64Array),
    /// waits, wait_usec, misses, by_helpers, bounds_usec, sim_usec, work, pooled}; the pool is
    /// used only from `min_work` particle-steps (round 763's review, L2). {error: String} when an
    /// element is not a set-up SrEfpSim, a sim is listed twice (L1) or a step panicked (M1): the
    /// client then turns the native simulation off for the session.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn run(
        &self,
        sims: VarArray,
        delta: f64,
        base: i64,
        limits: PackedInt64Array,
        keeps: PackedByteArray,
        cams: PackedFloat32Array,
        interval_mul: i64,
        threshold: i64,
        helpers: i64,
        min_work: i64,
    ) -> VarDictionary {
        let mut out = VarDictionary::new();
        let fail = |why: &str| {
            let mut d = VarDictionary::new();
            d.set("error", &GString::from(why));
            d
        };
        let n = sims.len();
        if limits.len() < n || keeps.len() < n {
            return fail("limits or keeps shorter than the sims");
        }
        let mut shared = Vec::with_capacity(n);
        for v in sims.iter_shared() {
            let Ok(g) = v.try_to::<Gd<SrEfpSim>>() else { return fail("an element is not an SrEfpSim") };
            let Some(b) = g.bind().b.clone() else { return fail("an SrEfpSim that was not set up") };
            shared.push(b);
        }
        let cams_v: Vec<B3> = (0..n).map(|i| b3_from(cams.as_slice().get(9 * i..9 * i + 9).unwrap_or(&[]))).collect();
        let r = efp_batch::run(
            pool(),
            shared,
            delta,
            base,
            limits.as_slice()[..n].to_vec(),
            keeps.as_slice()[..n].iter().map(|&k| k != 0).collect(),
            cams_v,
            quality(interval_mul, threshold),
            helpers.max(0) as usize,
            min_work,
        );
        let r = match r {
            Ok(r) => r,
            Err(e) => return fail(&e),
        };
        out.set("steps", &PackedInt64Array::from(r.steps));
        out.set("change", &PackedInt64Array::from(r.change));
        out.set("counters", &PackedInt64Array::from(r.counters));
        out.set("waits", r.waits);
        out.set("wait_usec", r.wait_us);
        out.set("misses", r.misses);
        out.set("by_helpers", r.by_helpers);
        out.set("bounds_usec", r.bounds_us);
        out.set("sim_usec", r.sim_us);
        out.set("work", r.work);
        out.set("pooled", r.pooled);
        out
    }

    /// The batch's default work threshold for the pool (core::efp_batch::POOL_MIN_WORK).
    #[func]
    fn pool_min_work(&self) -> i64 {
        efp_batch::POOL_MIN_WORK
    }

    /// Singular bases inverted so far (returned unchanged, as the editor build's GDScript does).
    #[func]
    fn singular_inverses(&self) -> i64 {
        crate::core::gdmath::SINGULAR_INVERSES.load(std::sync::atomic::Ordering::Relaxed) as i64
    }

    /// Floats an instance takes in a draw buffer.
    #[func]
    fn stride(&self) -> i64 {
        STRIDE as i64
    }
}
