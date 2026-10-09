//! Round 764's review, F1 (OURS; docs/rounds/r764.md section 8): EquipFxBatch's hosts -- every
//! weapon effect of a crowd -- chosen, culled and placed once a frame here, so a particle's vertex
//! reads its host's frame (3 texels) instead of composing it (about 20 texel reads, an
//! orthonormalisation, a determinant and a cube root in every vertex: the review measured that
//! as most of the +3 ms of GPU the whole swarm's effects cost).
//!
//! A host's frame is `EquipFx.place`'s: the item's frame `G` -- for a ghost (a CrowdGpu body drawn
//! from its kind's recipe) the body's transform times its clip frame's bone (CrowdGpu's
//! `ghost_item_frame`, crowd_gpu_vertex.gdshaderinc's composition) times the item's rest and chain
//! -- times the item bone's pose, its basis orthonormalised (Gram-Schmidt over the columns, as
//! `Basis.orthonormalized`) and scaled by the row's scale times cbrt(|det G|). A dressed body's
//! host comes with its frame already made (`Direct`).
//!
//! The choice (OURS, `EquipFxBatch.host_budget`): a host draws when its body is shown (its page
//! revealed, not fading out), within `range` (720: retail's LOD 0.9 x 800, READ round 761) and
//! Character Sight Range, among the `budget` nearest such hosts (0: no limit, as retail), and
//! within `near` units of the view's frustum. The budget counts hosts in every direction, so
//! turning the camera does not change which hosts are chosen.
//!
//! The 3 x 4 matrices are rows, each `[m0, m1, m2, origin]` (CrowdGpu's texel layout).

/// Floats a ghost host's table entry takes: slot, bone, row scale, layout index + 16 x the slot's
/// stamp (CrowdGpu: the body it was placed for); the item's rest x chain (3 rows); that x the item
/// bone's pose (3 rows).
pub const HOST_FLOATS: usize = 28;
/// Floats a direct host takes: its frame (3 rows) and its body's place (x, y, z, 0).
pub const DIRECT_FLOATS: usize = 16;
/// Floats a CrowdGpu body takes (CrowdGpu.FLOATS_PER_BODY): its transform (3 rows), its clip
/// (first row, frame count, duration ms, offset ms), (object colour, fade, -, -).
pub const BODY_FLOATS: usize = 20;
/// CrowdAnim.QUANTUM_MS and CrowdGpu.PAGE_ROWS.
pub const QUANTUM_MS: f32 = 1000.0 / 120.0;
pub const PAGE_ROWS: usize = 1024;
/// Floats a frame takes in the output (3 rows).
pub const FRAME_FLOATS: usize = 12;
/// The layout index's bits in host[3] (16 layouts; the slot's stamp above them).
pub const LAYOUT_MASK: u32 = 15;

pub type M34 = [[f32; 4]; 3];

pub fn rows(s: &[f32]) -> M34 {
    [[s[0], s[1], s[2], s[3]], [s[4], s[5], s[6], s[7]], [s[8], s[9], s[10], s[11]]]
}

/// a x b, both affine 3 x 4 (the shader's mat4 product with a (0, 0, 0, 1) last row).
pub fn mul(a: &M34, b: &M34) -> M34 {
    let mut r = [[0.0f32; 4]; 3];
    for i in 0..3 {
        for j in 0..4 {
            let mut v = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
            if j == 3 {
                v += a[i][3];
            }
            r[i][j] = v;
        }
    }
    r
}

fn det3(m: &M34) -> f32 {
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn norm(a: [f32; 3]) -> [f32; 3] {
    let l = dot(a, a).sqrt();
    if l > 0.0 && l.is_finite() {
        [a[0] / l, a[1] / l, a[2] / l]
    } else {
        [0.0, 0.0, 0.0]
    }
}

/// The body's clip frame row (crowd_gpu_vertex.gdshaderinc, CrowdGpu.frame_of): the nearest
/// quantum of the body's time into its loop.
pub fn clip_row(body: &[f32], clock_ms: f32) -> usize {
    let first = (body[12] + 0.5) as i64;
    let count = ((body[13] + 0.5) as i64).max(1);
    let dur = body[14].max(1.0);
    let t = clock_ms + body[15];
    let ms = t - dur * (t / dur).floor();
    (first + ((ms / QUANTUM_MS + 0.5) as i64) % count).max(0) as usize
}

/// Whether a body draws (its fade texel, CrowdGpu._write_fade): not fading out (negative; a freed
/// slot holds -1 too), and a held page's only once revealed (`reveal`: srr_crowd_reveal).
pub fn body_shown(body: &[f32], clock_ms: f32, reveal: &[f32; 4]) -> bool {
    let f = body[17];
    if f < 0.0 {
        return false;
    }
    if f >= 3.5e6 {
        let k = ((f - 4.0e6 + 0.5) as i64).clamp(0, 3) as usize;
        let e = (clock_ms - reveal[k]).max(0.0) / 1000.0;
        return (255.0f32 / 2.0 * e).floor().min(255.0) > 0.0;
    }
    true
}

/// A ghost host's frame, or None when its bone's row is not in `pages`.
pub fn ghost_frame(body: &[f32], host: &[f32], clock_ms: f32, pages: &[&[f32]], width: usize) -> Option<M34> {
    let row = clip_row(body, clock_ms);
    let bone = (host[1] + 0.5) as usize;
    let page = pages.get(row / PAGE_ROWS)?;
    let o = ((row % PAGE_ROWS) * width + bone * 3) * 4;
    if o + 12 > page.len() || bone * 3 + 3 > width {
        return None;
    }
    let k = mul(&rows(&body[0..12]), &rows(&page[o..o + 12]));
    let g = mul(&k, &rows(&host[4..16]));
    let a = mul(&k, &rows(&host[16..28]));
    let x = norm([a[0][0], a[1][0], a[2][0]]);
    let c1 = [a[0][1], a[1][1], a[2][1]];
    let d1 = dot(x, c1);
    let y = norm([c1[0] - x[0] * d1, c1[1] - x[1] * d1, c1[2] - x[2] * d1]);
    let c2 = [a[0][2], a[1][2], a[2][2]];
    let (d2x, d2y) = (dot(x, c2), dot(y, c2));
    let z = norm([c2[0] - x[0] * d2x - y[0] * d2y, c2[1] - x[1] * d2x - y[1] * d2y, c2[2] - x[2] * d2x - y[2] * d2y]);
    let s = host[2] * det3(&g).abs().cbrt();
    Some([
        [x[0] * s, y[0] * s, z[0] * s, a[0][3]],
        [x[1] * s, y[1] * s, z[1] * s, a[1][3]],
        [x[2] * s, y[2] * s, z[2] * s, a[2][3]],
    ])
}

/// The camera: its place, its world-to-view rows, the projection's x and y scales, whether it is
/// orthogonal; the reach (720), Character Sight Range (0: none) and the frustum's margin.
#[derive(Clone, Copy, Debug)]
pub struct Cam {
    pub pos: [f32; 3],
    pub view: M34,
    pub sx: f32,
    pub sy: f32,
    pub ortho: bool,
    pub range: f32,
    pub sight: f32,
    pub near: f32,
}

impl Cam {
    /// Within `near` of the frustum (the old shader's sphere test in view space).
    pub fn sees(&self, p: [f32; 3]) -> bool {
        if self.ortho {
            return true;
        }
        let v = |r: usize| self.view[r][0] * p[0] + self.view[r][1] * p[1] + self.view[r][2] * p[2] + self.view[r][3];
        let (vx, vy, vz) = (v(0), v(1), v(2));
        let depth = -vz;
        depth + self.near >= 0.0
            && vx.abs() * self.sx <= depth + self.near * (self.sx * self.sx + 1.0).sqrt()
            && vy.abs() * self.sy <= depth + self.near * (self.sy * self.sy + 1.0).sqrt()
    }
}

/// One batch's input: its ghost hosts' table (HOST_FLOATS each) and its direct hosts
/// (DIRECT_FLOATS each, made this frame).
pub struct BatchIn<'a> {
    pub ghosts: &'a [f32],
    pub direct: &'a [f32],
}

/// One batch's output: its drawn hosts' frames (FRAME_FLOATS each), whether any host is chosen
/// (its effect is to be stepped), and the drawn hosts' bodies' bounds.
#[derive(Default, Debug, Clone)]
pub struct BatchOut {
    pub frames: Vec<f32>,
    pub drawn: usize,
    pub live: bool,
    pub lo: [f32; 3],
    pub hi: [f32; 3],
}

#[derive(Default, Debug, Clone, Copy)]
pub struct Totals {
    /// Hosts whose body draws within reach (before the budget), chosen, and drawn (in view).
    pub in_reach: usize,
    pub chosen: usize,
    pub drawn: usize,
}

/// Every batch's hosts chosen, culled and placed (the module's doc). `layouts[i]` is a layout's
/// pages and its row width in texels; a ghost host names its layout by index (host[3]).
pub fn step(
    batches: &[BatchIn],
    bodies: &[f32],
    layouts: &[(Vec<&[f32]>, usize)],
    clock_ms: f32,
    reveal: &[f32; 4],
    cam: &Cam,
    budget: usize,
    threads: usize,
) -> (Vec<BatchOut>, Totals) {
    // (distance, batch, index, direct) of every host within reach.
    let mut cand: Vec<(f32, u32, u32, bool)> = Vec::new();
    for (bi, b) in batches.iter().enumerate() {
        for (hi, h) in b.ghosts.chunks_exact(HOST_FLOATS).enumerate() {
            let slot = (h[0] + 0.5) as usize;
            let Some(body) = bodies.get(slot * BODY_FLOATS..slot * BODY_FLOATS + BODY_FLOATS) else { continue };
            // The body the host was placed for (CrowdGpu's slot stamp, texel 4's w): a later body
            // in the same slot draws none of it (the review's F4).
            if (h[3] as u32) >> 4 != body[19] as u32 || !body_shown(body, clock_ms, reveal) {
                continue;
            }
            if let Some(d) = reach(cam, [body[3], body[7], body[11]]) {
                cand.push((d, bi as u32, hi as u32, false));
            }
        }
        for (hi, h) in b.direct.chunks_exact(DIRECT_FLOATS).enumerate() {
            if let Some(d) = reach(cam, [h[12], h[13], h[14]]) {
                cand.push((d, bi as u32, hi as u32, true));
            }
        }
    }
    let mut t = Totals { in_reach: cand.len(), ..Default::default() };
    if budget > 0 && cand.len() > budget {
        cand.select_nth_unstable_by(budget - 1, |a, b| a.0.total_cmp(&b.0));
        cand.truncate(budget);
    }
    t.chosen = cand.len();
    // A stable order (by batch and host) whatever the selection did; the
    // candidates were pushed in that order, so only a cut list is sorted.
    if budget > 0 && t.in_reach > budget {
        cand.sort_unstable_by_key(|c| (c.1, c.3, c.2));
    }
    // Each chosen host culled and placed: on `threads` threads for a long list
    // (OURS: 2,048 hosts and up; the scoped threads cost ~20 us each).
    let place = |c: &(f32, u32, u32, bool)| -> Option<(M34, [f32; 3])> {
        let (_, bi, hi, direct) = *c;
        let b = &batches[bi as usize];
        if direct {
            let h = &b.direct[hi as usize * DIRECT_FLOATS..(hi as usize + 1) * DIRECT_FLOATS];
            let at = [h[12], h[13], h[14]];
            return if cam.sees(at) { Some((rows(&h[0..12]), at)) } else { None };
        }
        let h = &b.ghosts[hi as usize * HOST_FLOATS..(hi as usize + 1) * HOST_FLOATS];
        let slot = (h[0] + 0.5) as usize;
        let body = &bodies[slot * BODY_FLOATS..slot * BODY_FLOATS + BODY_FLOATS];
        let at = [body[3], body[7], body[11]];
        if !cam.sees(at) {
            return None;
        }
        let li = ((h[3] as u32) & LAYOUT_MASK) as usize;
        layouts.get(li).and_then(|(pages, w)| ghost_frame(body, h, clock_ms, pages, *w)).map(|f| (f, at))
    };
    let placed: Vec<Option<(M34, [f32; 3])>> = if threads > 1 && cand.len() >= 2048 {
        let per = cand.len().div_ceil(threads);
        std::thread::scope(|sc| {
            let hs: Vec<_> = cand.chunks(per).map(|ch| sc.spawn(move || ch.iter().map(place).collect::<Vec<_>>())).collect();
            // A placement thread's panic goes on to the caller (the re-review's R3: dropping its
            // chunk would shift every later host's frame onto the wrong host).
            hs.into_iter()
                .flat_map(|h| match h.join() {
                    Ok(v) => v,
                    Err(e) => std::panic::resume_unwind(e),
                })
                .collect()
        })
    } else {
        cand.iter().map(place).collect()
    };
    let mut out: Vec<BatchOut> = (0..batches.len())
        .map(|_| BatchOut { lo: [f32::INFINITY; 3], hi: [f32::NEG_INFINITY; 3], ..Default::default() })
        .collect();
    for (c, p) in cand.iter().zip(placed.iter()) {
        let o = &mut out[c.1 as usize];
        o.live = true;
        let Some((f, at)) = p else { continue };
        for r in f.iter() {
            o.frames.extend_from_slice(r);
        }
        o.drawn += 1;
        for k in 0..3 {
            o.lo[k] = o.lo[k].min(at[k]);
            o.hi[k] = o.hi[k].max(at[k]);
        }
    }
    t.drawn = out.iter().map(|o| o.drawn).sum();
    (out, t)
}

fn reach(cam: &Cam, p: [f32; 3]) -> Option<f32> {
    let d = ((p[0] - cam.pos[0]).powi(2) + (p[1] - cam.pos[1]).powi(2) + (p[2] - cam.pos[2]).powi(2)).sqrt();
    if !d.is_finite() || d > cam.range || (cam.sight > 0.0 && d > cam.sight) {
        return None;
    }
    Some(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: M34 = [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0]];

    fn flat(m: &M34) -> Vec<f32> {
        m.iter().flat_map(|r| r.iter().copied()).collect()
    }

    fn body(at: [f32; 3], fade: f32) -> Vec<f32> {
        let mut b = vec![0.0; BODY_FLOATS];
        b[0] = 2.0; // a scale of 2 on x, y, z: det 8, cbrt 2
        b[5] = 2.0;
        b[10] = 2.0;
        b[3] = at[0];
        b[7] = at[1];
        b[11] = at[2];
        b[12] = 0.0;
        b[13] = 1.0;
        b[14] = 1000.0;
        b[17] = fade;
        b
    }

    fn host(slot: usize, scale: f32) -> Vec<f32> {
        let mut h = vec![slot as f32, 0.0, scale, 0.0];
        h.extend(flat(&ID));
        let mut pose = ID;
        pose[0][3] = 1.0; // the item bone one unit along x
        h.extend(flat(&pose));
        h
    }

    fn cam() -> Cam {
        // Looking down -z from the origin: world to view is the identity.
        Cam { pos: [0.0; 3], view: ID, sx: 1.0, sy: 1.0, ortho: false, range: 720.0, sight: 0.0, near: 30.0 }
    }

    #[test]
    fn a_frame_is_the_holders_composition() {
        let b = body([0.0, 0.0, -50.0], 0.0);
        let page = flat(&ID); // one bone, one row: identity
        let f = ghost_frame(&b, &host(0, 0.5), 0.0, &[&page], 3).unwrap();
        // G = body x bone x rest/chain = scale 2: cbrt(8) = 2, x row scale 0.5 -> 1; the origin is
        // the body's place plus the pose's 1 along x, scaled by 2.
        assert_eq!(f, [[1.0, 0.0, 0.0, 2.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, -50.0]]);
    }

    #[test]
    fn the_budget_takes_the_nearest_in_any_direction() {
        let mut bodies = Vec::new();
        for z in [-60.0f32, 70.0, -80.0, 90.0, -800.0] {
            bodies.extend(body([0.0, 0.0, z], 0.0));
        }
        let mut ghosts = Vec::new();
        for s in 0..5 {
            ghosts.extend(host(s, 1.0));
        }
        let page = flat(&ID);
        let layouts = vec![(vec![&page[..]], 3usize)];
        let b = [BatchIn { ghosts: &ghosts, direct: &[] }];
        let (o, t) = step(&b, &bodies, &layouts, 0.0, &[0.0; 4], &cam(), 0, 1);
        // 800 is past reach; 70 and 90 are behind the camera (in reach, chosen, not drawn).
        assert_eq!((t.in_reach, t.chosen, t.drawn), (4, 4, 2));
        assert!(o[0].live);
        let (_, t) = step(&b, &bodies, &layouts, 0.0, &[0.0; 4], &cam(), 2, 1);
        // The two nearest are -60 (ahead) and 70 (behind).
        assert_eq!((t.in_reach, t.chosen, t.drawn), (4, 2, 1));
    }

    #[test]
    fn a_held_or_leaving_body_draws_nothing() {
        let page = flat(&ID);
        let layouts = vec![(vec![&page[..]], 3usize)];
        let ghosts = host(0, 1.0);
        let b = [BatchIn { ghosts: &ghosts, direct: &[] }];
        for (fade, reveal, want) in [(-1.0f32, 0.0f32, 0usize), (4.0e6, 1.0e9, 0), (4.0e6, -100.0, 1), (1.0e6, 0.0, 1)] {
            let bodies = body([0.0, 0.0, -50.0], fade);
            let (_, t) = step(&b, &bodies, &layouts, 0.0, &[reveal; 4], &cam(), 0, 1);
            assert_eq!(t.drawn, want, "fade {fade} reveal {reveal}");
        }
    }

    #[test]
    fn a_later_body_in_the_slot_draws_no_old_host() {
        let page = flat(&ID);
        let layouts = vec![(vec![&page[..]], 3usize)];
        let mut ghosts = host(0, 1.0);
        ghosts[3] = 16.0 * 7.0; // stamped 7, layout 0
        let b = [BatchIn { ghosts: &ghosts, direct: &[] }];
        let mut bodies = body([0.0, 0.0, -50.0], 0.0);
        bodies[19] = 7.0;
        let (_, t) = step(&b, &bodies, &layouts, 0.0, &[0.0; 4], &cam(), 0, 1);
        assert_eq!(t.drawn, 1);
        bodies[19] = 8.0;
        let (_, t) = step(&b, &bodies, &layouts, 0.0, &[0.0; 4], &cam(), 0, 1);
        assert_eq!((t.in_reach, t.drawn), (0, 0));
    }

    #[test]
    fn a_direct_host_is_placed_as_given() {
        let mut d = flat(&ID);
        d[3] = 5.0;
        d.extend([5.0, 0.0, -40.0, 0.0]);
        let b = [BatchIn { ghosts: &[], direct: &d }];
        let (o, t) = step(&b, &[], &[], 0.0, &[0.0; 4], &cam(), 0, 1);
        assert_eq!(t.drawn, 1);
        assert_eq!(&o[0].frames[..4], &[1.0, 0.0, 0.0, 5.0]);
        assert_eq!(o[0].lo, [5.0, 0.0, -40.0]);
    }

    #[test]
    fn threads_place_what_one_thread_places() {
        let mut bodies = Vec::new();
        let mut ghosts = Vec::new();
        for s in 0..5000usize {
            let a = s as f32 * 0.37;
            bodies.extend(body([a.sin() * 300.0, 0.0, -50.0 - (s % 400) as f32], 0.0));
            ghosts.extend(host(s, 1.0 + (s % 3) as f32));
        }
        let page = flat(&ID);
        let layouts = vec![(vec![&page[..]], 3usize)];
        let b = [BatchIn { ghosts: &ghosts[..HOST_FLOATS * 2500], direct: &[] }, BatchIn { ghosts: &ghosts[HOST_FLOATS * 2500..], direct: &[] }];
        let (o1, t1) = step(&b, &bodies, &layouts, 0.0, &[0.0; 4], &cam(), 0, 1);
        let (o4, t4) = step(&b, &bodies, &layouts, 0.0, &[0.0; 4], &cam(), 0, 4);
        assert_eq!((t1.in_reach, t1.chosen, t1.drawn), (t4.in_reach, t4.chosen, t4.drawn));
        assert!(t1.drawn > 2048);
        for (a, b) in o1.iter().zip(o4.iter()) {
            assert_eq!(a.frames, b.frames);
            assert_eq!((a.lo, a.hi, a.drawn), (b.lo, b.hi, b.drawn));
        }
    }

    #[test]
    fn the_clip_row_follows_the_clock() {
        let mut b = body([0.0; 3], 0.0);
        b[12] = 10.0;
        b[13] = 4.0;
        b[14] = 4.0 * QUANTUM_MS;
        assert_eq!(clip_row(&b, 0.0), 10);
        assert_eq!(clip_row(&b, 2.0 * QUANTUM_MS), 12);
        assert_eq!(clip_row(&b, 5.0 * QUANTUM_MS), 11);
    }
}
