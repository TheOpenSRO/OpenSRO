//! What a natively simulated effect draws (round 763): its plate and mesh nodes' MultiMesh buffers,
//! and its Link nodes' chains, built from the particles as EfpEffect builds them in GDScript, so the
//! main thread only hands each buffer to the RenderingServer.
//!
//! - **The MultiMesh buffer** is Godot's layout for TRANSFORM_3D with colours and custom data
//!   (RenderingServer.multimesh_set_buffer): per instance the basis rows each followed by the
//!   origin's coordinate (12 floats), the colour (4) and the custom data (4). The values are
//!   EfpEffect._update_draws': a shared-turn node (use_shared_turn) puts `Basis.from_scale(scale)`
//!   and the position, the colour, and the shape's rotation as a quaternion (turn_custom); any
//!   other node `particle_transform` (the view basis x shape x scale, at the position), the colour
//!   and the UV rectangle. A node's instances are its particles in list order (the `by_tpl`
//!   grouping). Its instance count grows as GDScript grows it: to max(n, 2 x the old count) when n
//!   passes it.
//! - **The chains** are EfpLinks.gather_from's: from each emitter's oldest live particle (no link)
//!   along next_link, a point closer than EPS (READ, 1e-6) to the last kept one merged into it
//!   (LinkObj) or skipped (the pipes).

use super::efp_links;
use super::efp_sim::Sim;
use super::gdmath::{B3, V3};

/// Floats an instance takes in the buffer.
pub const STRIDE: usize = 20;
/// EfpLinks.EPS (READ: the float at 0x00e1b848).
pub const LINK_EPS: f64 = 1e-6;

pub const VIEW_NONE: u8 = 0;
pub const VIEW_BILLBOARD: u8 = 1;
pub const VIEW_YBILLBOARD: u8 = 2;
pub const VIEW_VBILLBOARD: u8 = 3;

/// One plate or mesh node EfpEffect draws (an entry of `_draws`).
#[derive(Clone, Debug)]
pub struct DrawNode {
    pub tpl: u32,
    pub view: u8,
    pub turn: bool,
    /// The MultiMesh's instance count, as GDScript would have set it.
    pub cap: usize,
}

/// One Link node (an entry of `_links`): its kind (0 LinkDPipe, 1 LinkPipe, 2 LinkObj, which
/// keeps a merged point's last values) and whether its pipes are shared-turn (built here; a pipe
/// drawn with the camera's side is built in GDScript from the chains).
#[derive(Clone, Debug)]
pub struct LinkNode {
    pub tpl: u32,
    pub kind: u8,
    pub turn: bool,
}

impl LinkNode {
    pub fn obj(&self) -> bool {
        self.kind == 2
    }
    /// Whether its strip is built natively (camera-free).
    pub fn native(&self) -> bool {
        self.kind == 2 || self.turn
    }
}

/// The chains of every Link node, flat: per chain its link node index and point count, then the
/// points (pos, colour, width = scale.x, y = the rotation's Y axis for LinkObj, else zero).
#[derive(Clone, Debug, Default)]
pub struct Chains {
    pub meta: Vec<i32>,
    pub pos: Vec<V3>,
    pub col: Vec<i64>,
    pub w: Vec<f32>,
    pub y: Vec<V3>,
}

#[derive(Clone, Debug, Default)]
pub struct Outputs {
    pub draws: Vec<DrawNode>,
    pub links: Vec<LinkNode>,
    /// Per draw node: cap x STRIDE floats, the first `counts[i]` instances filled.
    pub bufs: Vec<Vec<f32>>,
    pub counts: Vec<usize>,
    pub chains: Chains,
    /// Per Link node its strip, when built here (LinkNode::native).
    pub strips: Vec<efp_links::Out>,
    /// Built after the last step and not yet taken.
    pub fresh: bool,
}

/// EfpEffect.view_basis.
fn view_basis(p_rot: &B3, p_vel: V3, view: u8, cam: &B3) -> B3 {
    match view {
        VIEW_BILLBOARD => B3::from_columns(cam.column(0), cam.column(1), cam.column(2).neg()),
        VIEW_YBILLBOARD => B3::from_columns(cam.column(0), V3(0.0, 1.0, 0.0), cam.column(2).neg()),
        VIEW_VBILLBOARD => {
            if (p_vel.length_squared() as f64) < 1e-12 {
                return super::gdmath::IDENTITY;
            }
            let y = p_vel.normalized();
            let zc = y.cross(V3(0.0, 1.0, 0.0));
            if (zc.length_squared() as f64) < 1e-12 {
                return super::gdmath::IDENTITY;
            }
            let zn = zc.normalized();
            B3::from_columns(y.cross(zn), y, zn)
        }
        _ => *p_rot,
    }
}

#[inline]
fn put_transform(o: &mut [f32], b: &B3, at: V3) {
    o[0] = b.r[0][0];
    o[1] = b.r[0][1];
    o[2] = b.r[0][2];
    o[3] = at.0;
    o[4] = b.r[1][0];
    o[5] = b.r[1][1];
    o[6] = b.r[1][2];
    o[7] = at.1;
    o[8] = b.r[2][0];
    o[9] = b.r[2][1];
    o[10] = b.r[2][2];
    o[11] = at.2;
}

/// EfpSim.color_of -> EfpReader.d3dcolor -> Color8: each byte / 255 in f32 (Color::from_rgba8).
#[inline]
pub fn color_floats(c: i64) -> [f32; 4] {
    [
        ((c >> 16) & 0xFF) as f32 / 255.0f32,
        ((c >> 8) & 0xFF) as f32 / 255.0f32,
        (c & 0xFF) as f32 / 255.0f32,
        ((c >> 24) & 0xFF) as f32 / 255.0f32,
    ]
}

impl Outputs {
    /// EfpEffect._update_draws for every draw node, with `cam` the camera's rotation in the
    /// effect's space (cam_rot).
    pub fn build_draws(&mut self, sim: &Sim, cam: &B3) {
        let ntpl = sim.tmpl.tpls.len();
        let mut node_of = vec![usize::MAX; ntpl];
        for (i, d) in self.draws.iter().enumerate() {
            if (d.tpl as usize) < ntpl && node_of[d.tpl as usize] == usize::MAX {
                node_of[d.tpl as usize] = i;
            }
        }
        let nd = self.draws.len();
        let mut counts = vec![0usize; nd];
        for p in sim.particles() {
            let k = node_of.get(p.tpl as usize).copied().unwrap_or(usize::MAX);
            if k != usize::MAX {
                counts[k] += 1;
            }
        }
        self.bufs.resize_with(nd, Vec::new);
        for (i, d) in self.draws.iter_mut().enumerate() {
            let n = counts[i];
            if n > d.cap {
                d.cap = n.max(d.cap * 2);
            }
            let want = d.cap * STRIDE;
            let b = &mut self.bufs[i];
            if b.len() != want {
                b.resize(want, 0.0);
            }
        }
        let mut fill = vec![0usize; nd];
        for p in sim.particles() {
            let k = node_of.get(p.tpl as usize).copied().unwrap_or(usize::MAX);
            if k == usize::MAX {
                continue;
            }
            let d = &self.draws[k];
            let at = fill[k];
            fill[k] += 1;
            let o = &mut self.bufs[k][at * STRIDE..(at + 1) * STRIDE];
            if d.turn {
                put_transform(o, &B3::from_scale(p.scale), p.pos);
                o[12..16].copy_from_slice(&color_floats(p.color));
                let q = p.shape.orthonormalized().rotation_quaternion();
                o[16..20].copy_from_slice(&q);
            } else {
                let v = view_basis(&p.rot, p.vel, d.view, cam);
                let m = v.mul(&p.shape).mul(&B3::from_scale(p.scale));
                put_transform(o, &m, p.pos);
                o[12..16].copy_from_slice(&color_floats(p.color));
                o[16..20].copy_from_slice(&p.uv);
            }
        }
        self.counts = counts;
    }

    /// EfpEffect._update_links' walk: every Link node's chains, in the order of their heads.
    pub fn build_chains(&mut self, sim: &Sim) {
        let c = &mut self.chains;
        c.meta.clear();
        c.pos.clear();
        c.col.clear();
        c.w.clear();
        c.y.clear();
        if self.links.is_empty() {
            return;
        }
        self.strips.resize_with(self.links.len(), Default::default);
        for (o, l) in self.strips.iter_mut().zip(&self.links) {
            o.turn = l.turn && l.kind != 2;
            o.clear();
        }
        let mut scratch = efp_links::Buf::default();
        let ntpl = sim.tmpl.tpls.len();
        let mut link_of = vec![usize::MAX; ntpl];
        for (i, l) in self.links.iter().enumerate() {
            if (l.tpl as usize) < ntpl && link_of[l.tpl as usize] == usize::MAX {
                link_of[l.tpl as usize] = i;
            }
        }
        for &head in sim.list_slots() {
            let hp = sim.particle(head);
            if hp.link != u32::MAX {
                continue;
            }
            let li = link_of.get(hp.tpl as usize).copied().unwrap_or(usize::MAX);
            if li == usize::MAX {
                continue;
            }
            let obj = self.links[li].obj();
            let start = c.pos.len();
            let mut n = 0usize;
            let mut last = V3(0.0, 0.0, 0.0);
            let mut s = head;
            while s != u32::MAX {
                let p = sim.particle(s);
                let at = p.pos;
                if n > 0 {
                    let d = at.sub(last);
                    if (d.0.abs() as f64) <= LINK_EPS && (d.1.abs() as f64) <= LINK_EPS && (d.2.abs() as f64) <= LINK_EPS {
                        if obj {
                            let k = start + n - 1;
                            c.pos[k] = at;
                            c.col[k] = p.color;
                            c.w[k] = p.scale.0;
                            c.y[k] = p.rot.column(1);
                        }
                        s = p.next_link;
                        continue;
                    }
                }
                c.pos.push(at);
                c.col.push(p.color);
                c.w.push(p.scale.0);
                c.y.push(if obj { p.rot.column(1) } else { V3(0.0, 0.0, 0.0) });
                n += 1;
                last = at;
                s = p.next_link;
            }
            c.meta.push(li as i32);
            c.meta.push(n as i32);
            if self.links[li].native() {
                // EfpEffect._link_geometry on this chain.
                let b = efp_links::Buf {
                    pos: c.pos[start..start + n].to_vec(),
                    col: c.col[start..start + n].to_vec(),
                    w: c.w[start..start + n].to_vec(),
                    y: c.y[start..start + n].to_vec(),
                };
                let out = &mut self.strips[li];
                match self.links[li].kind {
                    2 => efp_links::obj_ribbon(&b, out),
                    1 => {
                        efp_links::spline(&b, &mut scratch);
                        efp_links::pipe_turn(&scratch, out);
                    }
                    _ => efp_links::pipe_turn(&b, out),
                }
            }
        }
    }

    /// Both, after a step.
    pub fn build(&mut self, sim: &Sim, cam: &B3) {
        if !self.draws.is_empty() {
            self.build_draws(sim, cam);
        }
        if !self.links.is_empty() {
            self.build_chains(sim);
        }
        self.fresh = true;
    }
}
