//! Round 764's review, F1: `SrEfpHosts`, EquipFxBatch's hosts chosen, culled and placed once a
//! frame (core::efp_hosts). GDScript gives it CrowdGpu's layouts (their bone pages), each batch's
//! ghost host table and its draws, and each frame the body data, the clock and the camera; it
//! returns every drawn host's frame packed into one buffer (a texture's bytes) and each batch's
//! start in it, and sets each draw's visible instance count and its bounds itself.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::OnceLock;

use godot::classes::RenderingServer;
use godot::prelude::*;

use crate::core::efp_hosts::{self, BatchIn, Cam, FRAME_FLOATS};

/// Frames a texture row holds (EquipFxBatch.FRAMES_PER_ROW): 3 texels each.
const FRAMES_PER_ROW: usize = 64;
/// Bounds are sent again only when they moved this far (units; OURS): a culling-tree update a
/// draw on the render thread each time.
const AABB_SLACK: f32 = 16.0;
/// Margin around the drawn bodies' places (OURS): an effect reaches past its body.
const AABB_MARGIN: f32 = 40.0;
/// Layouts a host table names (efp_hosts: 4 bits of host[3]).
const MAX_LAYOUTS: i64 = 16;

/// The machine's threads, read once (the re-review's R4: a read is a cgroup file on Linux, ~45 us).
fn machine_threads() -> usize {
    static N: OnceLock<usize> = OnceLock::new();
    *N.get_or_init(|| std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1))
}

/// f32s as their bytes (FORMAT_RGBAF / FORMAT_RF: the machine's f32), safely (the re-review's R2).
pub fn f32_bytes(v: &[f32]) -> PackedByteArray {
    let mut out = Vec::with_capacity(v.len() * 4);
    for f in v {
        out.extend_from_slice(&f.to_ne_bytes());
    }
    PackedByteArray::from(&out[..])
}

#[derive(Default)]
struct Batch {
    ghosts: PackedFloat32Array,
    direct: PackedFloat32Array,
    /// Each draw: its MultiMesh, the instances a host takes, the visible count last sent.
    draws: Vec<(Rid, i64, i64)>,
    /// The draws' instances (for their bounds) and the bounds last sent.
    insts: Vec<Rid>,
    sent: Option<([f32; 3], [f32; 3])>,
    drawn: usize,
    live: bool,
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrEfpHosts {
    layouts: Vec<(Vec<PackedFloat32Array>, usize)>,
    batches: HashMap<i64, Batch>,
    totals: [i64; 5],
    broken: bool,
    starts: HashMap<i64, usize>,
    needed: usize,
    panic_next: bool,
}

#[godot_api]
impl SrEfpHosts {
    /// Layout `i`'s bone pages (CrowdGpu.Layout.pages) and its row width in texels.
    #[func]
    fn set_layout(&mut self, i: i64, width: i64, pages: VarArray) {
        // The re-review's R5: a host names at most MAX_LAYOUTS layouts; any other index is refused.
        if !(0..MAX_LAYOUTS).contains(&i) {
            return;
        }
        let i = i as usize;
        if self.layouts.len() <= i {
            self.layouts.resize_with(i + 1, || (Vec::new(), 0));
        }
        let p = pages.iter_shared().map(|v| v.try_to::<PackedFloat32Array>().unwrap_or_default()).collect();
        self.layouts[i] = (p, width.max(0) as usize);
    }

    /// Batch `id`'s ghost hosts (HOST_FLOATS each: slot, bone, row scale, layout index, rest x
    /// chain, that x pose).
    #[func]
    fn set_ghosts(&mut self, id: i64, hosts: PackedFloat32Array) {
        self.batches.entry(id).or_default().ghosts = hosts;
    }

    /// Batch `id`'s direct hosts this frame (DIRECT_FLOATS each: the frame, the body's place).
    #[func]
    fn set_direct(&mut self, id: i64, hosts: PackedFloat32Array) {
        self.batches.entry(id).or_default().direct = hosts;
    }

    /// Batch `id`'s draws: their MultiMeshes, the instances a host takes on each, their instances.
    #[func]
    fn set_draws(&mut self, id: i64, multimeshes: VarArray, strides: PackedInt32Array, instances: VarArray) {
        let b = self.batches.entry(id).or_default();
        let mms: Vec<Rid> = multimeshes.iter_shared().map(|v| v.try_to::<Rid>().unwrap_or(Rid::Invalid)).collect();
        let st = strides.as_slice();
        // The visible counts are sent again (-1): a MultiMesh whose instance count GDScript changed
        // shows all of its instances until told otherwise.
        b.draws = mms.iter().enumerate().map(|(k, &r)| (r, st.get(k).copied().unwrap_or(0) as i64, -1)).collect();
        b.insts = instances.iter_shared().map(|v| v.try_to::<Rid>().unwrap_or(Rid::Invalid)).collect();
        b.sent = None;
    }

    #[func]
    fn remove_batch(&mut self, id: i64) {
        self.batches.remove(&id);
    }

    #[func]
    fn clear(&mut self) {
        self.batches.clear();
        self.layouts.clear();
    }

    /// One frame: every batch's hosts chosen, culled and placed. Returns the frames texture's
    /// bytes (`rows` rows of FRAMES_PER_ROW frames, 3 RGBA float texels each; what does not fit is
    /// cut, and `needed_frames` tells the caller to grow it); `layout_out` gives each batch's first
    /// frame. Sets each
    /// draw's visible instances (its hosts drawn x its stride) and its bounds.
    #[func]
    fn step(
        &mut self,
        bodies: PackedFloat32Array,
        clock_ms: f32,
        reveal: PackedFloat32Array,
        view: Transform3D,
        cam_pos: Vector3,
        sx: f32,
        sy: f32,
        ortho: bool,
        range: f32,
        sight: f32,
        near: f32,
        budget: i64,
        rows: i64,
        threads: i64,
    ) -> PackedByteArray {
        if self.broken {
            return PackedByteArray::new();
        }
        match catch_unwind(AssertUnwindSafe(|| {
            if std::mem::take(&mut self.panic_next) {
                panic!("SrEfpHosts: QA panic (qa_panic_next_step)");
            }
            self.step_inner(&bodies, clock_ms, &reveal, view, cam_pos, sx, sy, ortho, range, sight, near, budget, rows, threads)
        })) {
            Ok(v) => v,
            Err(_) => {
                self.broken = true;
                PackedByteArray::new()
            }
        }
    }

    /// The frames the last step drew in all (the texture must hold this many: rows of
    /// FRAMES_PER_ROW).
    #[func]
    fn needed_frames(&self) -> i64 {
        self.needed as i64
    }

    /// QA (tests): the next step panics, as a broken step would (the re-review's R1).
    #[func]
    fn qa_panic_next_step(&mut self) {
        self.panic_next = true;
    }

    /// Whether a step panicked (EquipFxBatch then draws through its GDScript path).
    #[func]
    fn broken(&self) -> bool {
        self.broken
    }

    /// The last step's first frames, one f32 a batch id (`width` ids), as the offsets texture's
    /// bytes (FORMAT_RF).
    #[func]
    fn offsets_bytes(&self, width: i64) -> PackedByteArray {
        let mut v = vec![0.0f32; width.clamp(0, 1 << 20) as usize];
        for (id, at) in self.starts.iter() {
            if *id >= 0 && (*id as usize) < v.len() {
                v[*id as usize] = *at as f32;
            }
        }
        f32_bytes(&v)
    }

    /// The batches with a host drawn in the last step (their effects are stepped).
    #[func]
    fn drawn_ids(&self) -> PackedInt64Array {
        let mut v: Vec<i64> = self.batches.iter().filter(|(_, b)| b.drawn > 0).map(|(id, _)| *id).collect();
        v.sort_unstable();
        PackedInt64Array::from(&v[..])
    }

    /// The last step's [hosts within reach, chosen, drawn, instances, draws with any].
    #[func]
    fn totals(&self) -> PackedInt64Array {
        PackedInt64Array::from(&self.totals[..])
    }

    /// The last step's [batch id, its first frame in the buffer, its frames drawn, live 0/1] each.
    #[func]
    fn layout_out(&self) -> PackedInt64Array {
        let mut v = Vec::new();
        for (id, b) in self.batches.iter() {
            v.extend([*id, self.starts.get(id).copied().unwrap_or(0) as i64, b.drawn as i64, b.live as i64]);
        }
        PackedInt64Array::from(&v[..])
    }

    /// Tests: one ghost host's frame (12 floats), or empty.
    #[func]
    fn qa_ghost_frame(&self, body: PackedFloat32Array, host: PackedFloat32Array, clock_ms: f32, layout: i64) -> PackedFloat32Array {
        let Some((pages, w)) = self.layouts.get(layout.max(0) as usize) else { return PackedFloat32Array::new() };
        let ps: Vec<&[f32]> = pages.iter().map(|p| p.as_slice()).collect();
        let (b, h) = (body.as_slice(), host.as_slice());
        if b.len() < efp_hosts::BODY_FLOATS || h.len() < efp_hosts::HOST_FLOATS {
            return PackedFloat32Array::new();
        }
        match efp_hosts::ghost_frame(b, h, clock_ms, &ps, *w) {
            Some(f) => PackedFloat32Array::from(&f.iter().flat_map(|r| r.iter().copied()).collect::<Vec<f32>>()[..]),
            None => PackedFloat32Array::new(),
        }
    }
}

impl SrEfpHosts {
    #[allow(clippy::too_many_arguments)]
    fn step_inner(
        &mut self,
        bodies: &PackedFloat32Array,
        clock_ms: f32,
        reveal: &PackedFloat32Array,
        view: Transform3D,
        cam_pos: Vector3,
        sx: f32,
        sy: f32,
        ortho: bool,
        range: f32,
        sight: f32,
        near: f32,
        budget: i64,
        rows: i64,
        threads: i64,
    ) -> PackedByteArray {
        let r = reveal.as_slice();
        let rv = [r.first().copied().unwrap_or(0.0), r.get(1).copied().unwrap_or(0.0), r.get(2).copied().unwrap_or(0.0), r.get(3).copied().unwrap_or(0.0)];
        let b = view.basis.rows;
        let o = view.origin;
        let cam = Cam {
            pos: [cam_pos.x, cam_pos.y, cam_pos.z],
            view: [[b[0].x, b[0].y, b[0].z, o.x], [b[1].x, b[1].y, b[1].z, o.y], [b[2].x, b[2].y, b[2].z, o.z]],
            sx,
            sy,
            ortho,
            range,
            sight,
            near,
        };
        let layouts: Vec<(Vec<&[f32]>, usize)> =
            self.layouts.iter().map(|(p, w)| (p.iter().map(|x| x.as_slice()).collect(), *w)).collect();
        // A stable batch order: by id.
        let mut ids: Vec<i64> = self.batches.keys().copied().collect();
        ids.sort_unstable();
        let ins: Vec<BatchIn> = ids
            .iter()
            .map(|id| {
                let b = &self.batches[id];
                BatchIn { ghosts: b.ghosts.as_slice(), direct: b.direct.as_slice() }
            })
            .collect();
        // The effects' thread setting (EfpSimNative.threads: OPENSRO_EFP_THREADS, Godot's pool, 4
        // at most), never past the machine's (the re-review's R4).
        let threads = (threads.max(1) as usize).min(machine_threads());
        let (outs, t) = efp_hosts::step(&ins, bodies.as_slice(), &layouts, clock_ms, &rv, &cam, budget.max(0) as usize, threads);
        self.totals = [t.in_reach as i64, t.chosen as i64, t.drawn as i64, 0, 0];
        // The packed frames: each batch's after the one before (in id order), and a texel row of
        // offsets is the caller's (layout_out names each batch's start).
        let cap_frames = rows.clamp(0, 1 << 16) as usize * FRAMES_PER_ROW;
        let mut buf = vec![0.0f32; cap_frames * FRAME_FLOATS];
        let mut at = 0usize;
        let mut starts: HashMap<i64, usize> = HashMap::new();
        let mut rs = RenderingServer::singleton();
        for (k, id) in ids.iter().enumerate() {
            let out = &outs[k];
            starts.insert(*id, at);
            let fit = out.drawn.min(cap_frames.saturating_sub(at));
            if fit > 0 {
                buf[at * FRAME_FLOATS..(at + fit) * FRAME_FLOATS].copy_from_slice(&out.frames[..fit * FRAME_FLOATS]);
            }
            at += out.drawn;
            let b = self.batches.get_mut(id).unwrap();
            b.drawn = fit;
            b.live = out.live;
            for d in b.draws.iter_mut() {
                let want = fit as i64 * d.1;
                self.totals[3] += want;
                self.totals[4] += (want > 0) as i64;
                if d.2 != want {
                    rs.multimesh_set_visible_instances(d.0, want as i32);
                    d.2 = want;
                }
            }
            if fit > 0 {
                let moved = match b.sent {
                    None => true,
                    Some((lo, hi)) => (0..3).any(|i| (lo[i] - out.lo[i]).abs() > AABB_SLACK || (hi[i] - out.hi[i]).abs() > AABB_SLACK),
                };
                if moved {
                    b.sent = Some((out.lo, out.hi));
                    let pos = Vector3::new(out.lo[0] - AABB_MARGIN, out.lo[1] - AABB_MARGIN, out.lo[2] - AABB_MARGIN);
                    let size = Vector3::new(
                        out.hi[0] - out.lo[0] + 2.0 * AABB_MARGIN,
                        out.hi[1] - out.lo[1] + 2.0 * AABB_MARGIN,
                        out.hi[2] - out.lo[2] + 2.0 * AABB_MARGIN,
                    );
                    for inst in b.insts.iter() {
                        rs.instance_set_custom_aabb(*inst, Aabb::new(pos, size));
                    }
                }
            }
        }
        self.starts = starts;
        self.needed = at;
        f32_bytes(&buf)
    }
}
