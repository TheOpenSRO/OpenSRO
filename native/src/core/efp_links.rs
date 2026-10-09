//! The Link render modes' strips (round 763): EfpLinks (client/scripts/efp/efp_links.gd) ported
//! for natively simulated effects, so a master's LinkPipe / LinkDPipe / LinkObj geometry is built
//! on the thread that stepped it. The rules, their READ labels and addresses are efp_links.gd's
//! header; this follows its code operation for operation (f32 where it stores in a Vector3 /
//! Vector2 / Color / packed float, f64 where it computes in a GDScript float), so the strips are
//! the GDScript's, bit for bit (efp_native_test, efp_native_parity.gd).
//!
//! Only the camera-free strips are built here: LinkObj, and the pipes of a shared-turn effect
//! (`pipe_turn`, whose side the shader builds per holder). A pipe drawn with the camera's side
//! (`pipe_ribbon`) stays GDScript, from the chains (efp_out.rs).

use super::gdmath::V3;

/// EfpLinks.T_STEP (READ: the double at 0x00e0ec60).
pub const T_STEP: f64 = 0.3333333432674408;
const SAMPLES: usize = 3;

/// EfpLinks.bspline: the uniform cubic B-spline weights at t.
fn bspline(t: f64) -> [f64; 4] {
    let t2 = t * t;
    let t3 = t2 * t;
    let u = 1.0 - t;
    [u * u * u / 6.0, (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0, (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0, t3 / 6.0]
}

/// EfpLinks._w: the weights at t = 0, T_STEP, T_STEP + T_STEP.
fn weights() -> [f64; 12] {
    let mut out = [0.0; 12];
    let mut t = 0.0;
    for k in 0..SAMPLES {
        out[4 * k..4 * k + 4].copy_from_slice(&bspline(t));
        t += T_STEP;
    }
    out
}

/// EfpLinks._lerp4: a D3DCOLOR lerped byte by byte, rounded half to even.
fn lerp4(a: i64, b: i64, t: f64) -> i64 {
    let s = 1.0 - t;
    let byte = |sh: i64| {
        let x = s * ((a >> sh) & 0xFF) as f64 + t * ((b >> sh) & 0xFF) as f64;
        let mut r = (x + 0.5) as i64;
        if r & 1 != 0 && r as f64 - x == 0.5 {
            r -= 1;
        }
        r
    };
    let mut out = byte(0);
    out |= byte(8) << 8;
    out |= byte(16) << 16;
    out | (byte(24) << 24)
}

/// EfpLinks._color / Out.pair's colour: each byte / 255.0 in a GDScript float, then the Color's f32.
fn color(c: i64) -> [f32; 4] {
    [
        (((c >> 16) & 0xFF) as f64 / 255.0) as f32,
        (((c >> 8) & 0xFF) as f64 / 255.0) as f32,
        ((c & 0xFF) as f64 / 255.0) as f32,
        (((c >> 24) & 0xFF) as f64 / 255.0) as f32,
    ]
}

/// `Vector3 * float`: the float narrowed to real_t first.
#[inline]
fn sc(v: V3, w: f64) -> V3 {
    v.scale(w as f32)
}

/// A chain's points (EfpLinks.Buf).
#[derive(Clone, Debug, Default)]
pub struct Buf {
    pub pos: Vec<V3>,
    pub col: Vec<i64>,
    pub w: Vec<f32>,
    pub y: Vec<V3>,
}

impl Buf {
    pub fn n(&self) -> usize {
        self.pos.len()
    }
}

/// One node's strip (EfpLinks.Out), its arrays exactly as long as they are drawn.
#[derive(Clone, Debug, Default)]
pub struct Out {
    pub turn: bool,
    pub verts: Vec<V3>,
    pub colors: Vec<[f32; 4]>,
    pub uvs: Vec<[f32; 2]>,
    pub c0: Vec<f32>,
    pub c1: Vec<f32>,
    pre: usize,
    prefix: usize,
    stitch: bool,
}

impl Out {
    pub fn clear(&mut self) {
        self.verts.clear();
        self.colors.clear();
        self.uvs.clear();
        self.c0.clear();
        self.c1.clear();
    }

    pub fn nv(&self) -> usize {
        self.verts.len()
    }

    fn grow(&mut self, k: usize) {
        for _ in 0..k {
            self.verts.push(V3(0.0, 0.0, 0.0));
            self.colors.push([0.0; 4]);
            self.uvs.push([0.0; 2]);
            if self.turn {
                self.c0.extend_from_slice(&[0.0; 4]);
                self.c1.extend_from_slice(&[0.0; 4]);
            }
        }
    }

    /// Out.begin_strip: room for the stitching vertices.
    fn begin_strip(&mut self) {
        let nv = self.nv();
        self.stitch = nv > 0;
        self.prefix = if self.stitch { 1 } else { 0 } + 1;
        if (nv + self.prefix) % 2 == 0 {
            self.prefix += 1;
        }
        self.pre = nv;
        self.grow(self.prefix);
    }

    fn copy_vertex(&mut self, from: usize, to: usize) {
        self.verts[to] = self.verts[from];
        self.colors[to] = self.colors[from];
        self.uvs[to] = self.uvs[from];
        if self.turn {
            for k in 0..4 {
                self.c0[4 * to + k] = self.c0[4 * from + k];
                self.c1[4 * to + k] = self.c1[4 * from + k];
            }
        }
    }

    /// Out.end_strip: the previous strip's last vertex once, then this strip's first.
    fn end_strip(&mut self) {
        let mut at = self.pre;
        if self.stitch {
            self.copy_vertex(at - 1, at);
            at += 1;
        }
        let first = self.pre + self.prefix;
        while at < first {
            self.copy_vertex(first, at);
            at += 1;
        }
    }

    /// Out.pair.
    fn pair(&mut self, a: V3, b: V3, c: i64, u: f64) {
        let col = color(c);
        let u = u as f32;
        self.verts.push(a);
        self.verts.push(b);
        self.colors.push(col);
        self.colors.push(col);
        self.uvs.push([u, 0.0]);
        self.uvs.push([u, 1.0]);
        if self.turn {
            self.c0.extend_from_slice(&[0.0; 8]);
            self.c1.extend_from_slice(&[0.0; 8]);
        }
    }
}

/// EfpLinks.spline: LinkPipe's B-spline through `src`. Empty below 2 points.
pub fn spline(src: &Buf, dst: &mut Buf) {
    dst.pos.clear();
    dst.col.clear();
    dst.w.clear();
    dst.y.clear();
    let m = src.n();
    if m < 2 {
        return;
    }
    let w = weights();
    let (t1, t2) = (T_STEP, T_STEP + T_STEP);
    for i in 0..m - 1 {
        let p0 = src.pos[if i > 0 { i - 1 } else { 0 }];
        let p1 = src.pos[i];
        let p2 = src.pos[i + 1];
        let p3 = src.pos[if i + 2 < m { i + 2 } else { m - 1 }];
        for k in 0..SAMPLES {
            let o = 4 * k;
            dst.pos.push(sc(p0, w[o]).add(sc(p1, w[o + 1])).add(sc(p2, w[o + 2])).add(sc(p3, w[o + 3])));
        }
        let (ca, cb) = (src.col[i], src.col[i + 1]);
        dst.col.push(ca);
        if ca == cb {
            dst.col.push(ca);
            dst.col.push(ca);
        } else {
            dst.col.push(lerp4(ca, cb, t1));
            dst.col.push(lerp4(ca, cb, t2));
        }
        let wa = src.w[i] as f64;
        let dw = (src.w[i + 1] as f64 - wa) / 3.0;
        dst.w.push(wa as f32);
        dst.w.push((wa + dw) as f32);
        dst.w.push((wa + dw * 2.0) as f32);
    }
    dst.pos.push(src.pos[m - 1]);
    dst.col.push(src.col[m - 1]);
    dst.w.push(src.w[m - 1]);
    dst.y.resize(dst.pos.len(), V3(0.0, 0.0, 0.0));
}

/// EfpLinks.pipe_turn: each point twice, its neighbours and signed width in the custom channels.
pub fn pipe_turn(b: &Buf, out: &mut Out) {
    let n = b.n();
    if n < 2 {
        return;
    }
    out.begin_strip();
    let inv = 1.0 / (n - 1) as f64;
    let last = n - 1;
    for i in 0..n {
        let p = b.pos[i];
        let pa = b.pos[if i > 0 { i - 1 } else { 0 }];
        let pb = b.pos[if i < last { i + 1 } else { last }];
        let col = color(b.col[i]);
        let u = if i == 0 {
            0.0
        } else if i == last {
            1.0
        } else {
            i as f64 * inv
        };
        for k in 0..2 {
            out.verts.push(p);
            out.colors.push(col);
            out.uvs.push([u as f32, k as f32]);
            out.c0.extend_from_slice(&[pa.0, pa.1, pa.2, if k == 0 { b.w[i] } else { -b.w[i] }]);
            out.c1.extend_from_slice(&[pb.0, pb.1, pb.2, 0.0]);
        }
    }
    out.end_strip();
}

/// EfpLinks.obj_ribbon: LinkObj's strip from the taken particles (with their Y axes).
pub fn obj_ribbon(b: &Buf, out: &mut Out) {
    let k = b.n();
    if k < 2 {
        return;
    }
    let samples = 3 * (k - 2);
    out.begin_strip();
    let w = weights();
    let mut ea = Vec::with_capacity(k);
    let mut eb = Vec::with_capacity(k);
    for i in 0..k {
        let off = sc(b.y[i], b.w[i] as f64);
        ea.push(b.pos[i].add(off));
        eb.push(b.pos[i].sub(off));
    }
    let mut u = 1.0f64;
    let du = if samples > 0 { 2.0 / (samples * 2) as f64 } else { 0.0 };
    for j in 0..k - 2 {
        let i0 = if j > 0 { j - 1 } else { 0 };
        let (a0, a1, a2, a3) = (ea[i0], ea[j], ea[j + 1], ea[j + 2]);
        let (e0, e1, e2, e3) = (eb[i0], eb[j], eb[j + 1], eb[j + 2]);
        let (ca, cb) = (b.col[j], b.col[j + 1]);
        let mut t = 0.0f64;
        for s in 0..SAMPLES {
            let o = s * 4;
            let c = if s == 0 || ca == cb { ca } else { lerp4(ca, cb, t) };
            let pa = sc(a0, w[o]).add(sc(a1, w[o + 1])).add(sc(a2, w[o + 2])).add(sc(a3, w[o + 3]));
            let pe = sc(e0, w[o]).add(sc(e1, w[o + 1])).add(sc(e2, w[o + 2])).add(sc(e3, w[o + 3]));
            out.pair(pa, pe, c, u);
            u -= du;
            t += T_STEP;
        }
    }
    let c2 = k - 2;
    out.pair(ea[c2], eb[c2], b.col[c2], u);
    out.end_strip();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buf(n: usize) -> Buf {
        let mut b = Buf::default();
        for i in 0..n {
            b.pos.push(V3(i as f32 * 0.5, (i as f32).sin(), 0.1 * i as f32));
            b.col.push(0xFF00_0000 | (i as i64 * 40) << 16 | 0x80);
            b.w.push(0.2 + 0.05 * i as f32);
            b.y.push(V3(0.0, 1.0, 0.0));
        }
        b
    }

    #[test]
    fn strips_are_stitched_with_odd_starts() {
        let mut out = Out { turn: true, ..Default::default() };
        let mut s = Buf::default();
        spline(&buf(5), &mut s);
        assert_eq!(s.n(), 3 * 4 + 1);
        pipe_turn(&s, &mut out);
        let first = out.nv();
        pipe_turn(&buf(3), &mut out);
        assert!(out.nv() > first);
        assert_eq!(out.c0.len(), 4 * out.nv());
        let mut o2 = Out::default();
        obj_ribbon(&buf(6), &mut o2);
        obj_ribbon(&buf(2), &mut o2);
        assert_eq!(o2.colors.len(), o2.nv());
    }

    #[test]
    fn lerp_rounds_half_to_even() {
        assert_eq!(lerp4(0, 0x01, 0.5) & 0xFF, 0);
        assert_eq!(lerp4(0, 0x03, 0.5) & 0xFF, 2);
        assert_eq!(lerp4(0x10, 0x10, 0.3), 0x10);
    }
}
