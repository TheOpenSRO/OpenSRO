//! The per-vertex cloth of a mesh (round 794): retail's Dynamic Animation, READ from
//! sro_client.exe (docs/protocol/CLOTH.md has every address). No Godot types; the GDScript twin is
//! client/scripts/assets/cloth_sim.gd, and the two give the same bytes (cloth_test.gd).
//!
//! - **The data.** A mesh is cloth when its hdr[2] (per vertex: an amount, and pinned) and hdr[3]
//!   (links: two vertices and a rest length, an order over the links, a 36-byte parameter block)
//!   are both non-empty (`ResObject::FUN_00bce1a0`). The block: a use-the-file's-wind word, the
//!   wind vector, gravity, gravity gain per amount, gust gain per amount, the velocity kept, the
//!   gust divisor.
//! - **The skin** (`FUN_00c52270`): near (LOD 0) only the pinned vertices are skinned, their
//!   position into the particle and the vertex buffer, their normal into the buffer; far, every
//!   vertex is. Two weighted bones there; here the mesh's own influences.
//! - **The step** (`CCompChar::FUN_00c0d010`, one per 50 ms): position Verlet for every vertex
//!   not pinned, then up to 7 passes of stretch-only links in the file's order.
//! - **The copy out** (`FUN_00c0d610`): every particle's position into the buffer after the
//!   steps. The normals of free vertices are never written there: they keep the last skin's (the
//!   bind pose's until the first far frame).

use std::sync::atomic::{AtomicU32, Ordering};

/// The process's one `rand()` state (MSVC's, `0xb44c36`): retail rolls every gust on the C
/// library's global generator.
static RAND: AtomicU32 = AtomicU32::new(1);

/// MSVC `srand`.
pub fn seed_rand(seed: u32) {
    RAND.store(seed, Ordering::Relaxed);
}

pub fn rand_state() -> u32 {
    RAND.load(Ordering::Relaxed)
}

/// MSVC `rand`: `holdrand = holdrand * 214013 + 2531011`, then bits 16..30.
pub fn rand() -> i32 {
    let mut s = RAND.load(Ordering::Relaxed);
    s = s.wrapping_mul(214013).wrapping_add(2531011);
    RAND.store(s, Ordering::Relaxed);
    ((s >> 16) & 0x7fff) as i32
}

/// The parameter block (hdr[3]'s 36-byte tail, mesh +0x100..+0x123).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Params {
    /// +0x00: non-zero, the gust blows along `wind`; zero, along the character's (FUN_00c0d720).
    pub file_wind: bool,
    /// +0x04..+0x0c.
    pub wind: [f32; 3],
    /// +0x10: gravity, times -5.0 (`0xde4fa0`) on Y.
    pub gravity: f32,
    /// +0x14: gravity's gain per amount, `(k * a + 1)`.
    pub gravity_gain: f32,
    /// +0x18: the gust's gain per amount.
    pub gust_gain: f32,
    /// +0x1c: the velocity a step keeps.
    pub retention: f32,
    /// +0x20: a gust when `rand() % n == 0`.
    pub gust_div: i32,
}

impl Params {
    /// From the nine values ClothSim passes: flag, wind xyz, gravity, its gain, the gust's gain,
    /// retention, divisor.
    pub fn from_slice(f: &[f32]) -> Option<Params> {
        if f.len() < 9 {
            return None;
        }
        Some(Params {
            file_wind: f[0] != 0.0,
            wind: [f[1], f[2], f[3]],
            gravity: f[4],
            gravity_gain: f[5],
            gust_gain: f[6],
            retention: f[7],
            gust_div: f[8] as i32,
        })
    }
}

/// p's shaping at the top of FUN_00c0d010: 0.2 (`0xe1b8d0`), 0.2f (`0xda95f8`), 900 (`0xe0c720`).
pub fn shape_p(p: f32) -> f32 {
    if p > 0.0 {
        if p >= 0.2 {
            if p < 1.0 {
                p * 900.0
            } else {
                900.0
            }
        } else {
            0.2 * 900.0
        }
    } else {
        p
    }
}

pub struct Cloth {
    pub amount: Vec<f32>,
    pub pinned: Vec<bool>,
    /// v0, v1, rest.
    pub links: Vec<(usize, usize, f32)>,
    pub order: Vec<usize>,
    pub params: Params,
    pub cur: Vec<[f32; 3]>,
    pub prev: Vec<[f32; 3]>,
    bind_pos: Vec<[f32; 3]>,
    bind_nrm: Vec<[f32; 3]>,
    /// The buffer's normals: the last skin's, the bind pose's at first.
    pub nrm: Vec<[f32; 3]>,
    bones: Vec<i32>,
    weights: Vec<f32>,
    per: usize,
    /// Each vertex's tangent word (Godot's normal/tangent block keeps it beside the normal).
    tangent: Vec<[u8; 4]>,
}

fn add(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

impl Cloth {
    /// None when the data is not a cloth this step can run: the counts disagree, an index is out
    /// of range, a divisor is not positive (retail's `idiv` would fault; MEASURED: none in the
    /// 801 real meshes), or a link joins two pinned vertices (a division by zero there; none).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        amount: &[f32],
        pinned: &[u8],
        links: &[i32],
        rest: &[f32],
        order: &[i32],
        params: Params,
        positions: &[[f32; 3]],
        normals: &[[f32; 3]],
        bones: &[i32],
        weights: &[f32],
        vertex_data: &[u8],
    ) -> Result<Cloth, String> {
        let n = positions.len();
        if n == 0 || amount.len() != n || pinned.len() != n || normals.len() != n {
            return Err("vertex counts disagree".into());
        }
        if rest.is_empty() || links.len() != rest.len() * 2 {
            return Err("link counts disagree".into());
        }
        if params.gust_div <= 0 {
            return Err(format!("gust divisor {}", params.gust_div));
        }
        let mut l = Vec::with_capacity(rest.len());
        for (i, &r) in rest.iter().enumerate() {
            let a = links[i * 2];
            let b = links[i * 2 + 1];
            if a < 0 || b < 0 || a as usize >= n || b as usize >= n {
                return Err(format!("link {i} out of range"));
            }
            if amount[a as usize] + amount[b as usize] == 0.0 {
                return Err(format!("link {i} joins two still vertices"));
            }
            l.push((a as usize, b as usize, r));
        }
        let mut o = Vec::with_capacity(order.len());
        for &k in order {
            if k < 0 || k as usize >= l.len() {
                return Err("order out of range".into());
            }
            o.push(k as usize);
        }
        let per = if bones.is_empty() { 0 } else { bones.len() / n };
        if per > 0 && (bones.len() != per * n || weights.len() != per * n) {
            return Err("skin counts disagree".into());
        }
        let mut tangent = vec![[0u8; 4]; n];
        if vertex_data.len() >= n * 20 {
            for (i, t) in tangent.iter_mut().enumerate() {
                let at = n * 12 + i * 8 + 4;
                t.copy_from_slice(&vertex_data[at..at + 4]);
            }
        }
        Ok(Cloth {
            amount: amount.to_vec(),
            pinned: pinned.iter().map(|&p| p != 0).collect(),
            links: l,
            order: o,
            params,
            cur: positions.to_vec(),
            prev: positions.to_vec(),
            bind_pos: positions.to_vec(),
            bind_nrm: normals.to_vec(),
            nrm: normals.to_vec(),
            bones: bones.to_vec(),
            weights: weights.to_vec(),
            per,
            tangent,
        })
    }

    /// Back to the bind pose (the particles' init, `FUN_00c1af60`: the position twice).
    pub fn reset(&mut self) {
        self.cur.copy_from_slice(&self.bind_pos);
        self.prev.copy_from_slice(&self.bind_pos);
        self.nrm.copy_from_slice(&self.bind_nrm);
    }

    /// FUN_00c52270. `mats`: 12 floats a bind (Godot's basis columns x, y, z, then the origin) --
    /// the bone's pose times the bind pose, in the mesh's space. Near: only the pinned vertices.
    pub fn skin(&mut self, mats: &[f32], near: bool) {
        if self.per == 0 {
            return;
        }
        let nb = mats.len() / 12;
        for i in 0..self.cur.len() {
            if near && !self.pinned[i] {
                continue;
            }
            let v = self.bind_pos[i];
            let nv = self.bind_nrm[i];
            let mut p = [0.0f32; 3];
            let mut q = [0.0f32; 3];
            let mut ws = 0.0f32;
            for k in 0..self.per {
                let w = self.weights[i * self.per + k];
                let b = self.bones[i * self.per + k];
                if w <= 0.0 || b < 0 || b as usize >= nb {
                    continue;
                }
                let m = &mats[b as usize * 12..b as usize * 12 + 12];
                for c in 0..3 {
                    p[c] += w * (m[c] * v[0] + m[3 + c] * v[1] + m[6 + c] * v[2] + m[9 + c]);
                    q[c] += w * (m[c] * nv[0] + m[3 + c] * nv[1] + m[6 + c] * nv[2]);
                }
                ws += w;
            }
            if ws <= 0.0 {
                continue;
            }
            self.cur[i] = p;
            self.nrm[i] = q;
        }
    }

    /// FUN_00c0d610's loop: `steps` steps of FUN_00c0d010.
    pub fn step(&mut self, steps: i32, wind: [f32; 3], p: f32) {
        for _ in 0..steps.max(0) {
            self.step_once(wind, p);
        }
    }

    /// CCompChar::FUN_00c0d010.
    pub fn step_once(&mut self, wind: [f32; 3], p: f32) {
        let p = shape_p(p);
        let s = self.params;
        for i in 0..self.cur.len() {
            if self.pinned[i] {
                continue;
            }
            let a = self.amount[i];
            let mut acc = [0.0f32, s.gravity * -5.0 * (s.gravity_gain * a + 1.0), 0.0];
            if rand() % s.gust_div == 0 {
                let f = p + 100.0;
                let g = s.gust_gain * a + 1.0;
                acc[0] += g * f * wind[0];
                acc[1] += wind[1] * f * g;
                acc[2] += g * f * wind[2];
            }
            let old = self.prev[i];
            let c = self.cur[i];
            self.prev[i] = c;
            let r = s.retention;
            self.cur[i] = [
                c[0] + r * (c[0] - old[0]) + acc[0] * 0.0004,
                (c[1] - old[1]) * r + acc[1] * 0.0004 + c[1],
                r * (c[2] - old[2]) + 0.0004 * acc[2] + c[2],
            ];
        }
        let mut pass = 0;
        loop {
            let mut clean = true;
            for &k in &self.order {
                let (v0, v1, rest) = self.links[k];
                let d = sub(self.cur[v1], self.cur[v0]);
                let len = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
                let err = len - rest;
                if err >= 0.01 {
                    clean = false;
                    let a0 = self.amount[v0];
                    let a1 = self.amount[v1];
                    let sum = a1 + a0;
                    let f0 = a0 / sum;
                    let f1 = a1 / sum;
                    let c = [(d[0] / len) * err, (d[1] / len) * err, err * (d[2] / len)];
                    self.cur[v0] = add(self.cur[v0], [f0 * c[0], c[1] * f0, c[2] * f0]);
                    self.cur[v1] = sub(self.cur[v1], [f1 * c[0], c[1] * f1, c[2] * f1]);
                }
            }
            if clean {
                break;
            }
            pass += 1;
            if pass >= 7 {
                break;
            }
        }
    }

    /// Godot's vertex stream for an uncompressed surface of positions and normals (4.7, MEASURED
    /// on the box: every position, 12 bytes, then per vertex the normal and the tangent, two
    /// octahedral u16 pairs).
    pub fn vertex_data(&self) -> Vec<u8> {
        let n = self.cur.len();
        let mut out = Vec::with_capacity(n * 20);
        for p in &self.cur {
            for c in p {
                out.extend_from_slice(&c.to_le_bytes());
            }
        }
        for (i, q) in self.nrm.iter().enumerate() {
            let (x, y) = octahedral_u16(*q);
            out.extend_from_slice(&x.to_le_bytes());
            out.extend_from_slice(&y.to_le_bytes());
            out.extend_from_slice(&self.tangent[i]);
        }
        out
    }

    /// The particles' box (min, max).
    pub fn bounds(&self) -> ([f32; 3], [f32; 3]) {
        let mut lo = [f32::INFINITY; 3];
        let mut hi = [f32::NEG_INFINITY; 3];
        for p in &self.cur {
            for c in 0..3 {
                lo[c] = lo[c].min(p[c]);
                hi[c] = hi[c].max(p[c]);
            }
        }
        (lo, hi)
    }
}

/// Godot's `Vector3::octahedron_encode` (the vector normalised first) and the surface's
/// `(uint16_t)CLAMP(x * 65535, 0, 65535)` (MEASURED on 4.7.2: (0.6, 0, -0.8) -> 65535, 51491).
pub fn octahedral_u16(v: [f32; 3]) -> (u16, u16) {
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    let n = if len > 0.0 { [v[0] / len, v[1] / len, v[2] / len] } else { [0.0, 0.0, 1.0] };
    let l1 = n[0].abs() + n[1].abs() + n[2].abs();
    let mut n = [n[0] / l1, n[1] / l1, n[2] / l1];
    let mut o = [0.0f32; 2];
    if n[2] >= 0.0 {
        o[0] = n[0];
        o[1] = n[1];
    } else {
        o[0] = (1.0 - n[1].abs()) * if n[0] >= 0.0 { 1.0 } else { -1.0 };
        o[1] = (1.0 - n[0].abs()) * if n[1] >= 0.0 { 1.0 } else { -1.0 };
    }
    n[0] = o[0] * 0.5 + 0.5;
    n[1] = o[1] * 0.5 + 0.5;
    ((n[0] * 65535.0).clamp(0.0, 65535.0) as u16, (n[1] * 65535.0).clamp(0.0, 65535.0) as u16)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// The generator is the process's one, as retail's is: the tests that roll it take turns.
    static ROLLS: Mutex<()> = Mutex::new(());

    fn params() -> Params {
        Params { file_wind: true, wind: [0.0, 0.0, 1.0], gravity: 9.8, gravity_gain: 1.0, gust_gain: 0.0, retention: 0.95, gust_div: 2 }
    }

    /// A pinned top and a free bottom, 1 apart.
    fn rope() -> Cloth {
        Cloth::new(
            &[0.0, 0.5],
            &[1, 0],
            &[0, 1],
            &[1.0],
            &[0],
            params(),
            &[[0.0, 1.0, 0.0], [0.0, 0.0, 0.0]],
            &[[0.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
            &[],
            &[],
            &[],
        )
        .unwrap()
    }

    #[test]
    fn rand_is_msvc() {
        let _turn = ROLLS.lock().unwrap_or_else(|e| e.into_inner());
        seed_rand(1);
        assert_eq!([rand(), rand(), rand()], [41, 18467, 6334]);
    }

    #[test]
    fn p_shaping() {
        assert_eq!(shape_p(0.0), 0.0);
        assert_eq!(shape_p(-3.0), -3.0);
        assert_eq!(shape_p(0.1), 0.2f32 * 900.0);
        assert_eq!(shape_p(0.5), 450.0);
        assert_eq!(shape_p(4.0), 900.0);
    }

    #[test]
    fn the_free_end_falls_and_the_link_holds_it() {
        let _turn = ROLLS.lock().unwrap_or_else(|e| e.into_inner());
        let mut c = rope();
        seed_rand(7);
        c.step(40, [0.0, 0.0, 0.0], 0.0);
        // Gravity pulls it away from the top; the link (stretch only) keeps it within 1.01.
        let d = sub(c.cur[1], c.cur[0]);
        let len = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
        assert!(len <= 1.0 + 0.0101, "{len}");
        assert_eq!(c.cur[0], [0.0, 1.0, 0.0], "a pinned vertex never moves in a step");
    }

    #[test]
    fn one_step_is_retails_arithmetic() {
        let _turn = ROLLS.lock().unwrap_or_else(|e| e.into_inner());
        let mut c = rope();
        // Slack (rest 2 against a gap of 1), so the link does not move it back.
        c.links[0].2 = 2.0;
        // The first roll after srand(1) is 41: 41 % 2 = 1, no gust.
        seed_rand(1);
        c.step_once([0.0, 0.0, 1.0], 0.0);
        let ay = 9.8f32 * -5.0 * (1.0 * 0.5 + 1.0);
        assert_eq!(c.cur[1], [0.0, ay * 0.0004, 0.0]);
        assert_eq!(c.prev[1], [0.0, 0.0, 0.0]);
    }

    #[test]
    fn a_link_is_only_ever_pulled_in() {
        let _turn = ROLLS.lock().unwrap_or_else(|e| e.into_inner());
        let mut c = rope();
        c.cur[1] = [0.0, 0.9, 0.0]; // closer than its rest: left alone
        c.prev[1] = c.cur[1];
        c.params.gravity = 0.0;
        seed_rand(1);
        c.step_once([0.0, 0.0, 0.0], 0.0);
        assert_eq!(c.cur[1], [0.0, 0.9, 0.0]);
    }

    #[test]
    fn near_skins_only_the_pinned() {
        let mut c = Cloth::new(
            &[0.0, 0.5],
            &[1, 0],
            &[0, 1],
            &[1.0],
            &[0],
            params(),
            &[[0.0, 1.0, 0.0], [0.0, 0.0, 0.0]],
            &[[0.0, 0.0, 1.0], [0.0, 0.0, 1.0]],
            &[0, 0],
            &[1.0, 1.0],
            &[],
        )
        .unwrap();
        // A bone moved up by 2.
        let m = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 2.0, 0.0];
        c.skin(&m, true);
        assert_eq!(c.cur, vec![[0.0, 3.0, 0.0], [0.0, 0.0, 0.0]]);
        c.skin(&m, false);
        assert_eq!(c.cur[1], [0.0, 2.0, 0.0]);
    }

    #[test]
    fn octahedral_matches_godot() {
        assert_eq!(octahedral_u16([0.0, 1.0, 0.0]), (32767, 65535));
        assert_eq!(octahedral_u16([0.6, 0.0, -0.8]), (65535, 51491));
        assert_eq!(octahedral_u16([-0.267261, 0.534522, 0.801784]), (27306, 43689));
    }

    #[test]
    fn refuses_what_would_fault() {
        let mut p = params();
        p.gust_div = 0;
        assert!(Cloth::new(&[0.0, 0.5], &[1, 0], &[0, 1], &[1.0], &[0], p, &[[0.0; 3]; 2], &[[0.0; 3]; 2], &[], &[], &[]).is_err());
        assert!(Cloth::new(&[0.0, 0.0], &[1, 1], &[0, 1], &[1.0], &[0], params(), &[[0.0; 3]; 2], &[[0.0; 3]; 2], &[], &[], &[]).is_err());
    }
}
